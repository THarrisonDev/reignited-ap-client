-- spyro1 dragons: send named checks from Collectable_Dragon_C actors and drive
-- the signed debug_extra_dragons counter so the game's count matches the
-- received Dragon items (spec = tests/lua/test_dragons.lua). Spyro-1-only, so
-- it runs only in Spyro 1 sessions. Threading: async poll thread, the
-- live-proven context for these calls.
--
-- API (main.lua): init{log, regions, loc_id, log_sent, sent_checks (shared
-- table ref), send_checks}, configure(slot_data, in_s1_session),
-- note_item(name, index), is_dragon(name), received(), last_extra(),
-- arm_backlog(), reset_received(), note_disconnected(), tick(gs), reset(),
-- status(). [RECONCILE] lines keep their sub-system tag inline.

local U = require("util")
local logger = require("logger")

local M = {}

local S1_PREFIX = "Spyro 1: " -- every Spyro 1 location and item name carries it
local ITEM_DRAGON = S1_PREFIX .. "Dragon"

local log = logger.tagged("[DRAGONS]")
local regions = {} -- map path -> region (generated regions.lua)
local loc_id = function()
  return nil
end
local log_sent = function() end -- logs one sent check (Sent: ...)
local send_checks = function()
  return false, "not wired"
end
local sent_checks = {} -- SHARED with main.lua (by reference)

-- ---------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------
local safe = U.safe
local valid = U.valid

--- Return the number of keys in t (or 0 for nil).
--- @param t table|nil
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
-- dragon reconcile: a signed debug_extra_dragons drive that keeps the game's
-- computed dragon count equal to the received Dragon items (spec =
-- tests/lua/test_dragons.lua). The compute is unclamped and the field is
-- int32, so extra = received - save_collected may take any sign. Writes are
-- idempotent and refused while disarmed / vanilla / no-baseline. The
-- [RECONCILE] debug lines are the live verification surface.
-- ---------------------------------------------------------------------------
local rec = {
  received = 0, -- Dragon items received from the server
  save_collected = 0, -- baseline + observed local rescues
  baseline_set = false,
  armed = false,
  sync_dragons = false, -- slot data says Dragon items exist (dragonsanity)
  last_extra = nil, -- last value we asked the game to hold
  writes = 0, -- lifetime extra writes
  readbacks = 0, -- lifetime save_collected readback polls
  drift_corrections = 0, -- lifetime readback drift re-syncs
  skips = { disarmed = 0, no_baseline = 0 },
  last_skip_reason = nil, -- for the heartbeat: why the last tick didn't write
  -- world transitions ZERO debug_extra_dragons (live-proven), so the
  -- written value is stale after every level load even if it numerically
  -- matches. reasserts_pending counts transitions seen since the last
  -- successful write; rec_tick re-asserts the target until it lands.
  reasserts_pending = 0,
  reasserts = 0, -- lifetime level-change re-asserts written
  -- stable-playable-level gate: current level must match /LS###_.../Maps/
  -- for >=2 consecutive ticks before ANY write; the gamestate also exists on
  -- the load screen, and writing there hardlocks the game.
  stable_ticks = 0,
  last_write_level = nil,
  pending_readback = nil, -- first unconfirmed disagreeing readback (nil=none)
}

--- Arm the reconcile and log the slot-connect debug line.
local function rec_arm()
  rec.armed = true
  log.debug(
    string.format(
      "[RECONCILE] armed at slot-connect (dragonsanity): received=%d baseline=%s sync_dragons=%s",
      rec.received,
      tostring(rec.save_collected),
      tostring(rec.sync_dragons)
    )
  )
end

--- Anchor save_collected to n on the first playable-level readback.
local function rec_set_baseline(n)
  if rec.baseline_set then
    return
  end
  rec.save_collected = n
  rec.baseline_set = true
  log.debug(string.format("[RECONCILE] baseline anchored: save_collected=%d (first playable-level readback)", n))
end

--- Record one observed local rescue so the drive self-corrects next tick.
local function rec_note_local_rescue()
  rec.save_collected = rec.save_collected + 1
  log.debug(
    string.format(
      "[RECONCILE] local rescue observed: save_collected %d -> %d (computed self-corrects next tick)",
      rec.save_collected - 1,
      rec.save_collected
    )
  )
end

--- Mark the drive invalid after a world transition, so the next stable tick
--- re-asserts the target (the game zeroes the field at transitions).
local function rec_note_level_change()
  if rec.last_extra ~= nil or rec.reasserts_pending > 0 then
    rec.reasserts_pending = rec.reasserts_pending + 1
    log.debug(
      string.format(
        "[RECONCILE] level change: drive invalidated (pending re-assert #%d, target=%d)",
        rec.reasserts_pending,
        rec.received - rec.save_collected
      )
    )
  end
