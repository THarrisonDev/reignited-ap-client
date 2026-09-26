-- Stub-based spec for util.lua's U.job_runner, the one-job-at-a-time
-- ExecuteInGameThread runner behind fillers, death_link, level locks,
-- balloonists and the inventory-grant modules. ExecuteInGameThread only
-- QUEUES work; pump() runs it. os.time is faked.
-- Run from the client repo root: lua tests/lua/test_job_runner.lua

local here = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./"
package.path = here .. "../../ue4ss_mod/srt_bridge/Scripts/?.lua;" .. package.path

local queue = {}
local function queue_fn(fn) queue[#queue + 1] = fn end
ExecuteInGameThread = queue_fn
local function pump()
    local jobs = queue
    queue = {}
    for _, fn in ipairs(jobs) do fn() end
end

local now = 1000
os.time = function() return now end

local U = require("util")

local lines = {}
local log = {
    warn = function(m) lines[#lines + 1] = "WARN " .. m end,
    error = function(m) lines[#lines + 1] = "ERROR " .. m end,
}
local function fresh(opts)
    queue, lines = {}, {}
    opts = opts or {}
    opts.log = function() return log end
    return U.job_runner(opts)
end
local function count(pat)
    local n = 0
    for _, l in ipairs(lines) do if l:find(pat, 1, true) then n = n + 1 end end
    return n
end

local tests, failed = 0, 0
local function test(name, fn)
    tests = tests + 1
    local ok, err = pcall(fn)
    if ok then
        print("PASS " .. name)
    else
        failed = failed + 1
        print("FAIL " .. name .. ": " .. tostring(err))
        for _, l in ipairs(lines) do print("    | " .. l) end
    end
    ExecuteInGameThread = queue_fn
end

test("one job in flight; finishing frees the slot", function()
    local r = fresh()
    assert(r.ready() and not r.busy() and r.status() == "idle")
    local ran = 0
    r.submit(function() ran = ran + 1 end)
    assert(r.busy() and not r.ready() and r.status() == "busy")
    assert(#queue == 1 and ran == 0, "the job must only run on the game thread")
    pump()
    assert(ran == 1 and not r.busy() and r.ready() and r.status() == "idle")
    assert(#lines == 0, "a clean job logs nothing")
end)

test("an unrun job is abandoned after the timeout, with no backoff", function()
    local r = fresh({ timeout = 5 })
    r.submit(function() end, { desc = "lock job for Stone Hill" })
    now = now + 4
    assert(not r.ready(), "still inside the timeout")
    now = now + 1
    assert(r.ready(), "timed-out job should free the slot and allow a resubmit at once")
    assert(count("WARN lock job for Stone Hill never finished; abandoning it") == 1)
    assert(not r.busy())
end)

test("default abandon wording is 'job never finished'", function()
    local r = fresh()
    r.submit(function() end)
    now = now + 5
    assert(r.ready() and count("WARN job never finished; abandoning it") == 1)
end)

test("a thrown job logs ERROR once and backs off", function()
    local r = fresh({ timeout = 5 })
    r.submit(function() error("boom") end, { fail = "raise Peace Keepers" })
    pump()
    assert(count("ERROR raise Peace Keepers: ") == 1 and count("boom") == 1)
    assert(not r.busy() and not r.ready() and r.status() == "backoff")
    now = now + 4
    assert(not r.ready(), "still backing off")
    now = now + 1
    assert(r.ready() and r.status() == "idle")
end)

test("default failure prefix is 'apply failed'", function()
    local r = fresh()
    r.submit(function() error("x") end)
    pump()
    assert(count("ERROR apply failed: ") == 1)
end)

test("a job returning false backs off without logging", function()
    local r = fresh({ timeout = 5, backoff = 3 })
    r.submit(function() return false end)
    pump()
    assert(#lines == 0 and not r.ready())
    now = now + 3
    assert(r.ready(), "custom backoff length not honoured")
end)

test("nil / true returns do not back off", function()
    local r = fresh()
    r.submit(function() return nil end)
    pump()
    assert(r.ready())
    r.submit(function() return true end)
    pump()
    assert(r.ready())
end)

test("missing ExecuteInGameThread: ERROR, backoff, nothing in flight", function()
    local r = fresh({ timeout = 5 })
    ExecuteInGameThread = nil
    local ran = false
    r.submit(function() ran = true end)
    assert(not ran and not r.busy())
    assert(count("ERROR ExecuteInGameThread: unavailable") == 1)
    assert(not r.ready(), "a missing game-thread API should back off")
    now = now + 5
    assert(r.ready())
end)

test("ExecuteInGameThread throwing: ERROR, backoff, nothing in flight", function()
    local r = fresh({ timeout = 5 })
    ExecuteInGameThread = function() error("no game thread") end
    r.submit(function() end)
    assert(not r.busy() and count("ERROR ExecuteInGameThread: ") == 1)
    assert(not r.ready())
end)

test("a late callback of an abandoned job never frees the newer job's slot", function()
    local r = fresh({ timeout = 5 })
    r.submit(function() error("late boom") end)
    local stale = queue
    queue = {}
    now = now + 5
    assert(r.ready())
    r.submit(function() end)
    assert(r.busy())
    for _, fn in ipairs(stale) do fn() end
    assert(r.busy(), "stale callback cleared the in-flight job")
    assert(count("late boom") == 1 and not r.ready(), "stale failure still backs off")
    pump()
    assert(not r.busy())
end)

test("the logger is looked up per use (modules swap it in init)", function()
    local r = fresh()
    local seen = {}
    local other = { warn = function(m) seen[#seen + 1] = m end, error = function(m) seen[#seen + 1] = m end }
    local cur = log
    r = U.job_runner({ log = function() return cur end })
    cur = other
    r.submit(function() error("swapped") end)
    pump()
    assert(#seen == 1 and seen[1]:find("swapped", 1, true), "error went to the stale logger")
end)

print(string.format("%d/%d passed", tests - failed, tests))
os.exit(failed == 0 and 0 or 1)
