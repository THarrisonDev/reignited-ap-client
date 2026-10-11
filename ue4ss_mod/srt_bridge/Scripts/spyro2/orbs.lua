-- Author: Tim Harrison
-- Created: 2026-09-27
-- Updated: 2026-10-11

-- spyro2 orbs: the signed debug_extra_orbs reconcile (spyro2_orb_shuffle;
-- spec = tests/lua/test_orbs.lua). Drives the orb counter so the game's orb
-- doors open on received Orb items, following the Spyro 1 dragon pattern
-- (spyro1/dragons.lua). Orb checks themselves are checkd's (the save's
-- EIT_S2GreenOrb records). Threading: async poll thread, gated on a stable
-- playable level like dragons.lua (writes on the load screen hardlock).
--
-- API (main.lua): init{log}, configure(slot_data, in_s2_session),
-- note_item(name, index), is_orb(name), received(), last_extra(),
-- arm_backlog(), reset_received(), note_disconnected(), tick(gs), reset(),
-- status(). UNPROVEN live: that the type-23 readback anchors and that the orb
-- doors read save+extra; a readback that never anchors leaves the module inert
-- (vanilla counters, server-side logic still routes the doors through items).

local U = require("util")
local logger = require("logger")

local M = {}

local S2_PREFIX = "Spyro 2: "
local ITEM_ORB = S2_PREFIX .. "Orb"
local ORB_SAVE_TYPE = 23  -- EIT_S2GreenOrb: the save-record type checkd scans
local ORB_TOTAL = 64

local log = logger.tagged("[ORBS2]")

-- ---------------------------------------------------------------------------
-- reconcile (signed debug_extra_orbs drive; shape = spyro1/dragons.lua rec)
-- ---------------------------------------------------------------------------
local rec = {
    received = 0,            -- Orb items received from the server
    save_collected = 0,      -- readback baseline (pure save-record count)
    baseline_set = false,
    armed = false,
    sync_orbs = false,       -- slot data says Orb items exist (orb_shuffle)
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
    pending_readback = nil,  -- first unconfirmed disagreeing readback
    readback_ok = false,     -- any successful in-level readback (type probe)
}

--- Arm the reconcile and log the slot-connect debug line.
local function rec_arm()
    rec.armed = true
    log.debug(string.format(
        "[RECONCILE] armed at slot-connect (orb_shuffle): received=%d baseline=%s",
        rec.received, tostring(rec.save_collected)))
end

--- Mark the drive invalid after a world transition, so the next stable tick
--- re-asserts the target (the game zeroes the field at transitions).
local function rec_note_level_change()
    if rec.last_extra ~= nil or rec.reasserts_pending > 0 then
        rec.reasserts_pending = rec.reasserts_pending + 1
        log.debug(string.format(
            "[RECONCILE] level change: drive invalidated (pending re-assert #%d, target=%d)",
            rec.reasserts_pending, rec.received - rec.save_collected))
    end
end

--- Make one reconcile decision and write, returning the extra written or nil.
--- cur_level is the caller's playable-level path (nil = not playable).
--- @return number|nil
local function rec_tick(cur_level, gs)
    if not rec.armed or not rec.sync_orbs then
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
    if extra < -ORB_TOTAL then extra = -ORB_TOTAL end
    if extra > ORB_TOTAL then extra = ORB_TOTAL end

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
    local ok = pcall(function() gs["debug - add s2 orbs"](extra, true) end)
    if not ok then
        ok = pcall(function() gs["debug_extra_orbs"] = extra end)
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

--- Return the one-line reconcile status for the poll heartbeat.
--- @return string
local function rec_status()
    if not rec.armed then return "disarmed" end
    if not rec.sync_orbs then return "vanilla(off)" end
    if not rec.baseline_set then return "no_baseline" end
    return string.format("extra=%s recv=%d save=%d reassert(pending=%d done=%d) drift=%d",
        tostring(rec.last_extra), rec.received, rec.save_collected,
        rec.reasserts_pending, rec.reasserts, rec.drift_corrections)
end