end

--- Make one reconcile decision and write, returning the extra written or nil.
--- cur_level is the caller's playable-level path (nil = not playable), shared
--- with the watchers so the stable-level gate uses the same source.
--- @return number|nil
local function rec_tick(cur_level, gs)
  if not rec.armed or not rec.sync_dragons then
    rec.last_skip_reason = "disarmed"
    rec.skips.disarmed = rec.skips.disarmed + 1
    return nil
  end
  if not rec.baseline_set then
    rec.last_skip_reason = "no_baseline"
    rec.skips.no_baseline = rec.skips.no_baseline + 1
    return nil
  end
  local extra = rec.received - rec.save_collected
  if extra < -80 then
    extra = -80
  end
  if extra > 80 then
    extra = 80
  end

  -- Stable-playable-level gate (the gamestate also exists on the load
  -- screen, and a write there hardlocks). cur_level is non-nil only when
  -- the current map path matches /LS###_.../Maps/.
  if cur_level == nil then
    rec.stable_ticks = 0
    rec.last_skip_reason = "not_playable"
    return nil
  end
  if cur_level ~= rec.last_write_level then
    rec.stable_ticks = 0
    rec.last_write_level = cur_level
  end
  rec.stable_ticks = rec.stable_ticks + 1
  if rec.stable_ticks < 2 then
    rec.last_skip_reason = "level_stabilizing"
    return nil
  end

  -- idempotence OR pending re-assert: after a level change the game zeroed
  -- the field, so a numerically-equal last_extra must still be re-written.
  if rec.last_extra == extra and rec.reasserts_pending == 0 then
    return nil
  end
  if not valid(gs) then
    rec.last_skip_reason = "game_not_ready"
    return nil
  end
  -- Write through the game's own UFunction: sets debug_extra_dragons = N
  -- when clear=true (kismet: extra = N + (clear ? 0 : current)) AND fires
  -- "Hud Notify Inventory Updated" so the HUD re-derives the count
  -- instantly — a raw property write skips the notify, so the HUD only
  -- refreshes at the next world transition (both live-proven).
  local ok = pcall(function()
    gs["debug - add dragons"](extra, true)
  end)
  if not ok then
    -- fallback: raw property write (no HUD notify; transition re-assert
    -- still converges the HUD later)
    ok = pcall(function()
      gs["debug_extra_dragons"] = extra
    end)
  end
  if ok then
    local prev = rec.last_extra
    rec.last_extra = extra
    rec.writes = rec.writes + 1
    local tag
    if rec.reasserts_pending > 0 then
      rec.reasserts = rec.reasserts + 1
      rec.reasserts_pending = 0
      tag = string.format(" re-assert #%d (level=%s)", rec.reasserts, cur_level)
    end
    log.debug(
      string.format(
        "[RECONCILE] extra write #%d: %s -> %d (received=%d save_collected=%d computed=%d)%s",
        rec.writes,
        tostring(prev),
        extra,
        rec.received,
        rec.save_collected,
        rec.save_collected + extra,
        tag or ""
      )
    )
  else
    log.error(
      string.format(
        "[RECONCILE] write failed for extra=%d (received=%d save_collected=%d)",
        extra,
        rec.received,
        rec.save_collected
      )
    )
  end
  return ok and extra or nil
end

--- Return the one-line reconcile status for the poll heartbeat.
--- @return string
local function rec_status()
  if not rec.armed then
    return "disarmed"
  end
  if not rec.sync_dragons then
    return "vanilla(off)"
  end
  if not rec.baseline_set then
    return "no_baseline"
  end
  return string.format(
    "extra=%s recv=%d save=%d reassert(pending=%d done=%d) drift=%d",
    tostring(rec.last_extra),
    rec.received,
    rec.save_collected,
    rec.reasserts_pending,
    rec.reasserts,
    rec.drift_corrections
  )
end

--- Read the pure dragon save-record count, excluding debug_extra; unwrap the
--- UE4SS out-param table wrapper. Returns nil when unreadable.
--- @return number|nil
local function rec_read_save_collected(gs)
  local out = {}
  local ok = pcall(function()
    gs["get inventory collected count"](16, "", true, out)
  end)
  if not ok then
    return nil
  end
  local c = safe(function()
    return out["Count"]
  end, nil)
  if type(c) == "number" then
    return c
  end
  if type(c) == "table" then
    local inner = safe(function()
      return c.value
    end, nil)
    if type(inner) == "number" then
      return inner
    end
  end
  return nil
end

