-- Author: Tim Harrison
-- Created: 2026-09-27
-- Updated: 2026-10-11

-- eggs_hud (Spyro 3): drive the signed debug-extra egg counter so the HUD
-- matches the received Dragon Egg items (spyro3_egg_shuffle). Display only:
-- it leaves the pure save record the egg gates read untouched, so it can never
-- open a door. Writes on the poll thread, gated on a stable playable level
-- (writes on the load screen hardlock).

local U = require("util")
local logger = require("logger")

local M = {}

local S3_PREFIX = "Spyro 3: "
local ITEM_EGG = S3_PREFIX .. "Dragon Egg"
local EGG_SAVE_TYPE = 29  -- EIT_S3Egg.
local EGG_TOTAL = 146     -- Shuffled non-boss eggs (boss eggs are EIT_S3Boss).

local log = logger.tagged("[EGGHUD]")

-- ---------------------------------------------------------------------------
-- Reconcile
-- ---------------------------------------------------------------------------
local rec = {
    received = 0,            -- Dragon Egg items received from the server.
    save_collected = 0,      -- Readback baseline (pure save-record count).
    baseline_set = false,
    armed = false,
    sync_eggs = false,       -- Slot data says Dragon Egg items exist (egg_shuffle).
    last_extra = nil,
    writes = 0,
    readbacks = 0,
    drift_corrections = 0,
    skips = { disarmed = 0, no_baseline = 0 },
    last_skip_reason = nil,
    reasserts_pending = 0,
    reasserts = 0,
    stable_ticks = 0,
    last_write_level = nil,
    pending_readback = nil,
    readback_ok = false,
}

--- Arm the reconcile and log the slot-connect state.
local function rec_arm()
    rec.armed = true
    log.debug(string.format(
        "[RECONCILE] armed at slot-connect (egg_shuffle): received=%d baseline=%s",
        rec.received, tostring(rec.save_collected)))
end

--- Mark the counter drive invalid after a level change so it is re-asserted.
local function rec_note_level_change()
    if rec.last_extra ~= nil or rec.reasserts_pending > 0 then
        rec.reasserts_pending = rec.reasserts_pending + 1
        log.debug(string.format(
            "[RECONCILE] level change: drive invalidated (pending re-assert #%d, target=%d)",
            rec.reasserts_pending, rec.received - rec.save_collected))
    end
end

--- Write the extra-egg counter when it changed and the level is stable;
--- return the applied value or nil when skipped.
--- @return number|nil
local function rec_tick(cur_level, gs)
    if not rec.armed or not rec.sync_eggs then
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
    if extra < -EGG_TOTAL then extra = -EGG_TOTAL end
    if extra > EGG_TOTAL then extra = EGG_TOTAL end

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

    if rec.last_extra == extra and rec.reasserts_pending == 0 then
        return nil
    end
    if not U.valid(gs) then
        rec.last_skip_reason = "game_not_ready"
        return nil
    end
    local ok = pcall(function() gs["debug - add s3 eggs"](extra, true) end)
    if not ok then
        ok = pcall(function() gs["debug extra s3 eggs"] = extra end)
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

--- Return one heartbeat line of reconcile state.
--- @return string
local function rec_status()
    if not rec.armed then return "disarmed" end
    if not rec.sync_eggs then return "vanilla(off)" end
    if not rec.baseline_set then return "no_baseline" end
    return string.format("extra=%s recv=%d save=%d reassert(pending=%d done=%d) drift=%d",
        tostring(rec.last_extra), rec.received, rec.save_collected,
        rec.reasserts_pending, rec.reasserts, rec.drift_corrections)
end

--- Return the pure egg save-record count, or nil when unreadable. Excludes
--- debug_extra; UE4SS sometimes wraps the out-param in a table, so unwrap
--- .value when it does.
--- @return number|nil
local function rec_read_save_collected(gs)
    local out = {}
    local ok = pcall(function() gs["get inventory collected count"](EGG_SAVE_TYPE, "", true, out) end)
    if not ok then return nil end
    local c = U.safe(function() return out["Count"] end, nil)
    if type(c) == "number" then return c end
    if type(c) == "table" then
        local inner = U.safe(function() return c.value end, nil)
        if type(inner) == "number" then return inner end
    end
    return nil
end

--- Anchor the save-record baseline and re-sync on two consecutive drifted
--- reads.
local function rec_anchor_baseline(gs, map_path)
    if not U.valid(gs) then return end
    if not (map_path and map_path ~= "") then return end
    local n = rec_read_save_collected(gs)
    -- The shuffled egg pool is [0,146]; anything else is a bad readback.
    if n == nil or n < 0 or n > EGG_TOTAL then return end
    if not rec.readback_ok then
        rec.readback_ok = true
        log.debug(string.format(
            "[RECONCILE] type-29 readback live: first Count=%d (probe settled)", n))
    end
    rec.readbacks = rec.readbacks + 1
    if not rec.baseline_set then
        rec.save_collected = n
        rec.baseline_set = true
        rec.pending_readback = nil
        log.debug(string.format(
            "[RECONCILE] baseline anchored: save_collected=%d (first playable-level readback)", n))
        return
    end
    if n == rec.save_collected then
        rec.pending_readback = nil
        return
    end
    -- A read that disagrees with the baseline needs a second consecutive
    -- confirmation before we re-sync.
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
            n, rec.save_collected, rec.received))
    end
