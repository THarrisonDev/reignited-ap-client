-- Author: Tim Harrison
-- Created: 2026-09-26
-- Updated: 2026-10-11

-- Spec for client/ue4ss_mod/srt_bridge/Scripts/session_gate.lua: the AP
-- session opens only once the player is in play on a Spyro 1, Spyro 2 or
-- Spyro 3 save, and closes at the main menu.
-- Run from the client repo root: lua tests/lua/test_session_gate.lua

local here = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./"
package.path = here .. "../../ue4ss_mod/srt_bridge/Scripts/?.lua;" .. package.path

local GATE = require("session_gate")
local MENU, LOADING, IN_PLAY, PAUSED = 0, 1, 3, 4

local logs = {}
local function fresh()
    logs = {}
    GATE.init({log = function(l) logs[#logs + 1] = l end})
end

local reads = 0
local function slot_reader(s, g)
    return function()
        reads = reads + 1
        return s, g
    end
end

local passed, total = 0, 0
local function case(name, fn)
    total = total + 1
    fresh()
    reads = 0
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        print("PASS " .. name)
    else
        print("FAIL " .. name .. ": " .. tostring(err))
    end
end

local function eq(got, want, what)
    if got ~= want then
        error(string.format("%s: got %s, want %s", what, tostring(got), tostring(want)), 2)
    end
end

case("main menu never opens and never reads the slot", function()
    for _ = 1, 10 do eq(GATE.tick(MENU, slot_reader(0, 0)), nil, "menu tick") end
    eq(reads, 0, "slot reads at the menu")
    eq(GATE.is_open(), false, "open")
end)

case("opens after STABLE_TICKS consecutive in-play ticks", function()
    GATE.tick(MENU, slot_reader(1, 0))
    GATE.tick(LOADING, slot_reader(1, 0))
    eq(GATE.tick(IN_PLAY, slot_reader(1, 0)), nil, "first in-play tick")
    local action, s, g = GATE.tick(IN_PLAY, slot_reader(1, 0))
    eq(action, "open", "second in-play tick")
    eq(s, 1, "slot")
    eq(g, 0, "game")
    eq(GATE.status(), "open(slot=1 game=0)", "status")
end)

case("a non-play state between in-play ticks restarts the count", function()
    GATE.tick(IN_PLAY, slot_reader(0, 0))
    GATE.tick(LOADING, slot_reader(0, 0))
    eq(GATE.tick(IN_PLAY, slot_reader(0, 0)), nil, "count restarted")
    eq(GATE.tick(IN_PLAY, slot_reader(0, 0)), "open", "opens after restart")
end)

case("stays open through pauses, cutscenes and level loads", function()
    GATE.tick(IN_PLAY, slot_reader(0, 0))
    GATE.tick(IN_PLAY, slot_reader(0, 0))
    for _, st in ipairs({PAUSED, LOADING, 5, 6, 7, IN_PLAY}) do
        eq(GATE.tick(st, slot_reader(0, 0)), nil, "state " .. st)
    end
    eq(GATE.is_open(), true, "open")
end)

case("returning to the main menu closes, and another slot reopens", function()
    GATE.tick(IN_PLAY, slot_reader(0, 0))
    GATE.tick(IN_PLAY, slot_reader(0, 0))
    eq(GATE.tick(MENU, slot_reader(0, 0)), "close", "menu closes")
    eq(GATE.tick(MENU, slot_reader(0, 0)), nil, "close fires once")
    GATE.tick(IN_PLAY, slot_reader(2, 0))
    local action, s = GATE.tick(IN_PLAY, slot_reader(2, 0))
    eq(action, "open", "reopen")
    eq(s, 2, "new slot")
end)

case("a Spyro 2 save opens a session", function()
    GATE.tick(IN_PLAY, slot_reader(1, 1))
    local action, s, g = GATE.tick(IN_PLAY, slot_reader(1, 1))
    eq(action, "open", "spyro 2 opens")
    eq(s, 1, "slot")
    eq(g, 1, "game")
    eq(#logs, 0, "no refusal logged")
end)

case("a Spyro 3 save opens a session", function()
    GATE.tick(IN_PLAY, slot_reader(0, 2))
    local action, s, g = GATE.tick(IN_PLAY, slot_reader(0, 2))
    eq(action, "open", "spyro 3 opens")
    eq(s, 0, "slot")
    eq(g, 2, "game")
    eq(GATE.status(), "open(slot=0 game=2)", "status")
    eq(#logs, 0, "no refusal logged")
end)

case("game keys and names", function()
    eq(GATE.game_key(0), "spyro1", "key 0")
    eq(GATE.game_key(1), "spyro2", "key 1")
    eq(GATE.game_key(2), "spyro3", "key 2")
    eq(GATE.game_key(7), nil, "unknown key")
    eq(GATE.game_name(1), "Spyro 2", "name 1")
end)

case("is_included checks slot_data.included_games", function()
    local both = {included_games = {"spyro1", "spyro2"}}
    local s2only = {included_games = {"spyro2"}}
    eq(GATE.is_included(both, 0), true, "spyro1 in both")
    eq(GATE.is_included(both, 1), true, "spyro2 in both")
    eq(GATE.is_included(both, 2), false, "spyro3 not in both")
    eq(GATE.is_included(s2only, 0), false, "spyro1 not in s2-only")
    eq(GATE.is_included({included_games = {"spyro1"}}, 1), false, "spyro2 not in s1-only")
    eq(GATE.is_included(nil, 5), false, "unknown game")
end)

case("missing included_games falls back to Spyro 1 only", function()
    eq(GATE.is_included({}, 0), true, "old seed spyro1")
    eq(GATE.is_included({}, 1), false, "old seed spyro2")
    eq(GATE.is_included(nil, 0), true, "no slot data spyro1")
end)

case("an unreadable slot keeps retrying without opening", function()
    for _ = 1, 4 do eq(GATE.tick(IN_PLAY, slot_reader(nil, nil)), nil, "unreadable tick") end
    eq(#logs, 1, "unreadable log lines")
    eq(GATE.tick(IN_PLAY, slot_reader(0, 0)), "open", "opens once readable")
end)

case("non-number states are ignored", function()
    eq(GATE.tick(nil, slot_reader(0, 0)), nil, "nil state")
    eq(GATE.tick("3", slot_reader(0, 0)), nil, "string state")
    eq(reads, 0, "slot reads")
end)

print(string.format("%d/%d passed", passed, total))
if passed ~= total then os.exit(1) end
