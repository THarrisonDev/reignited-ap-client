-- Author: Tim Harrison
-- Created: 2026-11-03
-- Updated: 2026-11-03

-- guidebook_core: factory behind the per-game spyroN/guidebook.lua modules. It
-- marks a received level key's level as visited in the game, so the level is
-- listed in the in-game Guide Book before the player has ever entered it. With
-- the slot's Open World option on it also marks every homeworld visited, so the
-- Guide Book's own travel lists the hubs; the book's jump is the game's feature
-- (do level jump -> begin level load), not something this mod drives.
--
-- The write is the gamestate's own `set level visited`, the call `complete
-- level load` makes (it is not `save progression`, which stays banned). Every
-- write is read back on the game thread, so a refused write is retried after
-- the job runner's backoff, never dropped: the key is held for the session.

local U = require("util")
local logger = require("logger")
local O = require("option")

local STABLE_TICKS = 8      -- x 250ms poll: never write until the level has held 2s
local JOB_TIMEOUT = 5       -- seconds before an unfinished job is abandoned (and failed-job backoff)

--- Build a guide-book visit module for one game.
--- @return table
local function new(cfg)
    -- cfg: {game = "spyro1", tag = "[GUIDE]", label = " (spyro2)", prefix = "spyro2 "}

    local M = {}

    local TAG = cfg.tag or "[GUIDE]"
    local log = logger.tagged(TAG)
    local region_to_path = {}   -- "Stone Hill" -> "/LS102_StoneHill/Maps/"
    local homeworlds = cfg.homeworlds or {} -- region -> true (constants.lua)
    local key_to_region = {}    -- key item name -> region, this seed
    local key_count = 0
    local can_write = false     -- ExecuteInGameThread available
    local enabled = false
    local held = {}             -- region -> true (key received this session)
    local pending = {}          -- region -> true (visit still due)
    local listed = {}           -- region -> true (readback confirmed)
    local retries = {}          -- region -> failed readback count
    local warned = {}           -- region -> true (no-path WARN already logged)
    local jobs = U.job_runner{log = function() return log end, timeout = JOB_TIMEOUT}

    -- -----------------------------------------------------------------------
    -- game-thread work (only ever called from inside a job)
    -- -----------------------------------------------------------------------
    --- Return whether the game now reports path as visited.
    local function read_visited(gs, path)
        local out = {}
        gs["get level visited"](path, out)
        return U.prop(out, "visited") == true
    end

    --- Mark path visited for region and read it back. Returns false while the
    --- game has not recorded the visit, so the runner backs off and retries.
    local function run_job(gs, region, path)
        if not U.valid(gs) then return false end
        gs["set level visited"](path)
        if read_visited(gs, path) then
            pending[region] = nil
            listed[region] = true
            log.info(region .. " now listed in the guide book")
            return true
        end
        local n = (retries[region] or 0) + 1
        retries[region] = n
        if n <= 3 or n % 20 == 0 then
            log.warn(string.format("%s visit write not reflected (#%d)", region, n))
        end
        return false
    end

    --- Submit the visit job for region to the game-thread runner.
    local function submit(gs, region, path)
        jobs.submit(function() return run_job(gs, region, path) end,
            {desc = "visit job for " .. region, fail = "visit " .. region})
    end

    -- -----------------------------------------------------------------------
    -- decisions (async thread: reads only)
    -- -----------------------------------------------------------------------
    --- Drop a pending region whose key never resolved to a level path, warning
    --- once. A queued region has no key left to make it valid later.
    local function drop(region)
        pending[region] = nil
        if warned[region] then return end
        warned[region] = true
        log.warn("no level path for " .. region .. "; guide book visit dropped")
    end

    --- Submit one pending region's visit; returns whether a job was submitted.
    local function plan_pending(gs)
        for region in pairs(pending) do
            local path = region_to_path[region]
            if path == nil then
                drop(region)
            else
                submit(gs, region, path)
                return true
            end
        end
        return false
    end

    -- -----------------------------------------------------------------------
    -- API
    -- -----------------------------------------------------------------------
    --- Wire the injected logger and invert the region map into level paths, and
    --- detect the game-thread write API.
    function M.init(opts)
        log = logger.leveled(TAG, opts and opts.log)
        region_to_path = {}
        for path, region in pairs(opts and opts.regions or {}) do
            if type(path) == "string" and type(region) == "string" and region_to_path[region] == nil then
                region_to_path[region] = path
            end
        end
        can_write = U.can_write()
        if not can_write then
            log.error("ExecuteInGameThread unavailable — guide book visits disabled")
        end
    end

    --- Queue one visit per homeworld the region table knows (Open World: the
    --- Guide Book's travel list then carries the hubs).
    local function queue_homeworlds()
        for region in pairs(homeworlds) do
            if region_to_path[region] ~= nil then pending[region] = true end
        end
    end

    --- Read this game's level keys from slot data and reset per-session state.
    function M.configure(sd)
        key_to_region, key_count = {}, 0
        local raw = O.game_data(sd, cfg.game).level_keys
        for region, key in pairs(type(raw) == "table" and raw or {}) do
            if type(region) == "string" and type(key) == "string" then
                key_to_region[key] = region
                key_count = key_count + 1
            end
        end
        local open_world = O.flag(O.game_options(sd, cfg.game).open_world, "open_world", log)
        held, pending, listed, retries, warned = {}, {}, {}, {}, {}
        if open_world then queue_homeworlds() end
        enabled = can_write and (key_count > 0 or open_world)
        log.info(string.format("configured%s: enabled=%s keys=%d open_world=%s",
            cfg.label, tostring(enabled), key_count, tostring(open_world)))
    end

    --- Mark a received level key item as held and queue its level's visit.
    function M.note_item(name, index)
        if type(name) ~= "string" then return end
        local region = key_to_region[name]
        if region == nil then return end
        if region_to_path[region] == nil then
            if not warned[region] then
                warned[region] = true
                log.warn("no level path for " .. region .. " (" .. name .. "); guide book visit skipped")
            end
            return
        end
        held[region] = true
        if not listed[region] then pending[region] = true end
        log.debug(string.format("%s received (index %s); guide book visit queued", name, tostring(index)))
    end

    --- Poll the world snapshot: once the level is known and stable, submit one
    --- pending region's visit.
    --- @param world table game_state snapshot.
    function M.tick(world)
        if not enabled or not world.ok or not world.playable then return end
        if world.ticks < STABLE_TICKS then return end
        if not jobs.ready() then return end
        plan_pending(world.gs)
    end

    --- Return a one-line heartbeat summary of keys held and levels listed.
    function M.status()
        local held_count, listed_count, pending_count = 0, 0, 0
        for _ in pairs(held) do held_count = held_count + 1 end
        for _ in pairs(listed) do listed_count = listed_count + 1 end
        for _ in pairs(pending) do pending_count = pending_count + 1 end
        return string.format("%senabled=%s keys=%d/%d listed=%d pending=%d",
            cfg.prefix, tostring(enabled), held_count, key_count, listed_count, pending_count)
    end

    M.tag = TAG
    return M
end

return {new = new}
