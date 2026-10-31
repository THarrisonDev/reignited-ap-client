-- Author: Tim Harrison
-- Created: 2026-09-26
-- Updated: 2026-10-23

-- spyro1 dragons: send named checks from Collectable_Dragon_C actors and drive
-- the signed debug_extra_dragons counter so the game's count matches the
-- received Dragon items (spec = tests/lua/test_dragons.lua). Spyro-1-only, so
-- it runs only in Spyro 1 sessions. Threading: async poll thread, the
-- live-proven context for these calls. The reconcile drive itself (threading,
-- stable-level gate, [RECONCILE] logs) lives in reconcile_core.lua; the actor
-- watcher below feeds it.
--
-- API (main.lua): init{loc_id, log_sent, sent_checks (shared table ref),
-- send_checks}, configure(slot_data, in_s1_session),
-- note_item(name, index), is_item(name), received(), last_extra(),
-- arm_backlog(), reset_received(), note_disconnected(), tick(world), reset(),
-- status(). [RECONCILE] lines keep their sub-system tag inline.

local U = require("util")
local logger = require("logger")
local C = require("constants")
local reconcile_core = require("reconcile_core")

local M = {}

local S1_PREFIX = "Spyro 1: " -- every Spyro 1 location and item name carries it
local ITEM_DRAGON = S1_PREFIX .. "Dragon"

local TAG = "[DRAGONS]"

local log = logger.tagged(TAG)
local loc_id = function()
  return nil
end
local log_sent = function() end -- logs one sent check (Sent: ...)
local send_checks = function()
  return false, "not wired"
end
local sent_checks = {} -- SHARED with main.lua (by reference)

-- The reconcile drive (a signed debug_extra_dragons write that keeps the game's
-- computed dragon count equal to the received Dragon items). [RECONCILE] lines
-- are the live verification surface.
local R = reconcile_core.new({
  game = "spyro1",
  tag = "[DRAGONS]",
  kind = "dragons",
  item = ITEM_DRAGON,
  save_type = C.eit.EIT_Dragon, -- save-record type checkd scans
  total = C.totals.dragons, -- pure save-record domain [0, total]
  ufunction = "debug - add dragons",
  property = "debug_extra_dragons",
  option_name = "dragon_shuffle",
  option_label = "dragonsanity",
})

-- ---------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------
local safe = U.safe
local valid = U.valid

--- Return the number of keys in t (or 0 for nil).
--- @return number
local function count_keys(t)
  local n = 0
  for _ in pairs(t or {}) do
    n = n + 1
  end
  return n
end

--- Return the region-prefixed location name for a freed dragon.
--- @return string
local function dragon_loc_name(region, dragon)
  return S1_PREFIX .. region .. ": Free " .. dragon
end

-- ---------------------------------------------------------------------------
-- dragon watcher: Collectable_Dragon_C actors -> named checks
-- ---------------------------------------------------------------------------
-- identity cache: actor address -> {dragon=..., region=...} (cleared on level change)
local identity_cache = {} -- actor address -> {dragon=..., region=...} (level-scoped)
local warned_identity = {} -- actor addresses whose identity never resolved
local dragon_state = {} -- actor address -> collected (last known)

--- Return d's address as a string key, or nil when unavailable.
--- @return string|nil
local function actor_key(d)
  local okA, addr = pcall(function()
    return d:GetAddress()
  end)
  if okA and addr then
    return tostring(addr)
  end
  return nil
end

