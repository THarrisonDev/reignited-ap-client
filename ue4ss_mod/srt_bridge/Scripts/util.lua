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
--- @param opts table|nil
--- @return table runner with ready(), submit(), busy() and status()
function U.job_runner(opts)
    opts = opts or {}
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
    function r.submit(fn, o)
        local mine = {started = os.time(), desc = (o and o.desc) or "job"}
        local fail = (o and o.fail) or "apply failed"
        if type(ExecuteInGameThread) ~= "function" then
            fail_later()
            get_log().error("ExecuteInGameThread: unavailable")
            return
        end
        job = mine
        local ok, err = pcall(ExecuteInGameThread, function()
            local okJ, res = pcall(fn)
            if not okJ then
                fail_later()
                get_log().error(fail .. ": " .. tostring(res))
            elseif res == false then
                fail_later()
            end
            if job == mine then job = nil end
        end)
        if not ok then
            if job == mine then job = nil end
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