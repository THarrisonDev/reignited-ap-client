-- Author: Tim Harrison
-- Created: 2026-09-26
-- Updated: 2026-10-23

-- util: shared UE4SS Lua helpers — pcall-safe reads, out-param unwrapping,
-- actor identity and the one-job game-thread runner. Pure logic, no mod state.

local U = {}

--- Return fn()'s result, or default when it throws.
local function ok_res(fn, default)
    local ok, res = pcall(fn)
    if ok then return res end
    return default
end

--- Call fn and return its result, or default when it throws.
function U.safe(fn, default)
    return ok_res(fn, default)
end

--- Return whether obj is non-nil and passes IsValid().
function U.valid(obj)
    if obj == nil then return false end
    local ok, v = pcall(function() return obj:IsValid() end)
    return ok and v == true
end

--- Return the live FalconGameState, or nil when it is not valid.
function U.game_state()
    local gs = ok_res(function() return FindFirstOf("FalconGameState_C") end, nil)
    if not U.valid(gs) then return nil end
    return gs
end

--- Return whether UE4SS exposes the game-thread write API.
--- @return boolean
function U.can_write()
    return type(ExecuteInGameThread) == "function"
end

--- Index a generated regions.lua path map by its /LSnnn_ portal code.
--- @param regions table|nil map path -> region
--- @return table map code -> region
function U.region_codes(regions)
    local codes = {}
    for path, region in pairs(regions or {}) do
        local code = path:match("^/(LS%d%d%d)_")
        if code then codes[code] = region end
    end
    return codes
end

--- Return whether a homeworld gate watcher may poll this tick: the slot's
--- option is on, the player is in a stable homeworld and the job runner is idle.
--- @param world table game_state snapshot.
--- @param enabled boolean
--- @param homeworlds table region name -> true
--- @param stable integer polls a region must hold before a write
--- @param jobs table job runner
--- @return boolean
function U.gate_ready(world, enabled, homeworlds, stable, jobs)
    if not world.ok or not enabled then return false end
    local here = world.region
    if not (here and homeworlds[here]) then return false end
    if world.ticks < stable then return false end
    return jobs.ready()
end

--- Read obj[key], unwrapping UE4SS's table-wrapped scalars (the out-param
--- quirk) to a number or boolean.
--- @return number|boolean|nil
function U.prop(obj, key)
    local v = ok_res(function() return obj[key] end, nil)
    if type(v) == "number" or type(v) == "boolean" or v == nil then return v end
    local inner = ok_res(function() return v.value end, nil)
    if type(inner) == "number" or type(inner) == "boolean" then return inner end
    return nil
end

--- Return obj[key] as a string via its ToString(), or nil when unreadable.
--- @return string|nil
function U.fstr(obj, key)
    return ok_res(function() return obj[key]:ToString() end, nil)
end

--- Return whether the health attribute set's Outer chain reaches pawn. Every
--- enemy owns a set, so the chain (set -> ASC -> pawn, 4 hops is plenty)
--- tells us which one is ours.
local function owned_by(set, pawn_addr)
    local node = set
    for _ = 1, 4 do
        if U.actor_key(node) == pawn_addr then return true end
        node = U.safe(function() return node:GetOuter() end, nil)
        if not U.valid(node) then return false end
    end
    return false
end

--- Return pawn's GAS health set (UPhasmidHealthSystemAttributeSet), found by
--- walking all sets and keeping the one owned_by pawn.
--- @return userdata|nil
function U.find_health_set(pawn)
    local pawn_addr = U.actor_key(pawn)
    if not pawn_addr then return nil end
    local sets = U.safe(function() return FindAllOf("PhasmidHealthSystemAttributeSet") end, nil)
    if type(sets) ~= "table" then return nil end
    for _, set in ipairs(sets) do
        if U.valid(set) and owned_by(set, pawn_addr) then return set end
    end
    return nil
end

--- Return obj's address as a string key, or nil when unavailable.
--- @return string|nil
function U.actor_key(obj)
    local addr = ok_res(function() return obj:GetAddress() end, nil)
    return addr and tostring(addr) or nil
end

--- Build a one-job-at-a-time ExecuteInGameThread runner, so the async tick
--- only reads and decides while every write runs alone on the game thread.
--- opts.log is a function returning the module's current logger (looked up per
--- use); opts.timeout abandons an unrun job (default 5s, no backoff);
--- opts.backoff is the quiet time after a failed job (default timeout).
--- @return table runner with ready(), submit(), busy() and status()
function U.job_runner(opts)    opts = opts or {}
    local timeout = opts.timeout or 5
    local backoff = opts.backoff or timeout
    local get_log = opts.log
    local job = nil             -- {started, desc} while a game-thread job is in flight
    local backoff_until = 0
    local r = {}

    --- Start the quiet period after a failed job.
    local function fail_later()
        backoff_until = os.time() + backoff
    end

    --- Return whether a game-thread job is in flight.
    function r.busy()
        return job ~= nil
    end

    --- Return whether a new job may run: nothing in flight (abandoning a
    --- timed-out one) and not backing off.
    function r.ready()
        if job then
            if os.time() - job.started < timeout then return false end
            get_log().warn(job.desc .. " never finished; abandoning it")
            job = nil
        end
        return os.time() >= backoff_until
    end

    --- Run fn on the game thread. fn throwing (ERROR "<o.fail>: err") or
    --- returning false starts the backoff; so does a missing or throwing
    --- ExecuteInGameThread. o.desc names the job in the abandon WARN.
    ---
    --- o.defer keeps the job in flight after fn returns: fn is handed a `done`
    --- callback and must call it when its delayed work has finished. The fence
    --- (ready()/busy()) then covers work that outlives the call — a write whose
    --- re-asserts are still scheduled — and `timeout` still abandons a job that
    --- never calls done.
    function r.submit(fn, o)
        local mine = {started = os.time(), desc = (o and o.desc) or "job"}
        local fail = (o and o.fail) or "apply failed"
        local defer = o and o.defer
        if type(ExecuteInGameThread) ~= "function" then
            fail_later()
            get_log().error("ExecuteInGameThread: unavailable")
            return
        end
        job = mine
        --- Clear the in-flight job when it is still ours.
        local function finish()
            if job == mine then job = nil end
        end
        local ok, err = pcall(ExecuteInGameThread, function()
            if defer then
                local finished = false
                --- Release the fence once, however often fn calls back.
                local function done()
                    if finished then return end
                    finished = true
                    finish()
                end
                local okJ, res = pcall(fn, done)
                if not okJ then
                    done()
                    fail_later()
                    get_log().error(fail .. ": " .. tostring(res))
                elseif res == false then
                    done()
                    fail_later()
                end
                return
            end
            local okJ, res = pcall(fn)
            if not okJ then
                fail_later()
                get_log().error(fail .. ": " .. tostring(res))
            elseif res == false then
                fail_later()
            end
            finish()
        end)
        if not ok then
            finish()
            fail_later()
            get_log().error("ExecuteInGameThread: " .. tostring(err))
        end
    end

    --- Return "busy", "backoff" or "idle".
    --- @return string
    function r.status()
        if job then return "busy" end
        if os.time() < backoff_until then return "backoff" end
        return "idle"
    end

    return r
end

return U