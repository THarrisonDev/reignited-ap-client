-- Author: Tim Harrison
-- Created: 2026-11-03
-- Updated: 2026-11-03

-- Stub-based spec for the guide-book visit modules
-- (Scripts/guidebook_core.lua behind spyroN/guidebook.lua). Fakes the
-- gamestate's `set level visited` / `get level visited` pair: the write records
-- itself and the readback answers from that record, so a write the game did not
-- take is visible to the module's own readback. ExecuteInGameThread only
-- QUEUES work; H.pump() runs it with the game-thread flag set, and every write
-- asserts that flag (level_locks hardlock lesson).
-- Run from the client repo root: lua tests/lua/test_guidebook.lua

package.path = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "support/?.lua;" .. package.path
local H = require("harness")

H.install_game_thread()

local STONE_PATH, HOLLOW_PATH, GLIMMER_PATH =
    "/LS102_StoneHill/Maps/", "/LS103_DarkHollow/Maps/", "/LS202_Glimmer/Maps/"

local REGIONS = {
    [STONE_PATH] = "Stone Hill",
    [HOLLOW_PATH] = "Dark Hollow",
    [GLIMMER_PATH] = "Glimmer",
}

local STONE_KEY, HOLLOW_KEY, GLIMMER_KEY =
    "Spyro 1: Stone Hill Key", "Spyro 1: Dark Hollow Key", "Spyro 2: Glimmer Key"

local world = { visited = {}, calls = {}, ignore_set = false, set_errors = false, wrapped = false }
local level = STONE_PATH

