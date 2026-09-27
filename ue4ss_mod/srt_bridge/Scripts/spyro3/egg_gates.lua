-- egg_gates (Spyro 3): the game's egg portals follow received Dragon Egg
-- items (spyro3_egg_shuffle). Each portal/gate controller in an S3 homeworld
-- carries a plain writable EggRequirement int, and this module writes
-- EggRequirement = max(0, vanilla - received Dragon Eggs) each tick; it never
-- raises a value. A vanilla 10 gate with 3 received Eggs therefore opens at 7
-- caught eggs. When the write brings the requirement to 0, the module also
-- calls Open(QuestActions) once: catching an egg is the only native trigger
-- that re-checks a gate, so a fully-covered requirement would otherwise sit
-- there forever. Open() does not itself re-check EggRequirement, so it must
-- only be called once the write has already brought the requirement to 0.
-- The requirement display keeps showing the vanilla number regardless; only
-- the actual gating moves.
--
-- Slot data (egg_gates) keys requirements by region display name, but
-- controllers carry TargetName (the engine id, e.g. "LS304_MoltenCrater").
-- `init` derives target_to_region from the path keys of the same regions.lua
-- table, and `tick` translates through it before indexing `vanilla`.
--
-- Only S3 homeworlds are scanned; the realm-side return portals carry no
-- requirements, and Super Bonus Round's GemRequirement stays vanilla.
-- Actors are fresh every homeworld load, so the tuned table resets on level
-- change and the write re-lands.
--
-- Threading: every write runs inside one ExecuteInGameThread job at a time.
-- The async tick only reads and decides, and submits nothing while a job is
-- in flight (U.job_runner). No game-thread API means no writes.
--
-- API (main.lua): init{log, regions}, configure(slot_data) on slot connect,
-- note_item(name) per received item, tick(gamestate) from the poll loop, and
-- status() for the heartbeat. log is a leveled logger (tagged [EGGS3]) or the
-- spec's collector function.

local U = require("util")
local logger = require("logger")

local STABLE_TICKS = 2      -- Polls of 250ms: a property write spawns nothing, so act fast.
local JOB_TIMEOUT = 5       -- Seconds before an unfinished job is abandoned (and failed-job backoff).

local HOMEWORLDS = {
    ["Sunrise Spring"] = true, ["Midday Gardens"] = true,
    ["Evening Lake"] = true, ["Midnight Mountain"] = true,
}