-- Dragon identity candidates, tried in order: save component
-- param[0].paramName (the game's own identity); DialogueTable.RowName; and the
-- display Name FText as a last resort ("Fairy" is a localization hit on every
-- statue and is rejected). A candidate is accepted only when slot data
-- resolves "Spyro 1: Region: Free <name>", so a wrong identity never reaches
-- LocationChecks.

--- Normalize a raw identity string, rejecting known junk ('Fairy', vo_/Default__
--- prefixes, generic Collectable_Dragon_C_N names). Returns nil when unusable.
--- @return string|nil
local function clean_dragon_name(raw)
  if type(raw) ~= "string" then
    return nil
  end
  local s = raw:match("^%s*(.-)%s*$")
  if s == "" or s == "None" or s == "Fairy" then
    return nil
  end
  if s:match("^vo_") or s:match("^Default__") then
    return nil
  end
  if s:match("^Collectable_Dragon_C_%d+$") then
    return nil
  end
  s = s:gsub("^Collectable_Dragon_", ""):gsub("^BP_", ""):gsub("^CNS%d+_", "")
  s = s:gsub("_C$", "")
  if s == "" or s:match("^%d+$") then
    return nil
  end
  return s
end

--- Decode a possibly UTF-16LE FString out-param value to an ASCII string,
--- returning raw when it is already plain ASCII and nil otherwise.
--- @return string|nil
local function decode_f16(raw)
  if type(raw) ~= "string" then
    return nil
  end
  if raw:match("^[\x20-\x7e]+$") then
    return raw
  end
  -- decode UTF-16LE: pair bytes -> code unit; take the ASCII subset
  local out = {}
  for i = 1, #raw - 1, 2 do
    local b1, b2 = raw:byte(i, i + 1)
    if b2 == 0 and b1 >= 0x20 and b1 <= 0x7e then
      out[#out + 1] = string.char(b1)
    elseif #out > 0 then
      break
    end
  end
  if #out == 0 then
    return nil
  end
  return table.concat(out)
end

--- Return d's raw identity strings in candidate order (save param, row name,
--- display name).
--- @return table
local function identity_raw(d)
  local raws = {}
  local save = safe(function()
    return d["PhasmidObjectSave"]
  end, nil)
  if valid(save) then
    local p = {}
    local okS = pcall(function()
      save:GetSaveParam(0, 0, p)
    end)
    if okS then
      -- p.paramName is a NESTED FString wrapper inside the struct
      -- out-param: call its ToString() (live-proven; may return UTF-16
      -- bytes, hence decode_f16). Reading it raw hands decode_f16 the
      -- wrapper object instead of a string, and every candidate is nil.
      raws[#raws + 1] = safe(function()
        return p.paramName:ToString()
      end, nil)
    end
  end
  local dtable = safe(function()
    return d["DialogueTable"]
  end, nil)
  if dtable ~= nil then
    raws[#raws + 1] = safe(function()
      return dtable.RowName:ToString()
    end, nil)
  end
  raws[#raws + 1] = safe(function()
    return d["Name"]:ToString()
  end, nil)
  return raws
end

--- Return d's cleaned, non-empty dragon-name candidates in priority order.
--- @return table
local function identity_candidates(d)
  local out = {}
  for _, raw in ipairs(identity_raw(d)) do
    local c = clean_dragon_name(decode_f16(raw))
    if c then
      out[#out + 1] = c
    end
  end
  return out
end

--- Return {dragon, region} for d by testing candidates against the loc_id
--- oracle, caching per actor address. Returns nil when unresolved.
--- @return table|nil
local function resolve_identity(d, region)
  local key = actor_key(d)
  if not key then
    return nil
  end
  local cached = identity_cache[key]
  if cached and cached.region == region then
    return cached
  end
  local dragon = nil
  for _, cand in ipairs(identity_candidates(d)) do
    if region and loc_id(dragon_loc_name(region, cand)) then
      dragon = cand
      break
    end
  end
  if dragon and region then
    identity_cache[key] = { dragon = dragon, region = region }
    return identity_cache[key]
  end
  return nil
end

--- Scan the current region's dragon actors and send checks for newly freed
--- dragons.
--- @param region string|nil Region resolved from the snapshot.
--- Queue the check for a newly observed rescue (silently skipped once sent).
local function queue_rescue(ident, new_checks)
  local full = dragon_loc_name(ident.region, ident.dragon)
  local id = loc_id(full)
  if not id then
    log.warn("no id for: " .. full)
    return
  end
  if sent_checks[id] then
    -- already sent this session (parent/child actor pairs and address
    -- recycling can re-fire); silent skip
    return
  end
  new_checks[#new_checks + 1] = id
  log.debug("dragon freed: " .. full .. " -> check " .. tostring(id))
end

--- Warn once per actor about an unresolved identity.
local function warn_identity(d, region, ident, collected, idkey)
  if ident or collected ~= true or not idkey or warned_identity[idkey] then
    return
  end
  warned_identity[idkey] = true
  local first = identity_candidates(d)[1]
  log.warn("unresolved dragon identity in " .. region .. " (first candidate: " .. tostring(first) .. ")")
end

--- Handle one dragon actor: warn once on an unresolved identity, and queue a
--- check for a rescue this session has not seen. Genuine observed rescues and
--- first-sight catch-up (despawn race / attach after a rescue) both land here;
--- R.note_local_rescue stays transition-only, since catch-up actors' save
--- records are counted by the readback instead.
local function note_dragon(d, region, new_checks)
  local collected = safe(function()
    return d["Collected_Dragons"] == true
  end, false)
  local ident = resolve_identity(d, region)
  local idkey = actor_key(d)
  warn_identity(d, region, ident, collected, idkey)
  if not (ident and ident.dragon and idkey) then
    return
  end
  local prev = dragon_state[idkey]
  if prev ~= true and collected == true then
    queue_rescue(ident, new_checks)
    if prev == false then
      R.note_local_rescue()
    end
  end
  dragon_state[idkey] = collected
end

--- Send the queued checks, marking each only on success so a failure retries.
local function send_new(new_checks)
  if #new_checks == 0 then
    return
  end
  local okS = send_checks(new_checks)
  log.debug("LocationChecks(" .. #new_checks .. "): ok=" .. tostring(okS))
  for _, id in ipairs(new_checks) do
    if okS then
      log_sent(id)
      sent_checks[id] = true
    end
  end
  log.debug("[RECONCILE] sent checks total this session: " .. count_keys(sent_checks))
end

local function poll_dragons(region)
  if not region then
    return
  end
  local dragons = safe(function()
    return FindAllOf("Collectable_Dragon_C")
  end)
  if not dragons then
    return
  end
  local new_checks = {}
  for _, d in ipairs(dragons) do
    if valid(d) then
      note_dragon(d, region, new_checks)
    end
  end
  send_new(new_checks)
end

-- per-poll entry point: one snapshot feeds the transition invalidation, the
-- baseline readback, the watcher and the reconcile drive, in that order (the
-- drive acts on this tick's readback).
--- Run one poll: transition invalidation, baseline readback, dragon watcher,
--- then the reconcile drive.
--- @param world table game_state snapshot.
function M.tick(world)
  if not world.ok then
    return
  end
  if world.changed then
    -- a world transition zeroes the debug-extra field and remakes the actors
    R.note_level_change()
    identity_cache, warned_identity, dragon_state = {}, {}, {}
  end

  R.anchor(world)
  poll_dragons(world.region)
  R.drive(world)
end

--- Return the reconcile status line.
--- @return string
function M.status()
  return R.status()
end

--- Reset per-session reconcile and watcher state. sent_checks is shared with
--- main.lua and is not cleared here.
function M.reset()
  R.reset()
  identity_cache, warned_identity, dragon_state = {}, {}, {}
end

--- Bind logger and the main.lua seams from opts {log, loc_id, log_sent,
--- send_checks, sent_checks}.
function M.init(opts)
  log = logger.leveled(TAG, opts and opts.log)
  loc_id = (opts and opts.loc_id) or loc_id
  log_sent = (opts and opts.log_sent) or log_sent
  send_checks = (opts and opts.send_checks) or send_checks
  if opts and opts.sent_checks then
    sent_checks = opts.sent_checks
  end
  R.init(opts)
end

-- Reconcile API (reconcile_core.lua): thin delegation to the shared drive.
M.configure = R.configure
M.note_item = R.note_item
M.is_item = R.is_item
M.received = R.received
M.last_extra = R.last_extra
M.arm_backlog = R.arm_backlog
M.reset_received = R.reset_received
M.note_disconnected = R.note_disconnected
M.tag = TAG

return M
