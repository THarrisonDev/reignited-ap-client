-- spyro1 dragons: the dragon watcher (named checks from Collectable_Dragon_C
-- actors) + the signed debug_extra_dragons reconcile; spec =
-- tests/lua/test_dragons.lua. Identity = save component param[0].paramName
-- (the Guide Book's own source); display Name FText is localization junk
-- ("Fairy" trap).
-- Received-Dragon counting is exact-once per AP item index.
--
-- Spyro-1-only game logic, so it runs only in Spyro 1 sessions (main.lua).
--
-- Game surface (all live-proven shapes):
--   reads   gs["current level"]:ToString(), FindAllOf("Collectable_Dragon_C"),
--           actor property reads, get inventory collected count(16, "", true, out)
--   writes  gs["debug - add dragons"](extra, true) with the raw property-write
--           fallback gs["debug_extra_dragons"] = extra
--   send    send_checks(ids) seam provided by main.lua (ap:LocationChecks)
-- Threading: async poll thread — the live-proven context for these calls.
--
-- API (main.lua): init{log, regions, loc_id, log_sent, sent_checks (shared
-- table ref), send_checks}, configure(slot_data, in_s1_session),
-- note_item(name, index), is_dragon(name), received(), last_extra(),
-- arm_backlog(), reset_received(), note_disconnected(), tick(gs), reset(),
-- status(). log is a leveled logger (tagged [DRAGONS]) or the spec's
-- collector function; the watcher's WARNs and the reconcile write failure
-- reach the console. [RECONCILE] lines keep their sub-system tag inline.

local U = require("util")
local logger = require("logger")

local M = {}

local S1_PREFIX = "Spyro 1: "  -- every Spyro 1 location and item name carries it
local ITEM_DRAGON = S1_PREFIX .. "Dragon"

local log = logger.tagged("[DRAGONS]")
local regions = {}             -- map path -> region (generated regions.lua)
local loc_id = function() return nil end
local log_sent = function() end              -- logs one sent check (Sent: ...)
local send_checks = function() return false, "not wired" end
local sent_checks = {}         -- SHARED with main.lua (by reference)

-- ---------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------
local safe = U.safe
local valid = U.valid

local function count_keys(t)
    local n = 0
    for _ in pairs(t or {}) do n = n + 1 end
    return n
end

local function dragon_loc_name(region, dragon)
    return S1_PREFIX .. region .. ": Free " .. dragon
end

-- ---------------------------------------------------------------------------
-- dragon reconcile (signed debug_extra_dragons drive; spec =
-- tests/lua/test_dragons.lua).
--
-- debug_extra_dragons is int32 (SDK +0x554) and the computed count (kismet
-- block 4517: GetFalconInventoryCollectedCount + debug_extra) is unclamped
-- (live-proven), so a signed drive makes computed == received always:
--   extra = received - save_collected   (any sign)
--   computed = save_collected + extra = received
-- save_collected = connect baseline (game's own counter) + observed local
-- rescues (uncollected->collected transitions in the watcher below). Writes
-- are idempotent and refused while disarmed / vanilla / no-baseline.
-- The [RECONCILE] debug lines are the live verification surface for the drive.
-- ---------------------------------------------------------------------------
local rec = {
    received = 0,            -- Dragon items received from the server
    save_collected = 0,      -- baseline + observed local rescues
    baseline_set = false,
    armed = false,
    sync_dragons = false,    -- slot data says Dragon items exist (dragonsanity)
    last_extra = nil,        -- last value we asked the game to hold
    writes = 0,              -- lifetime extra writes
    readbacks = 0,           -- lifetime save_collected readback polls
    drift_corrections = 0,   -- lifetime readback drift re-syncs
    skips = { disarmed = 0, no_baseline = 0 },
    last_skip_reason = nil,  -- for the heartbeat: why the last tick didn't write
    -- world transitions ZERO debug_extra_dragons (live-proven), so the
    -- written value is stale after every level load even if it numerically
    -- matches. reasserts_pending counts transitions seen since the last
    -- successful write; rec_tick re-asserts the target until it lands.
    reasserts_pending = 0,
    reasserts = 0,           -- lifetime level-change re-asserts written
    -- stable-playable-level gate: current level must match /LS###_.../Maps/
    -- for >=2 consecutive ticks before ANY write; the gamestate also exists on
    -- the load screen, and writing there hardlocks the game.
    stable_ticks = 0,
    last_write_level = nil,
    pending_readback = nil,  -- first unconfirmed disagreeing readback (nil=none)
}

local function rec_arm()
    rec.armed = true
    log.debug(string.format(
        "[RECONCILE] armed at slot-connect (dragonsanity): received=%d baseline=%s sync_dragons=%s",
        rec.received, tostring(rec.save_collected), tostring(rec.sync_dragons)))
end

local function rec_set_baseline(n)
    if rec.baseline_set then return end
    rec.save_collected = n
    rec.baseline_set = true
    log.debug(string.format(
        "[RECONCILE] baseline anchored: save_collected=%d (first playable-level readback)", n))
end

local function rec_note_local_rescue()
    rec.save_collected = rec.save_collected + 1
    log.debug(string.format(
        "[RECONCILE] local rescue observed: save_collected %d -> %d (computed self-corrects next tick)",
        rec.save_collected - 1, rec.save_collected))
end

-- The game zeroes debug_extra_dragons at world transitions. Called by the
-- level-change detection in the watcher below: invalidates the "already
-- written" memory so the next tick re-asserts the target once the new level
-- is stable.
local function rec_note_level_change()
    if rec.last_extra ~= nil or rec.reasserts_pending > 0 then
        rec.reasserts_pending = rec.reasserts_pending + 1
        log.debug(string.format(
            "[RECONCILE] level change: drive invalidated (pending re-assert #%d, target=%d)",
            rec.reasserts_pending, rec.received - rec.save_collected))
    end
end

-- one reconcile decision + write; returns the extra written or nil (with
-- reason). Caller passes cur_level (the already-computed playable level or
-- nil) so the stable-level gate uses the same map-path source as the
-- watchers; nil = not in a known playable level this tick.
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
    if extra < -80 then extra = -80 end
    if extra > 80 then extra = 80 end

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
    local ok = pcall(function() gs["debug - add dragons"](extra, true) end)
    if not ok then
        -- fallback: raw property write (no HUD notify; transition re-assert
        -- still converges the HUD later)
        ok = pcall(function() gs["debug_extra_dragons"] = extra end)
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
        log.debug(string.format(
            "[RECONCILE] extra write #%d: %s -> %d (received=%d save_collected=%d computed=%d)%s",
            rec.writes, tostring(prev), extra, rec.received, rec.save_collected,
            rec.save_collected + extra, tag or ""))
    else
        log.error(string.format(
            "[RECONCILE] write failed for extra=%d (received=%d save_collected=%d)",
            extra, rec.received, rec.save_collected))
    end
    return ok and extra or nil
end

-- one-line status for the poll heartbeat
local function rec_status()
    if not rec.armed then return "disarmed" end
    if not rec.sync_dragons then return "vanilla(off)" end
    if not rec.baseline_set then return "no_baseline" end
    return string.format("extra=%s recv=%d save=%d reassert(pending=%d done=%d) drift=%d",
        tostring(rec.last_extra), rec.received, rec.save_collected,
        rec.reasserts_pending, rec.reasserts, rec.drift_corrections)
end

-- live-proven readback: get inventory collected count(16, "", true) -> Count
-- out-key = PURE dragon save-record count (excludes debug_extra). May come
-- back table-wrapped (UE4SS out-param quirk) — unwrap .value.
local function rec_read_save_collected(gs)
    local out = {}
    local ok = pcall(function() gs["get inventory collected count"](16, "", true, out) end)
    if not ok then return nil end
    local c = safe(function() return out["Count"] end, nil)
    if type(c) == "number" then return c end
    if type(c) == "table" then
        local inner = safe(function() return c.value end, nil)
        if type(inner) == "number" then return inner end
    end
    return nil
end

-- Baseline + drift: read the game's own dragon save-record count every poll
-- tick. First successful in-playable-level read anchors
-- save_collected; every read re-syncs it, healing any drift (missed rescue
-- events, wrong-baseline starts) without touching rec.received. The signed
-- drive then enforces computed == received on the next tick. Readbacks on
-- load screens / unknown maps are ignored (save data may be mid-transition).
-- Disagreement rule: a readback that differs from save_collected is applied
-- ONLY on the second consecutive agreeing read — mid-transition reads can
-- return transient garbage (live: a 0 between two 9s), and re-syncing on a
-- single read would chase it with two needless counter writes.
local function rec_anchor_baseline(gs, map_path)
    if not valid(gs) then return end
    if not (map_path and regions[map_path]) then return end
    local n = rec_read_save_collected(gs)
    -- domain guard: dragons live in [0,80]; anything else is a bad readback
    -- (unwrapped out-param garbage) and must not touch the engine
    if n == nil or n < 0 or n > 80 then return end
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
        log.debug(string.format(
            "[RECONCILE] save_collected readback drift (confirmed): %d -> %d (received=%d; re-syncing)",
            rec.save_collected, n, rec.received))
        rec.save_collected = n
        rec.drift_corrections = rec.drift_corrections + 1
    else
        rec.pending_readback = n
        log.debug(string.format(
            "[RECONCILE] save_collected readback disagrees: %d != %d (received=%d; awaiting confirmation)",
            rec.save_collected, n, rec.received))
    end
end

-- exact-once per AP item index: ReceivedItems is cumulative, so every packet
-- re-delivers index 0..n. Returns true when the index was new.
local seen_index = {}   -- AP item index -> true
function M.note_item(name, index)
    if index ~= nil then
        if seen_index[index] then return false end
        seen_index[index] = true
    end
    if name == ITEM_DRAGON then
        rec.received = rec.received + 1
    end
    return true
end

function M.is_dragon(name) return name == ITEM_DRAGON end
function M.received() return rec.received end
function M.last_extra() return rec.last_extra end

-- reconnect: zero the received count so the cumulative backlog recount is
-- exact-once (a mid-session reconnect re-delivers every Dragon)
function M.reset_received()
    rec.received = 0
    seen_index = {}
end

-- arming: fresh sessions arm at slot-connect (M.configure); a RECONNECT
-- re-arms here on the first post-reconnect ReceivedItems batch — counting
-- starts from 0 exactly when the recount begins
function M.arm_backlog()
    if rec.sync_dragons and not rec.armed then
        rec_arm()
    end
end

-- no reconcile writes while disconnected; re-armed by arm_backlog
function M.note_disconnected()
    rec.armed = false
end

-- slot connect: reconcile config + the "[RECONCILE] slot config:" log line
-- + arming.
function M.configure(slot_data, in_s1_session)
    local opts = {}
    if slot_data and type(slot_data.games) == "table" and type(slot_data.games.spyro1) == "table" then
        opts = slot_data.games.spyro1.options or {}
    end
    local val = opts.dragon_shuffle
    -- slot data carries the option name ("dragonsanity") or truthy ordinal
    rec.sync_dragons = (val == "dragonsanity") or (val == 1)
    log.debug(string.format("[RECONCILE] slot config: sync_dragons=%s (dragon_shuffle=%s)",
        tostring(rec.sync_dragons), tostring(val)))
    -- arm AT slot-connect in dragonsanity (do NOT wait for the backlog): a
    -- fresh seed grants zero items and the server sends no ReceivedItems
    -- packet at all, so backlog-arming never fires and the neutralization
    -- (counter -> 0) would never activate. Safe: the drive field is a
    -- session-scoped overlay, the target is exact from the readback
    -- baseline, and vanilla mode never arms (config ran first). A RECONNECT
    -- (baseline already set) does not re-arm here: arm_backlog() re-arms on
    -- the next batch so the recount starts exactly when received = 0.
    if rec.sync_dragons and in_s1_session and not rec.baseline_set then
        rec_arm()
    end
end

-- ---------------------------------------------------------------------------
-- dragon watcher: Collectable_Dragon_C actors -> named checks
-- ---------------------------------------------------------------------------
-- identity cache: actor address -> {dragon=..., region=...} (cleared on level change)
local identity_cache = {}   -- actor address -> {dragon=..., region=...} (level-scoped)
local warned_identity = {}  -- actor addresses whose identity never resolved
local dragon_state = {}     -- actor address -> collected (last known)

local function actor_key(d)
    local okA, addr = pcall(function() return d:GetAddress() end)
    if okA and addr then return tostring(addr) end
    return nil
end

-- Dragon identity candidates, in priority order (all surfaces live-proven):
--  1. save component param[0].paramName — the game's own identity (Guide
--     Book decode: statue display name = save object param[0]; disk-save
--     proof: generic 'Collectable_Dragon_C_56' carries param 'Gildas')
--  2. DialogueTable.RowName ("CNS1101_Darius" -> strip the CNS key)
--  3. display Name FText — LAST resort; "Fairy" is a localization-table
--     name hit on ALL statues (live-proven) and is rejected outright.
-- (GetChildActorName is NOT a candidate: it returns void and writes an
-- FString out-param, so a zero-arg call is always nil, and string out-params
-- crash under UE4SS.)
-- A candidate is ACCEPTED only when slot data resolves "Spyro 1: Region: Free <name>"
-- (loc_id oracle), so a wrong identity can never reach LocationChecks.
local function clean_dragon_name(raw)
    if type(raw) ~= "string" then return nil end
    local s = raw:match("^%s*(.-)%s*$")
    if s == "" or s == "None" or s == "Fairy" then return nil end
    if s:match("^vo_") or s:match("^Default__") then return nil end
    if s:match("^Collectable_Dragon_C_%d+$") then return nil end
    s = s:gsub("^Collectable_Dragon_", ""):gsub("^BP_", ""):gsub("^CNS%d+_", "")
    s = s:gsub("_C$", "")
    if s == "" or s:match("^%d+$") then return nil end
    return s
end

-- FString values read through a struct out-param can come back as RAW
-- UTF-16 bytes in the Lua string (live: "뇐㔝" = misaligned code units of an
-- ASCII name).
-- The pcall keeps this safe on non-string shapes; byte pattern checks below
-- are done on the UTF-8-looking result only after decoding.
local function decode_f16(raw)
    if type(raw) ~= "string" then return nil end
    if raw:match("^[\x20-\x7e]+$") then return raw end
    -- decode UTF-16LE: pair bytes -> code unit; take the ASCII subset
    local out = {}
    for i = 1, #raw - 1, 2 do
        local b1, b2 = raw:byte(i, i+1)
        if b2 == 0 and b1 >= 0x20 and b1 <= 0x7e then
            out[#out+1] = string.char(b1)
        elseif #out > 0 then
            break
        end
    end
    if #out == 0 then return nil end
    return table.concat(out)
end

local function identity_raw(d)
    local raws = {}
    local save = safe(function() return d["PhasmidObjectSave"] end, nil)
    if valid(save) then
        local p = {}
        local okS = pcall(function() save:GetSaveParam(0, 0, p) end)
        if okS then
            -- p.paramName is a NESTED FString wrapper inside the struct
            -- out-param: call its ToString() (live-proven; may return UTF-16
            -- bytes, hence decode_f16). Reading it raw hands decode_f16 the
            -- wrapper object instead of a string, and every candidate is nil.
            raws[#raws+1] = safe(function() return p.paramName:ToString() end, nil)
        end
    end
    local dtable = safe(function() return d["DialogueTable"] end, nil)
    if dtable ~= nil then
        raws[#raws+1] = safe(function() return dtable.RowName:ToString() end, nil)
    end
    raws[#raws+1] = safe(function() return d["Name"]:ToString() end, nil)
    return raws
end

local function identity_candidates(d)
    local out = {}
    for _, raw in ipairs(identity_raw(d)) do
        local c = clean_dragon_name(decode_f16(raw))
        if c then out[#out+1] = c end
    end
    return out
end

local function resolve_identity(d, region)
    local key = actor_key(d)
    if not key then return nil end
    local cached = identity_cache[key]
    if cached and cached.region == region then return cached end
    local dragon = nil
    for _, cand in ipairs(identity_candidates(d)) do
        if region and loc_id(dragon_loc_name(region, cand)) then
            dragon = cand
            break
        end
    end
    if dragon and region then
        identity_cache[key] = {dragon = dragon, region = region}
        return identity_cache[key]
    end
    return nil
end

local rec_last_level = nil   -- last PLAYABLE map path seen (level-change detect)

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

    local dragons = safe(function() return FindAllOf("Collectable_Dragon_C") end)
    if not dragons then return end
    local new_checks = {}
    for _, d in ipairs(dragons) do
        if valid(d) then
            local collected = safe(function() return d["Collected_Dragons"] == true end, false)
            local ident = resolve_identity(d, region)
            local idkey = actor_key(d)
            if not ident and collected == true and idkey and not warned_identity[idkey] then
                warned_identity[idkey] = true
                local first = identity_candidates(d)[1]
                log.warn("unresolved dragon identity in " .. region ..
                    " (first candidate: " .. tostring(first) .. ")")
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
                        new_checks[#new_checks+1] = id
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

-- ---------------------------------------------------------------------------
-- per-poll entry point: one gamestate read feeds baseline readback, watcher
-- and reconcile, in that order (the drive acts on this tick's readback)
-- ---------------------------------------------------------------------------
local hb_ticks = 0

function M.tick(gs)
    if not valid(gs) then return end
    local map_path = safe(function() return gs["current level"]:ToString() end, nil)
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
        log.debug(string.format(
            "[RECONCILE] hb: %s | writes=%d reads=%d drift=%d skips(disarmed=%d no_baseline=%d) game=%s",
            rec_status(), rec.writes, rec.readbacks, rec.drift_corrections,
            rec.skips.disarmed, rec.skips.no_baseline,
            rec.last_skip_reason or "-"))
        rec.last_skip_reason = nil
    end
end

function M.status() return rec_status() end

-- a fresh session starts from nothing the previous save taught us; sent_checks
-- is shared with main.lua and NOT cleared here
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

function M.init(opts)
    log = logger.leveled("[DRAGONS]", opts and opts.log)
    regions = (opts and opts.regions) or regions
    loc_id = (opts and opts.loc_id) or loc_id
    log_sent = (opts and opts.log_sent) or log_sent
    send_checks = (opts and opts.send_checks) or send_checks
    if opts and opts.sent_checks then sent_checks = opts.sent_checks end
end

return M