--- Anchor save_collected on the first playable-level read and re-sync it on
--- confirmed drift, healing missed rescues without touching rec.received. A
--- disagreeing read is applied only on a second consecutive agreement, since
--- mid-transition reads can return transient garbage. Load-screen and unknown
--- map reads are ignored.
local function rec_anchor_baseline(gs, map_path)
  if not valid(gs) then
    return
  end
  if not (map_path and regions[map_path]) then
    return
  end
  local n = rec_read_save_collected(gs)
  -- domain guard: dragons live in [0,80]; anything else is a bad readback
  -- (unwrapped out-param garbage) and must not touch the engine
  if n == nil or n < 0 or n > 80 then
    return
  end
  rec.readbacks = rec.readbacks + 1
  if not rec.baseline_set then
    rec_set_baseline(n)
    rec.pending_readback = nil
    return
  end
  if n == rec.save_collected then
    rec.pending_readback = nil
    return
  end
  -- disagreeing read: require a second consecutive confirmation
  if rec.pending_readback == n then
    rec.pending_readback = nil
    log.debug(
      string.format(
        "[RECONCILE] save_collected readback drift (confirmed): %d -> %d (received=%d; re-syncing)",
        rec.save_collected,
        n,
        rec.received
      )
    )
    rec.save_collected = n
    rec.drift_corrections = rec.drift_corrections + 1
  else
    rec.pending_readback = n
    log.debug(
      string.format(
        "[RECONCILE] save_collected readback disagrees: %d != %d (received=%d; awaiting confirmation)",
        rec.save_collected,
        n,
        rec.received
      )
    )
  end
end

local seen_index = {} -- AP item index -> true

--- Count a received Dragon once per AP item index; ReceivedItems is
--- cumulative, so every packet re-delivers index 0..n. Return true when new.
--- @return boolean
function M.note_item(name, index)
  if index ~= nil then
    if seen_index[index] then
      return false
    end
    seen_index[index] = true
  end
  if name == ITEM_DRAGON then
    rec.received = rec.received + 1
  end
  return true
end

--- Return whether name is the shared Dragon item.
--- @return boolean
function M.is_dragon(name)
  return name == ITEM_DRAGON
end

--- Return the number of Dragon items received this session.
--- @return number
function M.received()
  return rec.received
end

--- Return the last extra value written, or nil.
--- @return number|nil
function M.last_extra()
  return rec.last_extra
end

--- Zero the received count on reconnect so the cumulative backlog recount is
--- exact-once (a mid-session reconnect re-delivers every Dragon).
function M.reset_received()
  rec.received = 0
  seen_index = {}
end

--- Re-arm on the first post-reconnect ReceivedItems batch, so counting starts
--- from 0 exactly when the recount begins.
function M.arm_backlog()
  if rec.sync_dragons and not rec.armed then
    rec_arm()
  end
end

--- Stop reconcile writes while disconnected; arm_backlog re-arms.
function M.note_disconnected()
  rec.armed = false
end

--- Read the dragonsanity option from slot data, arm when in a Spyro 1 session,
--- and log the slot config.
function M.configure(slot_data, in_s1_session)
  local opts = {}
  if slot_data and type(slot_data.games) == "table" and type(slot_data.games.spyro1) == "table" then
    opts = slot_data.games.spyro1.options or {}
  end
  local val = opts.dragon_shuffle
  -- slot data carries the option name ("dragonsanity") or truthy ordinal
  rec.sync_dragons = (val == "dragonsanity") or (val == 1)
  log.debug(
    string.format(
      "[RECONCILE] slot config: sync_dragons=%s (dragon_shuffle=%s)",
      tostring(rec.sync_dragons),
      tostring(val)
    )
  )
  -- arm at slot-connect, not on the backlog: a fresh dragonsanity seed may
  -- never send a ReceivedItems packet, so backlog-arming could never
  -- activate the neutralization. A reconnect (baseline set) waits for
  -- arm_backlog so the recount starts when received = 0.
  if rec.sync_dragons and in_s1_session and not rec.baseline_set then
    rec_arm()
  end
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

local rec_last_level = nil -- last PLAYABLE map path seen (level-change detect)