local function new()
    local M = {}

    local log = logger.tagged("[EGGS3]")
    local regions = {}          -- Map of path -> region (generated regions.lua).
    local target_to_region = {} -- TargetName (engine id, e.g. "LS304_MoltenCrater")
                                -- -> region display name (e.g. "Molten Crater").
                                -- Derived from `regions`'s path keys, since
                                -- TargetName is never the display name.
    local can_write = false     -- ExecuteInGameThread available.
    local enabled = false
    local vanilla = {}          -- Region -> vanilla EggRequirement (slot data).
    local nvanilla = 0
    local received = 0          -- Dragon Egg items received from the server.
    local cur_path, stable_ticks = nil, 0
    local tuned = {}            -- Actor address -> {region, done, bad}.
    local jobs = U.job_runner{log = function() return log end, timeout = JOB_TIMEOUT}

    local function target_for(region)
        local t = vanilla[region] - received
        if t < 0 then return 0 end
        return t
    end

    -- Open() forces the state transition unconditionally and does not itself
    -- re-check EggRequirement. A partial write deliberately leaves the rest
    -- to the player actually catching eggs, so this must only run once the
    -- write has already brought the requirement to 0.
    local function force_open(c, region)
        local actions = U.safe(function() return c.QuestActions end, nil)
        if not U.valid(actions) then
            log.warn(region .. " egg gate at 0 but QuestActions unreadable; not forcing open")
            return
        end
        local ok, err = pcall(function() c:Open(actions) end)
        if ok then
            log.info(region .. " egg gate forced open (Open() called)")
        else
            log.warn(region .. " egg gate Open() call failed: " .. tostring(err))
        end
    end

    local function run_job(c, st, region)
        if not U.valid(c) then return end
        local want = target_for(region)
        local old = U.prop(c, "EggRequirement")
        if type(old) ~= "number" then
            st.bad = st.bad + 1
            if st.bad <= 3 or st.bad % 20 == 0 then
                log.warn("EggRequirement unreadable on " .. region .. " controller (#" .. st.bad .. ")")
            end
            return
        end
        if old <= want then
            -- Already at or below target: another session's write, or a
            -- vanilla number with enough Eggs received.
            st.done = true
            return
        end
        c.EggRequirement = want
        local now = U.prop(c, "EggRequirement")
        if now == want then
            st.done = true
            log.info(string.format("%s egg gate %d -> %d (received %d)",
                region, old, now, received))
            if want <= 0 then force_open(c, region) end
        else
            st.bad = st.bad + 1
            if st.bad <= 3 or st.bad % 20 == 0 then
                log.warn(string.format("%s egg gate write %d -> %d read back %s (#%d)",
                    region, old, want, tostring(now), st.bad))
            end
        end
    end

    local function submit(c, st, region)
        jobs.submit(function() run_job(c, st, region) end,
            {desc = "tune job for " .. region, fail = "tune " .. region})
    end

    -- Submit a job for this controller if its requirement is above target.
    -- Return true if it did.
    local function plan_controller(c, key, region)
        local st = tuned[key]
        if not st then
            st = {region = region, done = false, bad = 0}
            tuned[key] = st
        end
        local req = U.prop(c, "EggRequirement")
        -- Not an egg-gate controller: unreadable, ours from this session, or 0.
        if type(req) ~= "number" or req <= 0 or req > vanilla[region] then
            return false
        end
        if target_for(region) < req then
            submit(c, st, region)
            return true
        end
        st.done = true
        return false
    end

    function M.init(opts)
        log = logger.leveled("[EGGS3]", opts and opts.log)
        regions = (opts and opts.regions) or {}
        target_to_region = {}
        for path, name in pairs(regions) do
            local target = path:match("^/(.-)/Maps/$")
            if target then target_to_region[target] = name end
        end
        can_write = type(ExecuteInGameThread) == "function"
        if not can_write then
            log.error("ExecuteInGameThread unavailable — egg gates stay vanilla")
        end
    end

    function M.configure(sd)
        local games = sd and type(sd.games) == "table" and sd.games or {}
        local sg = type(games.spyro3) == "table" and games.spyro3 or {}
        local opts = type(sg.options) == "table" and sg.options or {}
        local gates = type(sg.egg_gates) == "table" and sg.egg_gates or {}
        vanilla, nvanilla = {}, 0
        for region, req in pairs(gates) do
            if type(region) == "string" and type(req) == "number" and req > 0 then
                vanilla[region] = math.tointeger(math.floor(req))
                nvanilla = nvanilla + 1
            end
        end
        enabled = can_write and (opts.egg_shuffle == 1 or opts.egg_shuffle == true) and nvanilla > 0
        received = 0
        log.info(string.format("configured: enabled=%s gates=%d (egg_shuffle=%s)",
            tostring(enabled), nvanilla, tostring(opts.egg_shuffle)))
    end

    function M.note_item(name)
        if name == "Spyro 3: Dragon Egg" then
            received = received + 1
            log.debug("Dragon Egg received (running " .. received .. ")")
        end
    end

    function M.tick(gs)
        local path = U.safe(function() return gs["current level"]:ToString() end, nil)
        if path ~= cur_path then
            cur_path, stable_ticks, tuned = path, 0, {}
            return
        end
        if not enabled then return end
        local here = path and regions[path]
        if not (here and HOMEWORLDS[here]) then return end
        stable_ticks = stable_ticks + 1
        if stable_ticks < STABLE_TICKS then return end
        if not jobs.ready() then return end
        for _, c in ipairs(U.safe(function() return FindAllOf("PortalController") end, nil) or {}) do
            if U.valid(c) then
                local key = U.actor_key(c)
                -- PortalControllers in a homeworld gate the realms, so match
                -- by TargetName, never by streamed neighbours. TargetName is
                -- the engine id, never the display name that slot_data's
                -- egg_gates is keyed by; translate through target_to_region
                -- first.
                local target = U.fstr(c, "TargetName")
                local region = target and target_to_region[target]
                region = region and vanilla[region] and region or nil
                if region and plan_controller(c, key, region) then return end
            end
        end
    end

    function M.status()
        local done, bad = 0, 0
        for _, st in pairs(tuned) do
            if st.done then done = done + 1 end
            bad = bad + st.bad
        end
        return string.format("enabled=%s gates=%d received=%d tuned_here=%d bad=%d",
            tostring(enabled), nvanilla, received, done, bad)
    end

    return M
end

return new()