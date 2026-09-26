-- balloonists (Spyro 1): enforce the seed's balloonist gates
-- (slot_data.games.spyro1.gate_requirements: homeworld -> {type, needed}).
-- CNS1127_MarcoTheBalloonist_C is the only balloonist class; each instance
-- carries LevelPath (destination), GoalType (EInventoryItemType) and
-- GoalValue. SelectorSetup runs on player overlap and compares the inventory
-- count of GoalType against GoalValue (docs/game_state_control.md §9.5.1), so
-- raising GoalValue to the seed's number makes the game enforce it. Values
-- are only ever raised: vanilla seeds send the vanilla numbers (no-op).
--
-- Marcos stream in seconds after a homeworld load and every load spawns fresh
-- actors, so the tick polls and tracks state per actor, reset on level change.
-- Destinations match by LS1xx code (Marco's LevelPath spelling can differ
-- from the current-level path).
--
-- THREADING: every write runs inside ONE ExecuteInGameThread job at a time;
-- the async tick only reads and decides, and submits nothing while a job is
-- in flight (U.job_runner: abandoned after 5s; a thrown job backs off 5s
-- rather than resubmitting every tick). A write that reads back wrong is not a
-- failed job: it is retried next poll (WARN throttled). No game-thread API =
-- no writes.
--
-- API (main.lua): init{log, regions}, configure(slot_data) on slot connect,
-- tick(gamestate) from the poll loop, status() for the heartbeat. log is a
-- leveled logger (tagged [BALLOON]) or the spec's collector function.

local U = require("util")
local logger = require("logger")

local M = {}

local MARCO_CLASS = "CNS1127_MarcoTheBalloonist_C"
local STABLE_TICKS = 2      -- x 250ms poll: a property write spawns nothing, so act fast
local JOB_TIMEOUT = 5       -- seconds before an unfinished job is abandoned (and failed-job backoff)
local GOAL_TYPES = {gems = 1, eggs = 15, dragons = 16}   -- EIT_Treasure, EIT_Egg, EIT_Dragon
local HOMEWORLDS = {
    ["Artisans"] = true, ["Peace Keepers"] = true, ["Magic Crafters"] = true,
    ["Beast Makers"] = true, ["Dream Weavers"] = true, ["Gnorc Gnexus"] = true,
}

local log = logger.tagged("[BALLOON]")
local regions = {}          -- map path -> region (generated regions.lua)
local code_to_region = {}   -- "LS107" -> "Peace Keepers"
local can_write = false
local enabled = false
local gates = {}            -- destination region -> {type, needed, goal_type}
local ngates = 0
local cur_path, stable_ticks = nil, 0
local marcos = {}           -- actor address -> {dest, raised, mismatch, bad}
local jobs = U.job_runner{log = function() return log end, timeout = JOB_TIMEOUT}

local function run_job(m, st, gate)
    if not U.valid(m) then return end
    local old = U.prop(m, "GoalValue")
    if type(old) ~= "number" or old >= gate.needed then return end
    m.GoalValue = gate.needed
    local now = U.prop(m, "GoalValue")
    if now == gate.needed then
        st.raised = true
        log.info(string.format("%s gate %d -> %d (%s)", st.dest, old, now, gate.type))
    else
        st.bad = st.bad + 1
        if st.bad <= 3 or st.bad % 20 == 0 then
            log.warn(string.format("%s gate write %d -> %d read back %s (#%d)",
                st.dest, old, gate.needed, tostring(now), st.bad))
        end
    end
end

local function submit(m, st, gate)
    jobs.submit(function() run_job(m, st, gate) end,
        {desc = "raise job for " .. st.dest, fail = "raise " .. st.dest})
end

-- submits a job for this Marco if its gate is below the seed's; true if it did
local function plan_marco(m, key, dest, gate)
    local st = marcos[key]
    if not st then
        st = {dest = dest, raised = false, mismatch = false, bad = 0}
        marcos[key] = st
        if U.prop(m, "Unlocked") == true then
            log.debug(dest .. " Marco already Unlocked on first sight"
                .. " (destination visited before, or a race with our write)")
        end
    end
    local goal_type = U.prop(m, "GoalType")
    if goal_type ~= gate.goal_type then
        if not st.mismatch then
            st.mismatch = true
            log.warn(string.format("%s Marco GoalType=%s, seed gate is %s (%d); not touching it",
                dest, tostring(goal_type), gate.type, gate.goal_type))
        end
        return false
    end
    local value = U.prop(m, "GoalValue")
    if type(value) == "number" and value < gate.needed then
        submit(m, st, gate)
        return true
    end
    return false
end

function M.init(opts)
    log = logger.leveled("[BALLOON]", opts and opts.log)
    regions = (opts and opts.regions) or {}
    code_to_region = {}
    for path, region in pairs(regions) do
        local code = path:match("^/(LS%d%d%d)_")
        if code then code_to_region[code] = region end
    end
    can_write = type(ExecuteInGameThread) == "function"
    if not can_write then
        log.error("ExecuteInGameThread unavailable — balloonist gates stay vanilla")
    end
end

function M.configure(sd)
    local games = sd and type(sd.games) == "table" and sd.games or {}
    local sg = type(games.spyro1) == "table" and games.spyro1 or {}
    local reqs = type(sg.gate_requirements) == "table" and sg.gate_requirements or {}
    gates, ngates = {}, 0
    for dest, req in pairs(reqs) do
        local kind = type(req) == "table" and req.type
        local needed = type(req) == "table" and type(req.needed) == "number"
            and math.tointeger(math.floor(req.needed)) or nil
        if type(dest) == "string" and GOAL_TYPES[kind] and needed and needed >= 0 then
            gates[dest] = {type = kind, needed = needed, goal_type = GOAL_TYPES[kind]}
            ngates = ngates + 1
        end
    end
    enabled = can_write and ngates > 0
    cur_path, stable_ticks, marcos = nil, 0, {}
    log.info(string.format("configured: enabled=%s gates=%d", tostring(enabled), ngates))
end

function M.tick(gs)
    local path = U.safe(function() return gs["current level"]:ToString() end, nil)
    if path ~= cur_path then
        cur_path, stable_ticks, marcos = path, 0, {}
        return
    end
    if not enabled then return end
    local here = path and regions[path]
    if not (here and HOMEWORLDS[here]) then return end
    stable_ticks = stable_ticks + 1
    if stable_ticks < STABLE_TICKS then return end
    if not jobs.ready() then return end
    for _, m in ipairs(U.safe(function() return FindAllOf(MARCO_CLASS) end, nil) or {}) do
        local dest_path = U.valid(m) and U.fstr(m, "LevelPath") or nil
        local code = dest_path and dest_path:match("^/(LS%d%d%d)_")
        local dest = code and code_to_region[code]
        local gate = dest and gates[dest]
        local key = gate and U.actor_key(m)
        if key and plan_marco(m, key, dest, gate) then return end
    end
end

function M.status()
    local raised = 0
    for _, st in pairs(marcos) do
        if st.raised then raised = raised + 1 end
    end
    return string.format("enabled=%s gates=%d raised_here=%d", tostring(enabled), ngates, raised)
end

return M
