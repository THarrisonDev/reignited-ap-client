-- inventory_grants_core: factory behind the per-game global-inventory item
-- modules (spyro2/abilities.lua, spyro3/sparx_powers.lua). It forces each
-- item's owned flag to match the received set via the gamestate inventory
-- UFunctions, reconciling vanilla grants back off until the AP item arrives
-- (docs/game_state_control.md §9.1).

local U = require("util")
local logger = require("logger")

local STABLE_TICKS = 8      -- x 250ms poll: never write until the level has held 2s
local JOB_TIMEOUT = 5       -- seconds before an unfinished job is abandoned (and failed-job backoff)

--- Build a global-inventory item module for one game.
--- @return table
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

    --- Return the owned flag target (1 owned, 0 not) for name.
    local function target_for(name)
        return has_received[name] and 1 or 0
    end

    --- Return the target to drive name to, or nil when cur already matches it
    --- or a revoke already failed this session (never retried).
    local function drive(name, cur)
        local target = target_for(name)
        if cur == target or (target == 0 and revoke_failed[name]) then return nil end
        return target
    end

    --- Read back and, if needed, write one item's owned flag on the game
    --- thread.
    --- @return string|nil "ok" when a write landed, "failed" on readback/write
    ---   failure, nil otherwise.
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

    --- Run every item's write; returning false (any item failed) backs the
    --- runner off.
    local function run_job(gs)
        local all_ok = true
        for name, eit in pairs(ITEMS) do
            if run_item(gs, name, eit) == "failed" then all_ok = false end
        end
        return all_ok
    end

    --- Submit the batch reconcile job for gs to the game-thread runner.
    local function submit(gs)
        jobs.submit(function() return run_job(gs) end)
    end

    --- Wire the injected logger and region map, and detect the game-thread
    --- write API.
    function M.init(opts)
        log = logger.leveled(TAG, opts and opts.log)
        regions = (opts and opts.regions) or {}
        can_write = type(ExecuteInGameThread) == "function"
        if not can_write then
            log.error("ExecuteInGameThread unavailable — " .. cfg.disabled)
        end
    end

    --- Read this game's option from slot data and reset per-session state.
    function M.configure(sd)
        enabled = cfg.option(sd) and true or false
        received, has_received, applied, warned, revoke_failed = {}, {}, {}, {}, {}
        cur_path, stable_ticks = nil, 0
        log.info(string.format("configured: %s=%s", cfg.flag, tostring(enabled)))
    end

    --- Mark a received AP item as owned for this session (deduped by index).
    function M.note_item(name, index)
        if ITEMS[name] == nil then return end
        if index ~= nil and received[index] then return end
        if index ~= nil then received[index] = true end
        has_received[name] = true
        log.debug(string.format("%s received (index %s)", name, tostring(index)))
    end

    --- Poll gs: once the level is known and stable, decide which items drift
    --- from their target and submit a reconcile job (with a one-shot early
    --- WARN per item).
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

    --- Return a one-line heartbeat summary of received items and the option.
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
