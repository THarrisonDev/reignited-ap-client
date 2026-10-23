-- Author: Tim Harrison
-- Created: 2026-10-16
-- Updated: 2026-10-16

-- reconcile_core: the signed debug-extra reconcile drive shared by
-- spyro1/dragons.lua, spyro2/orbs.lua and spyro3/eggs_hud.lua. It keeps a
-- game-computed collectible count (dragons, orbs, eggs) equal to the received
-- AP items by writing the game's own signed debug-extra field through its
-- UFunction, re-asserting after every world transition (the engine zeroes the
-- field), and never writing before the level has been playable for two ticks
-- (a write on the load screen hardlocks the game). Writes are idempotent and
-- refused while disarmed / vanilla / no-baseline. The [RECONCILE] debug lines
-- are the live verification surface.

local U = require("util")
local logger = require("logger")
local O = require("option")

local SETTLE_TICKS = 2 -- polls the level must hold before any write (a write on
                       -- the load screen hardlocks the game)

--- Build a reconcile module for one collectible.
---
--- cfg: {game, tag (log tag), kind ("dragons"/"orbs"/"eggs"), item (AP item
---       name), save_type (EIT id), total (save-record domain), ufunction (the
---       debug-extra UFunction), property (raw fallback property), option_name
---       (slot-data key), option_label (legacy truthy string + arm-log word)}.
--- @return table
local function new(cfg)
    local M = {}

    local TAG = cfg.tag or "[RECONCILE]"
    local log = logger.tagged(TAG)

    local rec = {
        received = 0,           -- items received from the server
        save_collected = 0,     -- readback baseline + observed local pickups
        baseline_set = false,
        armed = false,
        sync = false,           -- slot data says this collectible's items exist
        last_extra = nil,       -- last value asked the game to hold
        writes = 0,             -- lifetime extra writes
        readbacks = 0,          -- lifetime save_collected readback polls
        drift_corrections = 0,  -- lifetime readback drift re-syncs
        skips = { disarmed = 0, no_baseline = 0 },
        last_skip_reason = nil, -- why the last tick didn't write (heartbeat line)
        -- world transitions ZERO the debug-extra field (live-proven), so the
        -- written value is stale after every level load even if it numerically
        -- matches. reasserts_pending counts transitions seen since the last
        -- successful write; drive re-asserts the target until it lands.
        reasserts_pending = 0,
        reasserts = 0,          -- lifetime level-change re-asserts written
        pending_readback = nil, -- first unconfirmed disagreeing readback (nil=none)
        readback_ok = false,    -- any successful in-level readback (type probe)
    }
    local seen_index = {}       -- AP item index -> true

    --- Arm the drive and log the slot-connect line.
    local function arm()
        rec.armed = true
        log.debug(
            string.format(
                "[RECONCILE] armed at slot-connect (%s): received=%d baseline=%s",
                cfg.option_label,
                rec.received,
                tostring(rec.save_collected)
            )
        )
    end

    --- Anchor save_collected to n on the first playable-level readback.
    local function set_baseline(n)
        if rec.baseline_set then
            return
        end
        rec.save_collected = n
        rec.baseline_set = true
        log.debug(string.format("[RECONCILE] baseline anchored: save_collected=%d (first playable-level readback)", n))
    end

    --- Return the one-line reconcile status for the poll heartbeat.
    --- @return string
    local function status()
        if not rec.armed then
            return "disarmed"
        end
        if not rec.sync then
            return "vanilla(off)"
        end
        if not rec.baseline_set then
            return "no_baseline"
        end
        return string.format(
            "extra=%s recv=%d save=%d reassert(pending=%d done=%d) drift=%d writes=%d reads=%d skips=%d skipped=%s",
            tostring(rec.last_extra),
            rec.received,
            rec.save_collected,
            rec.reasserts_pending,
            rec.reasserts,
            rec.drift_corrections,
            rec.writes,
            rec.readbacks,
            rec.skips.disarmed + rec.skips.no_baseline,
            tostring(rec.last_skip_reason or "-")
        )
    end

    --- Read the pure save-record count, excluding the debug extra. Returns nil
    --- when unreadable (the UE4SS out-param may be wrapped; U.prop unwraps it).
    --- @return number|nil
    local function read_save(gs)
        local out = {}
        local ok = pcall(function()
            gs["get inventory collected count"](cfg.save_type, "", true, out)
        end)
        if not ok then
            return nil
        end
        local c = U.prop(out, "Count")
        return type(c) == "number" and c or nil
    end

    --- Record one observed local pickup so the drive self-corrects next tick.
    function M.note_local_rescue()
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
    function M.note_level_change()
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
    --- @param world table game_state snapshot.
    --- @return number|nil
    --- Return extra clamped into the save record's domain.
    local function clamp_extra(raw)
        if raw < -cfg.total then return -cfg.total end
        if raw > cfg.total then return cfg.total end
        return raw
    end

    --- Write extra through the game's UFunction, falling back to the property.
    --- The UFunction also fires the HUD notify (a raw property write does not,
    --- so the displayed count would only refresh at the next transition).
    local function write_extra(gs, extra)
        local ok = pcall(function()
            gs[cfg.ufunction](extra, true)
        end)
        if ok then
            return true
        end
        return pcall(function()
            gs[cfg.property] = extra
        end)
    end

    --- Record a successful write and log it, or log the failure.
    local function finish_write(world, extra, ok)
        if not ok then
            log.error(
                string.format(
                    "[RECONCILE] write failed for extra=%d (received=%d save_collected=%d)",
                    extra,
                    rec.received,
                    rec.save_collected
                )
            )
            return
        end
        local prev = rec.last_extra
        rec.last_extra = extra
        rec.writes = rec.writes + 1
        local tag
        if rec.reasserts_pending > 0 then
            rec.reasserts = rec.reasserts + 1
            rec.reasserts_pending = 0
            tag = string.format(" re-assert #%d (level=%s)", rec.reasserts, world.region or world.path)
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
    end

    --- Record a skip reason and return nil; counted skips also bump the tally.
    local function skip(reason, counted)
        rec.last_skip_reason = reason
        if counted then
            rec.skips[reason] = rec.skips[reason] + 1
        end
        return nil
    end

    --- Write the computed extra when it differs (or a re-assert is pending).
    function M.drive(world)
        if not rec.armed or not rec.sync then
            return skip("disarmed", true)
        end
        if not rec.baseline_set then
            return skip("no_baseline", true)
        end
        local extra = clamp_extra(rec.received - rec.save_collected)
        if not world.playable then
            return skip("not_playable")
        end
        if world.ticks < SETTLE_TICKS then
            return skip("level_stabilizing")
        end
        -- Idempotence OR pending re-assert: after a level change the game zeroed
        -- the field, so a numerically-equal last_extra must still be re-written.
        if rec.last_extra == extra and rec.reasserts_pending == 0 then
            return nil
        end
        if not U.valid(world.gs) then
            return skip("game_not_ready")
        end
        local ok = write_extra(world.gs, extra)
        finish_write(world, extra, ok)
        if not ok then return nil end
        return extra
    end

    --- Anchor save_collected on the first playable-level read and re-sync it on
    --- confirmed drift, healing missed pickups without touching rec.received. A
    --- disagreeing read is applied only on a second consecutive agreement, since
    --- mid-transition reads can return transient garbage. Load-screen and unknown
    --- map reads are ignored.
    --- @param world table game_state snapshot.
    function M.anchor(world)
        if not U.valid(world.gs) then
            return
        end
        if not world.playable then
            return
        end
        local n = read_save(world.gs)
        -- domain guard: the count lives in [0, cfg.total]; anything else is a bad
        -- readback (wrong type routing / unwrapped garbage) and must not touch
        -- the engine
        if n == nil or n < 0 or n > cfg.total then
            return
        end
        if not rec.readback_ok then
            rec.readback_ok = true
            log.debug(string.format("[RECONCILE] type-%d readback live: first Count=%d (probe settled)", cfg.save_type, n))
        end
        rec.readbacks = rec.readbacks + 1
        if not rec.baseline_set then
            set_baseline(n)
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

    --- Count a received item once per AP item index; ReceivedItems is cumulative,
    --- so every packet re-delivers index 0..n. Return true when new.
    --- @return boolean
    function M.note_item(name, index)
        if index ~= nil then
            if seen_index[index] then
                return false
            end
            seen_index[index] = true
        end
        if name == cfg.item then
            rec.received = rec.received + 1
        end
        return true
    end

    --- Return whether name is this module's item.
    --- @return boolean
    function M.is_item(name)
        return name == cfg.item
    end

    --- Return the number of items received this session.
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
    --- exact-once (a mid-session reconnect re-delivers every item).
    function M.reset_received()
        rec.received = 0
        seen_index = {}
    end

    --- Re-arm on the first post-reconnect ReceivedItems batch, so counting starts
    --- from 0 exactly when the recount begins.
    function M.arm_backlog()
        if rec.sync and not rec.armed then
            arm()
        end
    end

    --- Stop reconcile writes while disconnected; arm_backlog re-arms.
    function M.note_disconnected()
        rec.armed = false
    end

    --- Read this collectible's option from slot data, arm when in that game's
    --- session, and log the slot config.
    function M.configure(slot_data, in_session)
        local opts = O.game_options(slot_data, cfg.game)
        local val = opts[cfg.option_name]
        rec.sync = O.flag(val, cfg.option_name, log, cfg.option_label)
        log.debug(
            string.format(
                "[RECONCILE] slot config: sync_%s=%s (%s=%s)",
                cfg.kind,
                tostring(rec.sync),
                cfg.option_name,
                tostring(val)
            )
        )
        -- arm at slot-connect, not on the backlog: a fresh shuffled seed may never
        -- send a ReceivedItems packet, so backlog-arming could never activate the
        -- neutralization. A reconnect (baseline set) waits for arm_backlog so the
        -- recount starts when received = 0.
        if rec.sync and in_session and not rec.baseline_set then
            arm()
        end
    end

    --- Run the drive for a session with no actor watcher (Spyro 2/3): note the
    --- world transition, anchor the readback, then drive the counter.
    --- @param world table game_state snapshot.
    function M.tick(world)
        if not world.ok then
            return
        end
        if world.changed then
            M.note_level_change()
        end
        M.anchor(world)
        M.drive(world)
    end

    --- Return the reconcile status line.
    --- @return string
    function M.status()
        return status()
    end

    --- Reset per-session reconcile state.
    function M.reset()
        rec.received, rec.save_collected, rec.baseline_set, rec.armed = 0, 0, false, false
        rec.last_extra, rec.reasserts_pending = nil, 0
        rec.pending_readback = nil
        rec.skips.disarmed, rec.skips.no_baseline = 0, 0
        rec.last_skip_reason = nil
        rec.readback_ok = false
        seen_index = {}
    end

    --- Bind the logger from opts {log}.
    function M.init(opts)
        log = logger.leveled(TAG, opts and opts.log)
    end

    M.tag = TAG
    return M
end

return { new = new }
