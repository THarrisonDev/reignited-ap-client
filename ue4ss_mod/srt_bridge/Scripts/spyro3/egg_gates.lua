-- Author: Tim Harrison
-- Created: 2026-09-27
-- Updated: 2026-10-31

-- egg_gates (Spyro 3): lower each S3 homeworld egg portal's EggRequirement as
-- Dragon Egg items are received (spyro3_egg_shuffle), forcing the gate open
-- once the write reaches 0; the displayed requirement stays vanilla. Writes
-- run one at a time on the game thread.

local U = require("util")
local logger = require("logger")
local C = require("constants")
local O = require("option")

local STABLE_TICKS = 2      -- Polls of 250ms: a property write spawns nothing, so act fast.
local JOB_TIMEOUT = 5       -- Seconds before an unfinished job is abandoned (and failed-job backoff).

local HOMEWORLDS = C.homeworlds.spyro3

--- Build a fresh egg-gates module instance.
local function new()
    local M = {}

    local TAG = "[EGGS3]"

    local log = logger.tagged(TAG)
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
    local tuned = {}            -- Actor address -> {region, done, bad}.
    local jobs = U.job_runner{log = function() return log end, timeout = JOB_TIMEOUT}

    --- Return the gate requirement after subtracting received Dragon Eggs,
    --- floored at 0.
    --- @return number
    local function target_for(region)
        local t = vanilla[region] - received
        if t < 0 then return 0 end
        return t
    end

    --- Force the portal's Open() transition at requirement 0.
    local function force_open(c, region)
        -- Open() forces the state transition unconditionally and does not itself
        -- re-check EggRequirement, so this must only run once the write has
        -- already brought the requirement to 0.
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

    --- Write one controller's EggRequirement down to target on the game thread,
    --- forcing the gate open when it reaches 0.
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

    --- Submit the game-thread tune job for one controller.
    local function submit(c, st, region)
        jobs.submit(function() run_job(c, st, region) end,
            {desc = "tune job for " .. region, fail = "tune " .. region})
    end

    --- Submit a tune job when the controller's requirement is above target;
    --- return whether one was submitted.
    --- @return boolean
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

    --- Set the logger and regions, deriving TargetName -> region from the path
    --- keys, and probe for ExecuteInGameThread.
    function M.init(opts)
        log = logger.leveled(TAG, opts and opts.log)
        regions = (opts and opts.regions) or {}
        target_to_region = {}
        for path, name in pairs(regions) do
            local target = path:match("^/(.-)/Maps/$")
            if target then target_to_region[target] = name end
        end
        can_write = U.can_write()
        if not can_write then
            log.error("ExecuteInGameThread unavailable — egg gates stay vanilla")
        end
    end

    --- Return the region -> vanilla requirement map from slot data's egg_gates.
    local function read_gates(sg)
        local raw = type(sg.egg_gates) == "table" and sg.egg_gates or {}
        local gates, count = {}, 0
        for region, req in pairs(raw) do
            if type(region) == "string" and type(req) == "number" and req > 0 then
                gates[region] = math.tointeger(math.floor(req))
                count = count + 1
            end
        end
        return gates, count
    end

    --- Load per-region vanilla requirements and enable the module when
    --- egg_shuffle is on.
    function M.configure(sd)
        local opts = O.game_options(sd, "spyro3")
        vanilla, nvanilla = read_gates(O.game_data(sd, "spyro3"))
        enabled = can_write and O.flag(opts.egg_shuffle, "egg_shuffle", log) and nvanilla > 0
        received = 0
        log.info(string.format("configured: enabled=%s gates=%d (egg_shuffle=%s)",
            tostring(enabled), nvanilla, tostring(opts.egg_shuffle)))
    end

    --- Count a received Dragon Egg item.
    function M.note_item(name)
        if name == "Spyro 3: Dragon Egg" then
            received = received + 1
            log.debug("Dragon Egg received (running " .. received .. ")")
        end
    end

    --- Return the actor key and region of a controller that gates a realm here.
    local function controller_region(c)
        if not U.valid(c) then return nil end
        -- PortalControllers in a homeworld gate the realms, so match by
        -- TargetName, never by streamed neighbours. TargetName is the engine id,
        -- never the display name that slot_data's egg_gates is keyed by;
        -- translate through target_to_region first.
        local target = U.fstr(c, "TargetName")
        local region = target and target_to_region[target]
        if not region or not vanilla[region] then return nil end
        return U.actor_key(c), region
    end

    --- Submit one tune job for a matching egg-gate controller.
    local function poll_controllers()
        local actors = U.safe(function() return FindAllOf("PortalController") end, nil) or {}
        for _, c in ipairs(actors) do
            local key, region = controller_region(c)
            if key and plan_controller(c, key, region) then return end
        end
    end

    --- Poll the world snapshot: in a stable homeworld, submit one tune job for
    --- a matching egg-gate controller.
    --- @param world table game_state snapshot.
    function M.tick(world)
        if not world.ok then return end
        -- a world transition remakes every gate controller
        if world.changed then tuned = {} end
        if not U.gate_ready(world, enabled, HOMEWORLDS, STABLE_TICKS, jobs) then return end
        poll_controllers()
    end

    --- Return one heartbeat line of counts.
    --- @return string
    function M.status()
        local done, bad = 0, 0
        for _, st in pairs(tuned) do
            if st.done then done = done + 1 end
            bad = bad + st.bad
        end
        return string.format("enabled=%s gates=%d received=%d tuned_here=%d bad=%d",
            tostring(enabled), nvanilla, received, done, bad)
    end

    M.tag = TAG
    return M
end

return new()