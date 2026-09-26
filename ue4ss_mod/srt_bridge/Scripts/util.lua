-- util: shared UE4SS Lua helpers (pcall-safe reads, out-param unwrapping,
-- actor identity, the one-job game-thread runner). Pure logic — no mod state
-- (each job_runner owns its own), safe to require from anywhere.

local U = {}

local function ok_res(fn, default)
    local ok, res = pcall(fn)
    if ok then return res end
    return default
end

function U.safe(fn, default)
    return ok_res(fn, default)
end

function U.valid(obj)
    if obj == nil then return false end
    local ok, v = pcall(function() return obj:IsValid() end)
    return ok and v == true
end

-- UE4SS can hand back table-wrapped scalars (out-param quirk): unwrap .value
function U.prop(obj, key)
    local v = ok_res(function() return obj[key] end, nil)
    if type(v) == "number" or type(v) == "boolean" or v == nil then return v end
    local inner = ok_res(function() return v.value end, nil)
    if type(inner) == "number" or type(inner) == "boolean" then return inner end
    return nil
end

function U.fstr(obj, key)
    return ok_res(function() return obj[key]:ToString() end, nil)
end

-- the GAS health attribute set (C++ UPhasmidHealthSystemAttributeSet) that
-- belongs to this pawn. FindAllOf/FindFirstOf take the short class name (no
-- U/A prefix). Every enemy has its own set, so FindFirstOf would hand back an
-- arbitrary one: walk all of them and keep the set whose Outer chain (set ->
-- ASC -> pawn; 4 hops is plenty) reaches the pawn's address. Only runs when a
-- trap or kill is applied, never per tick, so the FindAllOf is cheap enough.
local function owned_by(set, pawn_addr)
    local node = set
    for _ = 1, 4 do
        if U.actor_key(node) == pawn_addr then return true end
        node = U.safe(function() return node:GetOuter() end, nil)
        if not U.valid(node) then return false end
    end
    return false
end

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

function U.actor_key(obj)
    local addr = ok_res(function() return obj:GetAddress() end, nil)
    return addr and tostring(addr) or nil
end

-- One-job-at-a-time ExecuteInGameThread runner (THREADING lesson: the async
-- tick only reads and decides; every write runs inside ONE game-thread job).
--   opts.log      function returning the module's current leveled logger
--                 (modules swap loggers in init, so it is looked up per use)
--   opts.timeout  seconds before an unrun job is abandoned (default 5); an
--                 abandoned job starts NO backoff — the next tick may resubmit
--   opts.backoff  seconds of quiet after a failed job (default = timeout)
-- r.ready()        false while a job is in flight (abandoning it with a WARN
--                  once it outlives the timeout) or while backing off
-- r.submit(fn, o)  run fn on the game thread. fn throwing (ERROR "<o.fail>:
--                  err", default "apply failed") or returning false (module
--                  already logged why) starts the backoff; so does a missing
--                  or throwing ExecuteInGameThread. o.desc names the job in
--                  the abandon WARN (default "job").
-- r.busy(), r.status() ("idle" / "busy" / "backoff") for callers and specs.
-- ExecuteInGameThread is read at submit time (specs swap it per case). A
-- callback that runs after its job was abandoned still backs off on failure
-- but never clears the newer job's in-flight slot.
function U.job_runner(opts)
    opts = opts or {}
    local timeout = opts.timeout or 5
    local backoff = opts.backoff or timeout
    local get_log = opts.log
    local job = nil             -- {started, desc} while a game-thread job is in flight
    local backoff_until = 0
    local r = {}

    local function fail_later()
        backoff_until = os.time() + backoff
    end

    function r.busy()
        return job ~= nil
    end

    function r.ready()
        if job then
            if os.time() - job.started < timeout then return false end
            get_log().warn(job.desc .. " never finished; abandoning it")
            job = nil
        end
        return os.time() >= backoff_until
    end

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

    function r.status()
        if job then return "busy" end
        if os.time() < backoff_until then return "backoff" end
        return "idle"
    end

    return r
end

return U