--- Read the pure orb save-record count, excluding debug_extra; unwrap the
--- UE4SS out-param table wrapper. Returns nil when unreadable.
--- @return number|nil
local function rec_read_save_collected(gs)
    local out = {}
    local ok = pcall(function() gs["get inventory collected count"](ORB_SAVE_TYPE, "", true, out) end)
    if not ok then return nil end
    local c = U.safe(function() return out["Count"] end, nil)
    if type(c) == "number" then return c end
    if type(c) == "table" then
        local inner = U.safe(function() return c.value end, nil)
        if type(inner) == "number" then return inner end
    end
    return nil
end

--- Anchor save_collected on the first playable-level read and re-sync it on
--- confirmed drift, healing missed rescues without touching rec.received. A
--- disagreeing read is applied only on a second consecutive agreement.
local function rec_anchor_baseline(gs, map_path)
    if not U.valid(gs) then return end
    if not (map_path and map_path ~= "") then return end
    local n = rec_read_save_collected(gs)
    -- domain guard: orbs live in [0,64]; anything else is a bad readback
    -- (wrong type routing / unwrapped garbage) and must not touch the engine
    if n == nil or n < 0 or n > ORB_TOTAL then return end
    if not rec.readback_ok then
        rec.readback_ok = true
        log.debug(string.format(
            "[RECONCILE] type-23 readback live: first Count=%d (probe settled)", n))
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
            n, rec.save_collected, rec.received))
    end
end

local seen_index = {}   -- AP item index -> true

--- Count a received Orb once per AP item index; ReceivedItems is cumulative,
--- so every packet re-delivers index 0..n. Return true when new.
--- @return boolean
function M.note_item(name, index)
    if index ~= nil then
        if seen_index[index] then return false end
        seen_index[index] = true
    end
    if name == ITEM_ORB then
        rec.received = rec.received + 1
    end
    return true
end

--- Return whether name is the shared Orb item.
--- @return boolean
function M.is_orb(name) return name == ITEM_ORB end

--- Return the number of Orb items received this session.
--- @return number
function M.received() return rec.received end

--- Return the last extra value written, or nil.
--- @return number|nil
function M.last_extra() return rec.last_extra end

--- Zero the received count on reconnect so the cumulative backlog recount is
--- exact-once (a mid-session reconnect re-delivers every Orb).
function M.reset_received()
    rec.received = 0
    seen_index = {}
end

--- Re-arm on the first post-reconnect ReceivedItems batch, so counting starts
--- from 0 exactly when the recount begins.
function M.arm_backlog()
    if rec.sync_orbs and not rec.armed then
        rec_arm()
    end
end

--- Stop reconcile writes while disconnected; arm_backlog re-arms.
function M.note_disconnected()
    rec.armed = false
end

--- Read the orb_shuffle option from slot data, arm when in a Spyro 2 session,
--- and log the slot config.
function M.configure(slot_data, in_s2_session)
    local opts = {}
    if slot_data and type(slot_data.games) == "table" and type(slot_data.games.spyro2) == "table" then
        opts = slot_data.games.spyro2.options or {}
    end
    local val = opts.orb_shuffle
    -- slot data carries the option name ("orb_shuffle") or truthy ordinal
    rec.sync_orbs = (val == "orb_shuffle") or (val == 1)
    log.debug(string.format("[RECONCILE] slot config: sync_orbs=%s (orb_shuffle=%s)",
        tostring(rec.sync_orbs), tostring(val)))
    if rec.sync_orbs and in_s2_session and not rec.baseline_set then
        rec_arm()
    end
end

-- per-poll entry point: one gamestate read feeds baseline readback and
-- reconcile, in that order (the drive acts on this tick's readback)
local hb_ticks = 0
local rec_last_level = nil   -- last PLAYABLE map path seen (level-change detect)

--- Run one poll: detect level changes, then baseline readback and reconcile.
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

--- Return the reconcile status line.
--- @return string
function M.status() return rec_status() end

--- Reset per-session reconcile state.
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

--- Bind the logger from opts {log}.
function M.init(opts)
    log = logger.leveled("[ORBS2]", opts and opts.log)
end

return M