local gs = setmetatable({
    IsValid = function() return true end,
    ["set level visited"] = function(path)
        assert(H.thread, "visit write off the game thread")
        world.calls[#world.calls + 1] = { fn = "set", path = path, thread = H.thread }
        if world.set_errors then error("boom") end
        if not world.ignore_set then world.visited[path] = true end
    end,
    ["get level visited"] = function(path, out)
        assert(H.thread, "visit readback off the game thread")
        world.calls[#world.calls + 1] = { fn = "get", path = path, thread = H.thread }
        out.visited = world.wrapped and { value = world.visited[path] == true } or world.visited[path] == true
    end,
}, { __index = function(_, k)
    if k == "current level" then return H.fstring(level) end
    return nil
end })

local SD = {
    included_games = { "spyro1", "spyro2" },
    games = {
        spyro1 = { level_keys = { ["Stone Hill"] = STONE_KEY, ["Dark Hollow"] = HOLLOW_KEY } },
        spyro2 = { level_keys = { ["Glimmer"] = GLIMMER_KEY } },
    },
}
-- a key whose region is in the slot data but in no level path table
local MISSING_SD = {
    games = { spyro1 = { level_keys = { ["Nowhere"] = "Spyro 1: Nowhere Key" } } },
}

-- ---------------------------------------------------------------------------
-- harness
-- ---------------------------------------------------------------------------
local function fresh(name)
    H.new_fixture(REGIONS)
    H.clear_queue()
    package.loaded["spyro1.guidebook"] = nil
    package.loaded["spyro2.guidebook"] = nil
    package.loaded["spyro3.guidebook"] = nil
    world.visited, world.calls = {}, {}
    world.ignore_set, world.set_errors, world.wrapped = false, false, false
    level = STONE_PATH
    local G = require(name or "spyro1.guidebook")
    H.clear_log()
    G.init({ log = H.collect, regions = REGIONS })
    return G
end
local ticks, settle, calls_of = H.module_helpers(function() return gs end,
    function() return world.calls end)

local test = H.test

test("a received key lists its level once the level settles", function()
    local G = fresh()
    G.configure(SD)
    G.note_item(STONE_KEY, 0)
    for _ = 1, 8 do H.tick(G, gs) end
    assert(H.queued() == 0, "queued a visit before 8 stable ticks")
    H.tick(G, gs)
    assert(H.queued() == 1, "expected one queued job, got " .. H.queued())
    H.pump()
    local sets = calls_of("set")
    assert(#sets == 1 and sets[1].path == STONE_PATH,
        "expected one visit write for Stone Hill, got " .. #sets)
    assert(world.visited[STONE_PATH] == true, "Stone Hill not marked visited")
    settle(G)
    assert(#calls_of("set") == 1, "wrote again after the level was listed")
    local s = G.status()
    assert(s:find("listed=1", 1, true) and s:find("pending=0", 1, true), "status: " .. s)
end)

test("no key: nothing is queued", function()
    local G = fresh()
    G.configure(SD)
    settle(G)
    assert(H.queued() == 0 and #world.calls == 0, "queued a visit without a key")
end)

test("a non-key item queues nothing", function()
    local G = fresh()
    G.configure(SD)
    G.note_item("Extra Life", 3)
    G.note_item(nil, 4)
    settle(G)
    assert(#world.calls == 0, "a non-key item queued a visit")
end)

test("duplicate keys write once", function()
    local G = fresh()
    G.configure(SD)
    G.note_item(STONE_KEY, 0)
    G.note_item(STONE_KEY, 0)
    G.note_item(STONE_KEY, 1)
    settle(G)
    assert(#calls_of("set") == 1, "duplicate notes wrote " .. #calls_of("set") .. " times")
end)

test("a write the game does not reflect is retried after the backoff", function()
    local G = fresh()
    G.configure(SD)
    world.ignore_set = true
    G.note_item(STONE_KEY, 0)
    settle(G)
    assert(#calls_of("set") == 1, "expected one attempt, got " .. #calls_of("set"))
    local s = G.status()
    assert(s:find("listed=0", 1, true) and s:find("pending=1", 1, true), "status: " .. s)
    H.advance(6)
    settle(G)
    assert(#calls_of("set") == 2, "no retry after the backoff, attempts: " .. #calls_of("set"))
end)

test("a table-wrapped readback still counts as listed", function()
    local G = fresh()
    G.configure(SD)
    world.wrapped = true
    G.note_item(STONE_KEY, 0)
    settle(G)
    assert(world.visited[STONE_PATH] == true, "Stone Hill not marked visited")
    assert(G.status():find("listed=1", 1, true), "wrapped readback not detected: " .. G.status())
end)

test("a throwing write does not crash and is retried", function()
    local G = fresh()
    G.configure(SD)
    world.set_errors = true
    G.note_item(STONE_KEY, 0)
    settle(G)
    assert(#calls_of("set") == 1, "expected one attempt, got " .. #calls_of("set"))
    assert(H.logged("ERROR visit Stone Hill", true), "missing the runner's failed-job ERROR")
    H.advance(6)
    settle(G)
    assert(#calls_of("set") == 2, "no retry after a throwing write, attempts: " .. #calls_of("set"))
end)

test("no visit on a load screen or before the level settles", function()
    local G = fresh()
    G.configure(SD)
    G.note_item(STONE_KEY, 0)
    level = "/Game/Maps/LoadScreen"
    settle(G)
    assert(#world.calls == 0, "wrote on a load screen")
    level = STONE_PATH
    ticks(G, 5)
    assert(#world.calls == 0, "wrote before 8 stable ticks")
    ticks(G, 8)
    assert(world.visited[STONE_PATH] == true, "no visit after the level settled")
end)

test("configure({}) drops a queued visit", function()
    local G = fresh()
    G.configure(SD)
    G.note_item(STONE_KEY, 0)
    G.configure({})
    settle(G)
    assert(#world.calls == 0, "queued visit survived configure({})")
    local s = G.status()
    assert(s:find("keys=0/0", 1, true) and s:find("enabled=false", 1, true), "status: " .. s)
end)

test("a key with no level path warns once and queues nothing", function()
    local G = fresh()
    G.configure(MISSING_SD)
    G.note_item("Spyro 1: Nowhere Key", 0)
    G.note_item("Spyro 1: Nowhere Key", 1)
    settle(G)
    assert(#world.calls == 0, "queued a visit for a region with no level path")
    assert(H.count_logged("no level path for Nowhere", true) == 1, "expected one no-path WARN")
    assert(G.status():find("keys=0/1", 1, true), "status: " .. G.status())
end)

test("the spyro2 wrapper reads games.spyro2.level_keys", function()
    local G = fresh("spyro2.guidebook")
    G.configure(SD)
    assert(G.tag == "[GUIDE2]", "tag: " .. tostring(G.tag))
    G.note_item(STONE_KEY, 0)
    settle(G)
    assert(#world.calls == 0, "a spyro1 key triggered a spyro2 write")
    G.note_item(GLIMMER_KEY, 1)
    settle(G)
    local sets = calls_of("set")
    assert(#sets == 1 and sets[1].path == GLIMMER_PATH, "expected one visit write for Glimmer")
    assert(world.visited[GLIMMER_PATH] == true, "Glimmer not marked visited")
    assert(G.status():find("spyro2 ", 1, true), "status missing the spyro2 prefix: " .. G.status())
end)

H.finish()
