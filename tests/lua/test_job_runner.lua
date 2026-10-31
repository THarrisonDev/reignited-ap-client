-- Author: Tim Harrison
-- Created: 2026-09-26
-- Updated: 2026-10-23

-- Stub-based spec for util.lua's U.job_runner, the one-job-at-a-time
-- ExecuteInGameThread runner behind fillers, death_link, level locks,
-- balloonists and the inventory-grant modules. The harness queues the work and
-- H.pump() runs it; os.time is stubbed.
-- Run from the client repo root: lua tests/lua/test_job_runner.lua

package.path = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "support/?.lua;" .. package.path
local H = require("harness")

H.install_game_thread()

local U = require("util")

local log = {
    warn = function(m) H.collect("WARN " .. m) end,
    error = function(m) H.collect("ERROR " .. m) end,
}
local function fresh(opts)
    H.clear_queue()
    H.clear_log()
    opts = opts or {}
    opts.log = function() return log end
    return U.job_runner(opts)
end
local function count(pat)
    return H.count_logged(pat, true)
end

local test = H.test

test("one job in flight; finishing frees the slot", function()
    local r = fresh()
    assert(r.ready() and not r.busy() and r.status() == "idle")
    local ran = 0
    r.submit(function() ran = ran + 1 end)
    assert(r.busy() and not r.ready() and r.status() == "busy")
    assert(H.queued() == 1 and ran == 0, "the job must only run on the game thread")
    H.pump()
    assert(ran == 1 and not r.busy() and r.ready() and r.status() == "idle")
    assert(#H.lines == 0, "a clean job logs nothing")
end)

test("an unrun job is abandoned after the timeout, with no backoff", function()
    local r = fresh({ timeout = 5 })
    r.submit(function() end, { desc = "lock job for Stone Hill" })
    H.advance(4)
    assert(not r.ready(), "still inside the timeout")
    H.advance(1)
    assert(r.ready(), "timed-out job should free the slot and allow a resubmit at once")
    assert(count("WARN lock job for Stone Hill never finished; abandoning it") == 1)
    assert(not r.busy())
end)

test("default abandon wording is 'job never finished'", function()
    local r = fresh()
    r.submit(function() end)
    H.advance(5)
    assert(r.ready() and count("WARN job never finished; abandoning it") == 1)
end)

test("a thrown job logs ERROR once and backs off", function()
    local r = fresh({ timeout = 5 })
    r.submit(function() error("boom") end, { fail = "raise Peace Keepers" })
    H.pump()
    assert(count("ERROR raise Peace Keepers: ") == 1 and count("boom") == 1)
    assert(not r.busy() and not r.ready() and r.status() == "backoff")
    H.advance(4)
    assert(not r.ready(), "still backing off")
    H.advance(1)
    assert(r.ready() and r.status() == "idle")
end)

test("default failure prefix is 'apply failed'", function()
    local r = fresh()
    r.submit(function() error("x") end)
    H.pump()
    assert(count("ERROR apply failed: ") == 1)
end)

test("a job returning false backs off without logging", function()
    local r = fresh({ timeout = 5, backoff = 3 })
    r.submit(function() return false end)
    H.pump()
    assert(#H.lines == 0 and not r.ready())
    H.advance(3)
    assert(r.ready(), "custom backoff length not honoured")
end)

test("nil / true returns do not back off", function()
    local r = fresh()
    r.submit(function() return nil end)
    H.pump()
    assert(r.ready())
    r.submit(function() return true end)
    H.pump()
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
    H.advance(5)
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
    local stale = H.queue
    H.queue = {}
    H.advance(5)
    assert(r.ready())
    r.submit(function() end)
    assert(r.busy())
    for _, fn in ipairs(stale) do fn() end
    assert(r.busy(), "stale callback cleared the in-flight job")
    assert(count("late boom") == 1 and not r.ready(), "stale failure still backs off")
    H.pump()
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
    H.pump()
    assert(#seen == 1 and seen[1]:find("swapped", 1, true), "error went to the stale logger")
end)

test("a deferred job holds the fence until done()", function()
    local r = fresh({ timeout = 5 })
    local done_ref
    r.submit(function(done) done_ref = done end, { defer = true, desc = "banner job" })
    H.pump()
    assert(r.busy() and not r.ready(), "the fence must hold after fn returns")
    assert(r.status() == "busy")
    done_ref()
    assert(not r.busy() and r.ready() and r.status() == "idle")
    assert(#H.lines == 0, "a clean deferred job logs nothing")
end)

test("a stale done() never frees a newer job's slot", function()
    local r = fresh({ timeout = 5 })
    local done_ref
    r.submit(function(done) done_ref = done end, { defer = true })
    H.pump()
    done_ref()
    local ran = 0
    r.submit(function() ran = ran + 1 end)
    assert(r.busy())
    done_ref() -- the finished job's callback must not clear this one
    assert(r.busy(), "a stale done() cleared the newer job")
    H.pump()
    assert(ran == 1 and not r.busy())
end)

test("a deferred job that throws releases the fence and backs off", function()
    local r = fresh({ timeout = 5 })
    r.submit(function() error("deferred boom") end, { defer = true, fail = "banner apply failed" })
    H.pump()
    assert(count("ERROR banner apply failed: ") == 1)
    assert(not r.busy() and not r.ready() and r.status() == "backoff")
end)

test("a deferred job returning false releases the fence and backs off", function()
    local r = fresh({ timeout = 5 })
    r.submit(function() return false end, { defer = true })
    H.pump()
    assert(#H.lines == 0 and not r.busy() and not r.ready())
end)

test("a deferred job that never calls done is abandoned after the timeout", function()
    local r = fresh({ timeout = 5 })
    r.submit(function() end, { defer = true, desc = "stuck banner job" })
    H.pump()
    assert(r.busy())
    H.advance(4)
    assert(not r.ready(), "still inside the timeout")
    H.advance(1)
    assert(r.ready() and count("WARN stuck banner job never finished; abandoning it") == 1)
    assert(not r.busy())
end)

H.finish()
