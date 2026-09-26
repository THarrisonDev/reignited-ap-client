-- inventory_grants_core: the shared implementation behind the per-game
-- global-inventory item modules (spyro2/abilities.lua, spyro3/sparx_powers.lua).
-- One factory, parameterized by game config; the wrappers only supply: log
-- tag, item name -> EInventoryType table, slot-data option reader, status
-- short names and the log wording.
--
-- Reignited stores these as global-inventory records: unowned
-- collected=False param 0.0, owned collected=True param 1.0. The gamestate's
-- inventory UFunctions route types 30-33 and 45-49 to update param count on
-- the gamestate's own save object (docs/game_state_control.md §9.1), so:
--   grant:    add item to player inventory(EIT, 1)     (fillers-proven shape)
--   revoke:   remove from player inventory(EIT, 1)
--   readback: get player inventory item count(EIT, false, out) — pure save
--   state for these types (no debug_extra_* fields exist for them).
-- Only the types in the wrapper's table are ever read or written.
--
-- When the option is on, the owned flag of each item is forced to match the
-- received set: the vanilla grant (a Money Bags purchase, a Sparx realm
-- completion) cannot be prevented at the source, so it flips the flag on, the
-- reconcile writes it back off within a poll tick or two, and a one-shot WARN
-- tells the player why. Once the AP item arrives, the flag sticks on for real.
-- Option off = the module does nothing.
--
-- THREADING (level_locks/fillers lesson): the async tick only reads and
-- decides; all writes run inside ONE ExecuteInGameThread job at a time, each
-- write preceded by a fresh game-thread readback. Writes wait for a known
-- level that has held STABLE_TICKS; a level change clears the applied memory
-- so the drive is re-asserted (the game re-restores state at transitions).
-- U.job_runner: an unrun job is abandoned after JOB_TIMEOUT; a job that threw
-- or had a failed readback/write backs off JOB_TIMEOUT. A failed revoke is
-- recorded per item and that revoke is not attempted again (neither decided
-- nor written) until configure starts a new session; the item's grant, once
-- received, still lands.
--
-- API (via the per-game module): init{log, regions}, configure(slot_data) on
-- slot connect, note_item(name, index) per received item, tick(gamestate)
-- from the poll loop, status() for the heartbeat. log is a leveled logger
-- (tagged by cfg.tag) or the spec's collector function; warn/error reach the
-- console.

local U = require("util")
local logger = require("logger")

local STABLE_TICKS = 8      -- x 250ms poll: never write until the level has held 2s
local JOB_TIMEOUT = 5       -- seconds before an unfinished job is abandoned (and failed-job backoff)