--- Scan the current region's dragon actors, send checks for newly freed
--- dragons, and note level changes. map_path is the playable path or nil.
local function poll_dragons(map_path, region)
  if region then
    -- level-change detection: a playable map path that differs from the
    -- last playable one seen means a world transition happened (the
    -- field was zeroed by the engine) -> invalidate the drive's
    -- "already written" state
    if rec_last_level and rec_last_level ~= map_path then
      rec_note_level_change()
      identity_cache, warned_identity, dragon_state = {}, {}, {}
    end
    rec_last_level = map_path
  else
    -- load screen / unknown level: the transition window itself. Only
    -- counts as a change if we had a level before (not on first sight).
    if rec_last_level then
      rec_note_level_change()
      identity_cache, warned_identity, dragon_state = {}, {}, {}
      rec_last_level = nil
    end
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
      local collected = safe(function()
        return d["Collected_Dragons"] == true
      end, false)
      local ident = resolve_identity(d, region)
      local idkey = actor_key(d)
      if not ident and collected == true and idkey and not warned_identity[idkey] then
        warned_identity[idkey] = true
        local first = identity_candidates(d)[1]
        log.warn("unresolved dragon identity in " .. region .. " (first candidate: " .. tostring(first) .. ")")
      end
      if ident and ident.dragon and idkey then
        local prev = dragon_state[idkey]
        -- genuine observed rescue OR first-sight catch-up (despawn
        -- race / attach after a rescue): sends exactly once per
        -- session (sent_checks) and the server ignores re-checks.
        -- rec_note_local_rescue stays transition-only: catch-up
        -- actors' save records are counted by the readback instead.
        if prev ~= true and collected == true then
          local full = dragon_loc_name(ident.region, ident.dragon)
          local id = loc_id(full)
          if id and sent_checks[id] then
            -- already sent this session (parent/child actor pairs
            -- and address recycling can re-fire); silent skip
          elseif id then
            new_checks[#new_checks + 1] = id
            log.debug("dragon freed: " .. full .. " -> check " .. tostring(id))
          else
            log.warn("no id for: " .. full)
          end
          if prev == false then
            -- reconcile input: the game just added a save record
            rec_note_local_rescue()
          end
        end
        dragon_state[idkey] = collected
      end
    end
  end
  if #new_checks > 0 then
    local okS, err = send_checks(new_checks)
    log.debug("LocationChecks(" .. #new_checks .. "): ok=" .. tostring(okS) .. " err=" .. tostring(err))
    for _, id in ipairs(new_checks) do
      if okS then
        -- mark only on success (same rule as checks_drop.lua): a
        -- failed send must retry next tick, not be suppressed all session
        log_sent(id)
        sent_checks[id] = true
      end
    end
    log.debug("[RECONCILE] sent checks total this session: " .. count_keys(sent_checks))
  end
end

-- per-poll entry point: one gamestate read feeds baseline readback, watcher
-- and reconcile, in that order (the drive acts on this tick's readback)
local hb_ticks = 0

--- Run one poll: baseline readback, dragon watcher, then the reconcile drive.
function M.tick(gs)
  if not valid(gs) then
    return
  end
  local map_path = safe(function()
    return gs["current level"]:ToString()
  end, nil)
  local region = map_path and regions[map_path] or nil

  hb_ticks = hb_ticks + 1
  -- heartbeat cadence: this counter only advances while tick runs (in-play
  -- S1 sessions), so 480 ticks ~= 2 min of play, not of wall time
  local hb_now = rec.armed and (hb_ticks % 480 == 0)

  rec_anchor_baseline(gs, map_path)
  poll_dragons(map_path, region)
  -- signed reconcile drive; the playable level is passed in so the
  -- stable-level gate uses the same map-path source as the watchers
  rec_tick(region and map_path or nil, gs)

  if hb_now then
    log.debug(
      string.format(
        "[RECONCILE] hb: %s | writes=%d reads=%d drift=%d skips(disarmed=%d no_baseline=%d) game=%s",
        rec_status(),
        rec.writes,
        rec.readbacks,
        rec.drift_corrections,
        rec.skips.disarmed,
        rec.skips.no_baseline,
        rec.last_skip_reason or "-"
      )
    )
    rec.last_skip_reason = nil
  end
end

--- Return the reconcile status line.
--- @return string
function M.status()
  return rec_status()
end

--- Reset per-session reconcile and watcher state. sent_checks is shared with
--- main.lua and is not cleared here.
function M.reset()
  rec.received, rec.save_collected, rec.baseline_set, rec.armed = 0, 0, false, false
  rec.last_extra, rec.reasserts_pending, rec.stable_ticks = nil, 0, 0
  rec.last_write_level, rec.pending_readback = nil, nil
  rec.skips.disarmed, rec.skips.no_baseline = 0, 0
  rec.last_skip_reason = nil
  rec_last_level = nil
  identity_cache, warned_identity, dragon_state = {}, {}, {}
  seen_index = {}
end

--- Bind logger and the main.lua seams from opts {log, regions, loc_id,
--- log_sent, send_checks, sent_checks}.
function M.init(opts)
  log = logger.leveled("[DRAGONS]", opts and opts.log)
  regions = (opts and opts.regions) or regions
  loc_id = (opts and opts.loc_id) or loc_id
  log_sent = (opts and opts.log_sent) or log_sent
  send_checks = (opts and opts.send_checks) or send_checks
  if opts and opts.sent_checks then
    sent_checks = opts.sent_checks
  end
end

return M