end

-- Exact-once per AP item index: ReceivedItems is cumulative, and each packet
-- re-delivers indexes 0..n, so only count new ones.
local seen_index = {}   -- AP item index -> true.

--- Count a Dragon Egg item once per AP item index.
--- @return boolean
function M.note_item(name, index)
    if index ~= nil then
        if seen_index[index] then return false end
        seen_index[index] = true
    end
    if name == ITEM_EGG then
        rec.received = rec.received + 1
    end
    return true
end

--- Return whether name is the Dragon Egg item.
--- @return boolean
function M.is_egg(name) return name == ITEM_EGG end
--- Return the number of Dragon Egg items received.
--- @return number
function M.received() return rec.received end
--- Return the last counter value written, or nil.
--- @return number|nil
function M.last_extra() return rec.last_extra end

--- Zero the received count for the exact-once backlog recount.
-- Reconnects zero the received count so the cumulative backlog recount
-- stays exact-once.
--- Zero the received count for the exact-once backlog recount.
function M.reset_received()
    rec.received = 0
    seen_index = {}
end

-- Fresh sessions arm at slot-connect (M.configure); a reconnect re-arms
-- here on the first post-reconnect ReceivedItems batch.
--- Re-arm on the first post-reconnect ReceivedItems batch.
function M.arm_backlog()
    if rec.sync_eggs and not rec.armed then
        rec_arm()
    end
end

-- Do not write while disconnected; arm_backlog re-arms on reconnect.
--- Disarm writing while disconnected.
function M.note_disconnected()
    rec.armed = false
end

--- Read egg_shuffle from slot data and arm a fresh S3 session.
function M.configure(slot_data, in_s3_session)
    local opts = {}
    if slot_data and type(slot_data.games) == "table" and type(slot_data.games.spyro3) == "table" then
        opts = slot_data.games.spyro3.options or {}
    end
    local val = opts.egg_shuffle
    rec.sync_eggs = (val == "egg_shuffle") or (val == 1) or (val == true)
    log.debug(string.format("[RECONCILE] slot config: sync_eggs=%s (egg_shuffle=%s)",
        tostring(rec.sync_eggs), tostring(val)))
    if rec.sync_eggs and in_s3_session and not rec.baseline_set then
        rec_arm()
    end
end

-- One gamestate read per poll: the baseline readback runs first, then the
-- reconcile acts on it.
local hb_ticks = 0
local rec_last_level = nil   -- Last playable map path seen, for level-change detection.

--- Anchor the baseline, drive the counter, and emit the periodic heartbeat.
function M.tick(gs)
    if not U.valid(gs) then return end
    local map_path = U.safe(function() return gs["current level"]:ToString() end, nil)
    local playable = map_path and map_path:match("^/LS%d+_.-/Maps/") or nil

    hb_ticks = hb_ticks + 1
    local hb_now = rec.armed and (hb_ticks % 480 == 0)

    if playable then
        if rec_last_level and rec_last_level ~= playable then
            rec_note_level_change()
        end
        rec_last_level = playable
    else
        if rec_last_level then
            rec_note_level_change()
            rec_last_level = nil
        end
    end

    rec_anchor_baseline(gs, playable)
    rec_tick(playable, gs)

    if hb_now then
        log.debug(string.format(
            "[RECONCILE] hb: %s | writes=%d reads=%d drift=%d skips(disarmed=%d no_baseline=%d) game=%s",
            rec_status(), rec.writes, rec.readbacks, rec.drift_corrections,
            rec.skips.disarmed, rec.skips.no_baseline,
            rec.last_skip_reason or "-"))
        rec.last_skip_reason = nil
    end
end

--- Return one heartbeat line of reconcile state.
--- @return string
function M.status() return rec_status() end

--- Clear all reconcile state for a fresh session with no save knowledge.
function M.reset()
    rec.received, rec.save_collected, rec.baseline_set, rec.armed = 0, 0, false, false
    rec.last_extra, rec.reasserts_pending, rec.stable_ticks = nil, 0, 0
    rec.last_write_level, rec.pending_readback = nil, nil
    rec.skips.disarmed, rec.skips.no_baseline = 0, 0
    rec.last_skip_reason = nil
    rec.readback_ok = false
    rec_last_level = nil
    seen_index = {}
end

--- Set the leveled logger.
function M.init(opts)
    log = logger.leveled("[EGGHUD]", opts and opts.log)
end

return M
