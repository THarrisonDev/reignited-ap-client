-- Stub-based spec for client/ue4ss_mod/srt_bridge/Scripts/goal_watch.lua.
-- Fakes send()/log; exercises slot-data configuration, event detection across
-- backlog batches, once-only GOAL reporting and reconnect re-delivery.
-- Run from the client repo root: lua tests/lua/test_goal_watch.lua

local here = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./"
package.path = here .. "../../ue4ss_mod/srt_bridge/Scripts/?.lua;" .. package.path

local RIPTO_LOC = 226000
local GNASTY_LOC = 102031
local LOOT_LOC = 102028

local function sd(required, games)
    return {required_games = required, games = games or {}}
end

local lines, sends, G
local function fresh()
    package.loaded["goal_watch"] = nil
    local mod = require("goal_watch")
    lines, sends = {}, {}
    mod.init({
        log = function(l) lines[#lines + 1] = l end,
        send = function()
            sends[#sends + 1] = true
            return true
        end,
    })
    return mod
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
end

test("goal event arrival sends GOAL exactly once", function()
    local G = fresh()
    G.configure(sd({"spyro2"}, {spyro2 = {goal_location = RIPTO_LOC}}))
    assert(#sends == 0)
    G.note_batch({{item = 999, location = 1234, index = 0}})
    G.note_batch({{item = 5102, location = RIPTO_LOC, index = 1}})
    assert(#sends == 1, "GOAL not sent on the goal event")
    G.note_batch({{item = 5102, location = RIPTO_LOC, index = 1}})
    G.note_batch({})
    assert(#sends == 1, "GOAL sent twice")
end)

test("multi-game: GOAL only when every required goal has arrived", function()
    local G = fresh()
    G.configure(sd({"spyro1", "spyro2"}, {spyro1 = {goal_location = GNASTY_LOC},
                                          spyro2 = {goal_location = RIPTO_LOC}}))
    G.note_batch({{location = RIPTO_LOC, index = 0}})
    assert(#sends == 0, "GOAL sent with spyro1 goal still pending")
    G.note_batch({{location = GNASTY_LOC, index = 1}})
    assert(#sends == 1, "GOAL not sent after both goals arrived")
end)

test("backlog re-delivery after reconnect does not double-report", function()
    local G = fresh()
    G.configure(sd({"spyro2"}, {spyro2 = {goal_location = RIPTO_LOC}}))
    -- the connect-time backlog re-delivers index 0..n in one batch
    G.note_batch({{location = 1, index = 0}, {location = RIPTO_LOC, index = 1}})
    assert(#sends == 1)
    -- reconnect: the full backlog again (cumulative semantics)
    G.note_batch({{location = 1, index = 0}, {location = RIPTO_LOC, index = 1}})
    assert(#sends == 1, "reconnect backlog re-reported the goal")
end)

test("reconfigure for a new slot resets the state", function()
    local G = fresh()
    G.configure(sd({"spyro2"}, {spyro2 = {goal_location = RIPTO_LOC}}))
    G.note_batch({{location = RIPTO_LOC, index = 0}})
    assert(#sends == 1)
    G.configure(sd({"spyro1"}, {spyro1 = {goal_location = GNASTY_LOC}}))
    assert(#sends == 1)
    G.note_batch({{location = RIPTO_LOC, index = 0}})
    assert(#sends == 1, "stale goal fired after reconfigure")
    G.note_batch({{location = GNASTY_LOC, index = 1}})
    assert(#sends == 2, "new slot's goal not reported")
end)

test("required game without a goal_location keeps reporting off", function()
    local G = fresh()
    -- ALL_DRAGONS-style: goal_location = 0
    G.configure(sd({"spyro1"}, {spyro1 = {goal_location = 0}}))
    G.note_batch({{location = GNASTY_LOC, index = 0}})
    assert(#sends == 0, "GOAL sent despite goal_location = 0")
    -- no games table at all (old seed shape)
    G.configure(sd({"spyro1"}, nil))
    G.note_batch({{location = GNASTY_LOC, index = 0}})
    assert(#sends == 0, "GOAL sent without any goal configuration")
end)

test("empty required_games never reports", function()
    local G = fresh()
    G.configure(sd({}))
    G.note_batch({{location = RIPTO_LOC, index = 0}})
    assert(#sends == 0, "GOAL sent with nothing required")
    assert(G.sent() == false)
end)

test("send failure is logged and not retried from the same batch", function()
    local G = fresh()
    package.loaded["goal_watch"] = nil
    local mod = require("goal_watch")
    sends = {}
    local fail = true
    mod.init({
        log = function(l) lines[#lines + 1] = l end,
        send = function()
            sends[#sends + 1] = true
            return not fail
        end,
    })
    mod.configure(sd({"spyro2"}, {spyro2 = {goal_location = RIPTO_LOC}}))
    mod.note_batch({{location = RIPTO_LOC, index = 0}})
    assert(#sends == 1)
    assert(not mod.sent(), "marked sent despite a failed StatusUpdate")
    fail = false
    mod.note_batch({{location = RIPTO_LOC, index = 0}})
    assert(#sends == 2, "failed report was not retried on the next batch")
    assert(mod.sent())
end)

test("status() names the pending goal locations", function()
    local G = fresh()
    G.configure(sd({"spyro2"}, {spyro2 = {goal_location = RIPTO_LOC}}))
    local s = G.status()
    assert(type(s) == "string" and s:find("226000", 1, true), "got " .. s)
    G.note_batch({{location = RIPTO_LOC, index = 0}})
    assert(G.status():find("sent=true", 1, true), "got " .. G.status())
end)

print(string.format("%d/%d passed", tests - failed, tests))
os.exit(failed == 0 and 0 or 1)