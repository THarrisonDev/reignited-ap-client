-- Author: Tim Harrison
-- Created: 2026-09-26
-- Updated: 2026-10-11

-- Spec for client/ue4ss_mod/srt_bridge/Scripts/data_pkg.lua.
-- Fakes process/resolve/log; exercises the connect-time backlog: items whose
-- names are "Unknown"/"?" before the AP data package loads park as
-- (index -> item_id) and are replayed exactly once by tick(true).
-- Run from the client repo root: lua tests/lua/test_data_pkg.lua

local here = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./"
package.path = here .. "../../ue4ss_mod/srt_bridge/Scripts/?.lua;" .. package.path

local lines = {}
local applied = {}       -- {name=..., index=...} in process() call order
local fail_on_index = nil
local resolved = {}      -- item_id -> name
local resolve_calls = {}

local function fresh()
    package.loaded["data_pkg"] = nil
    lines = {}
    applied = {}
    fail_on_index = nil
    resolved = {}
    resolve_calls = {}
    local D = require("data_pkg")
    D.init({
        log = function(l) lines[#lines + 1] = l end,
        process = function(name, index)
            if index == fail_on_index then error("boom for index " .. tostring(index)) end
            applied[#applied + 1] = { name = name, index = index }
        end,
        resolve = function(item_id)
            resolve_calls[#resolve_calls + 1] = item_id
            return resolved[item_id]
        end,
    })
    return D
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

test("usable names apply inline immediately and park nothing", function()
    local D = fresh()
    D.note("Spyro 1: Toasty Key", 7, 100117)
    assert(#applied == 1 and applied[1].name == "Spyro 1: Toasty Key" and applied[1].index == 7,
        "usable name not applied inline")
    D.tick(true)
    assert(#applied == 1, "usable item was replayed by tick")
    assert(#resolve_calls == 0, "resolve called with nothing parked")
end)

test("?, Unknown and nil names park the item without processing", function()
    local D = fresh()
    D.note("?", 3, 100117)
    D.note("Unknown", 4, 100118)
    D.note(nil, 5, 100119)
    assert(#applied == 0, "parked items were processed")
    resolved[100117] = "Spyro 1: Toasty Key"
    resolved[100118] = "Spyro 1: Dragon"
    resolved[100119] = "Spyro 1: Extra Life"
    D.tick(true)
    assert(#applied == 3, "parked items not all applied")
end)

test("a later usable name clears the parked entry for its index", function()
    local D = fresh()
    D.note("?", 3, 100117)
    D.note("Spyro 1: Toasty Key", 3, 100117)
    D.tick(true)
    assert(#applied == 1 and applied[1].name == "Spyro 1: Toasty Key",
        "parked entry re-applied a name that already arrived")
    assert(#resolve_calls == 0, "resolve called for a cleared entry")
end)

test("tick(false) does nothing; parked entries survive", function()
    local D = fresh()
    D.note("?", 3, 100117)
    D.tick(false)
    D.tick(false)
    assert(#applied == 0, "tick(false) processed parked items")
    resolved[100117] = "Spyro 1: Toasty Key"
    D.tick(true)
    assert(#applied == 1, "parked entry lost by tick(false)")
end)

test("tick(true) applies every parked item exactly once via resolve", function()
    local D = fresh()
    resolved[100117] = "Spyro 1: Toasty Key"
    resolved[100123] = "Spyro 1: Dragon"
    D.note("?", 3, 100117)
    D.note("?", 8, 100123)
    D.tick(true)
    assert(#applied == 2, "expected 2 applied, got " .. #applied)
    table.sort(resolve_calls)
    assert(#resolve_calls == 2 and resolve_calls[1] == 100117 and resolve_calls[2] == 100123,
        "resolve did not receive the parked item ids")
    D.tick(true)
    assert(#applied == 2, "second tick(true) re-applied")
    local said = false
    for _, l in ipairs(lines) do
        if l:find("backlog item", 1, true) then said = true end
    end
    assert(said, "no backlog-applied log line")
end)

test("an item still unresolvable after the package is valid is dropped", function()
    local D = fresh()
    resolved[100117] = "?"
    D.note("?", 3, 100117)
    D.tick(true)
    assert(#applied == 0, "unresolvable item was applied")
    assert(#resolve_calls == 1, "item was retried beyond its single resolve")
    for _, l in ipairs(lines) do
        assert(not l:find("ERROR", 1, true), "ERROR logged for a dropped item: " .. l)
    end
end)

test("a throwing process logs ERROR; the remaining parked items still apply", function()
    local D = fresh()
    resolved[100117] = "Spyro 1: Toasty Key"
    resolved[100123] = "Spyro 1: Dragon"
    D.note("?", 3, 100117)
    D.note("?", 8, 100123)
    fail_on_index = 3
    D.tick(true)
    fail_on_index = nil
    assert(#applied == 1 and applied[1].index == 8,
        "remaining parked items did not apply after one failure")
    local errored = false
    for _, l in ipairs(lines) do
        if l:find("ERROR", 1, true) then errored = true end
    end
    assert(errored, "no ERROR logged for the failed apply")
end)

test("reset() clears parked entries and the loaded flag", function()
    local D = fresh()
    resolved[100117] = "Spyro 1: Toasty Key"
    resolved[100123] = "Spyro 1: Dragon"
    D.note("?", 3, 100117)
    D.tick(true)
    assert(#applied == 1 and applied[1].index == 3, "pre-reset item not applied")
    D.reset()
    D.note("?", 8, 100123)
    D.tick(true)
    assert(#applied == 2 and applied[2].index == 8 and applied[2].name == "Spyro 1: Dragon",
        "reset failed to clear the loaded flag (parked item never applied)")
    local threes = 0
    for _, a in ipairs(applied) do
        if a.index == 3 then threes = threes + 1 end
    end
    assert(threes == 1, "a parked entry survived reset (index 3 applied " .. threes .. "x)")
    D.tick(true)
    assert(#applied == 2, "re-applied after the post-reset replay")
end)

test("duplicate parking of the same index overwrites (last item_id wins)", function()
    local D = fresh()
    resolved[100123] = "Spyro 1: Dragon"
    D.note("?", 8, 100117)
    D.note("?", 8, 100123)
    D.tick(true)
    assert(#resolve_calls == 1 and resolve_calls[1] == 100123,
        "resolve did not see only the last parked item_id")
    assert(#applied == 1 and applied[1].name == "Spyro 1: Dragon" and applied[1].index == 8,
        "parked item resolved to the wrong name")
end)

print(string.format("%d/%d passed", tests - failed, tests))
os.exit(failed == 0 and 0 or 1)