local function new(cfg)
    -- cfg: {tag = "[ABILITIES]", items = {name = eit},
    --        option = function(slot_data) -> bool, flag = "sanity" (status/log),
    --        short = function(name) -> status short name,
    --        disabled = "ability items disabled" (no game-thread API),
    --        revoked = "... neutralized" (revoke log reason),
    --        revoke_stays = "(won't retry ...)" (revoke-failed suffix),
    --        early = " purchased without ..." (early-grant WARN, after the name)}

    local M = {}
    local TAG = cfg.tag
    local ITEMS = cfg.items

    local log = logger.tagged(TAG)
    local regions = {}          -- map path -> region (generated regions.lua)
    local can_write = false     -- ExecuteInGameThread available
    local enabled = false       -- slot data says the items are shuffled
    local received = {}         -- AP item index -> true (this module's items, this session)
    local has_received = {}     -- item name -> true (ever received this session)
    local applied = {}          -- item name -> last target successfully written
    local warned = {}           -- item name -> early-grant WARN already logged
    local revoke_failed = {}    -- item name -> remove-from-inventory failed: no revoke retry this session
    local cur_path, stable_ticks = nil, 0
    local jobs = U.job_runner{log = function() return log end, timeout = JOB_TIMEOUT}

    local safe = U.safe
    local num = U.prop

    local function target_for(name)
        return has_received[name] and 1 or 0
    end

    -- a revoke that already failed this session is never retried
    local function drive(name, cur)
        local target = target_for(name)
        if cur == target or (target == 0 and revoke_failed[name]) then return nil end
        return target
    end

    -- one item's fresh readback + write, game thread. Returns "ok" when a
    -- write landed, "failed" when a readback or write failed, nil otherwise.
    local function run_item(gs, name, eit)
        local out = {}
        local okR = pcall(function() gs["get player inventory item count"](eit, false, out) end)
        if not okR then
            log.error("readback failed for " .. name .. "; skipping this tick")
            return "failed"
        end
        local cur = num(out, "item count")
        if cur ~= 0 and cur ~= 1 then return nil end
        local target = drive(name, cur)
        if target == nil then return nil end
        local okW
        if target == 1 then
            okW = pcall(function() gs["add item to player inventory"](eit, 1) end)
        else
            okW = pcall(function() gs["remove from player inventory"](eit, 1) end)
        end
        if not okW then
            if target == 0 then
                revoke_failed[name] = true
                log.error("revoke failed for " .. name .. " " .. cfg.revoke_stays)
            else
                log.error("write failed for " .. name)
            end
            return "failed"
        end
        applied[name] = target
        local why = target == 1 and "received" or cfg.revoked
        log.info(string.format("%s: %d -> %d (%s)", name, cur, target, why))
        return "ok"
    end

    -- false (any item failed) backs the runner off
    local function run_job(gs)
        local all_ok = true
        for name, eit in pairs(ITEMS) do
            if run_item(gs, name, eit) == "failed" then all_ok = false end
        end
        return all_ok
    end

    local function submit(gs)
        jobs.submit(function() return run_job(gs) end)
    end

    function M.init(opts)
        log = logger.leveled(TAG, opts and opts.log)
        regions = (opts and opts.regions) or {}
        can_write = type(ExecuteInGameThread) == "function"
        if not can_write then
            log.error("ExecuteInGameThread unavailable — " .. cfg.disabled)
        end
    end

    function M.configure(sd)
        enabled = cfg.option(sd) and true or false
        received, has_received, applied, warned, revoke_failed = {}, {}, {}, {}, {}
        cur_path, stable_ticks = nil, 0
        log.info(string.format("configured: %s=%s", cfg.flag, tostring(enabled)))
    end

    function M.note_item(name, index)
        if ITEMS[name] == nil then return end
        if index ~= nil and received[index] then return end
        if index ~= nil then received[index] = true end
        has_received[name] = true
        log.debug(string.format("%s received (index %s)", name, tostring(index)))
    end

    function M.tick(gs)
        if not can_write or not enabled then return end
        local path = safe(function() return gs["current level"]:ToString() end, nil)
        if path ~= cur_path then
            cur_path, stable_ticks, applied = path, 0, {}
            return
        end
        if not (path and regions[path]) then return end
        stable_ticks = stable_ticks + 1
        if stable_ticks < STABLE_TICKS then return end
        if not jobs.ready() then return end

        -- async-side decide: what is owned vs what should be?
        local out = {}
        local mismatch, early = false, nil
        for name, eit in pairs(ITEMS) do
            local okR = pcall(function() gs["get player inventory item count"](eit, false, out) end)
            if okR then
                local cur = num(out, "item count")
                if cur == 0 or cur == 1 then
                    local target = drive(name, cur)
                    if target ~= nil then
                        mismatch = true
                        if cur == 1 and target == 0 and not warned[name] then
                            warned[name] = true
                            early = name
                        end
                    end
                end
            end
        end
        if early then
            log.warn(early .. cfg.early)
        end
        if mismatch then submit(gs) end
    end

    function M.status()
        local parts = {}
        for name in pairs(ITEMS) do
            parts[#parts + 1] = string.format("%s=%s", cfg.short(name),
                has_received[name] and "recv" or "-")
        end
        table.sort(parts)
        return table.concat(parts, " ") .. " " .. cfg.flag .. "=" .. tostring(enabled)
    end

    return M
end

return {new = new}
