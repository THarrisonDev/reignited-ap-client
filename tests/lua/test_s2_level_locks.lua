-- Stub-based spec for client/ue4ss_mod/srt_bridge/Scripts/spyro2/level_locks.lua.
-- Mirrors test_level_locks.lua: fakes ExecuteInGameThread (queue +
-- pump with the game-thread flag), portal actors, glyph actors. Every portal
-- write asserts the game-thread flag. Spyro 2 specifics covered here: the
-- 3-homeworld scan gate, the TARGET_HOMES skip (a portal whose partner maps
-- to a homeworld is never locked), and the games.spyro2 slot-data shape.
-- The Summer Forest key is precollected in real seeds, so it is left out of
-- the test KEYS; TARGET_HOMES is what keeps homeworld portals open.
-- Run from the client repo root: lua tests/lua/test_s2_level_locks.lua

local here = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./"
package.path = here .. "../../ue4ss_mod/srt_bridge/Scripts/?.lua;" .. package.path

local function fstring(s) return { ToString = function() return s end } end

local game_thread = false
local queue = {}
local function queue_fn(fn) queue[#queue + 1] = fn end
ExecuteInGameThread = queue_fn
local function pump()
    local jobs = queue
    queue = {}
    for _, fn in ipairs(jobs) do
        game_thread = true
        fn()
        game_thread = false
    end
end
local function as_game(fn) game_thread = true; fn(); game_thread = false end

local now = 1000
os.time = function() return now end

-- ---------------------------------------------------------------------------
-- fake portals
-- ---------------------------------------------------------------------------
local next_addr = 100
local function new_portal(code, name)
    next_addr = next_addr + 1
    local P = { addr = next_addr, remakes = 0, glyphs = {} }
    P.props = { PartnerPortalName = code .. "_LevelStart", EnableTransport = true, PreloadEnabled = true }
    local function spawn(text)
        P.glyphs = {}
        for ch in text:gmatch("%S") do P.glyphs[#P.glyphs + 1] = { ch = ch, hidden = true } end
    end
    spawn(name)
    for _, g in ipairs(P.glyphs) do g.hidden = false end -- portal init revealed them
    local cprops = { ["display text"] = name, Scale = 1.0, ["default char width"] = 22.0 }
    local characters = {
        GetArrayNum = function() return #P.glyphs end,
        ForEach = function(_, cb)
            for i, g in ipairs(P.glyphs) do
                local actor = setmetatable({}, { __index = function(_, k)
                    if k == "IsValid" then return function() return true end end
                    if k == "SetActorHiddenInGame" then return function(_, h)
                        assert(game_thread, "glyph visibility changed off the game thread")
                        g.hidden = h
                    end end
                end })
                cb(i, { get = function() return actor end })
            end
        end,
    }
    local comp = setmetatable({}, { __index = function(_, k)
        if k == "IsValid" then return function() return true end end
        if k == "Characters" then return characters end
        if k == "REMAKE text" then return function(text, scale, width)
            assert(game_thread, "REMAKE text called off the game thread")
            assert(scale == 1.0 and width == 22.0, "REMAKE must reuse the component's scale/width")
            P.remakes = P.remakes + 1
            cprops["display text"] = text
            spawn(text)
        end end
        local v = cprops[k]
        if type(v) == "string" then return fstring(v) end
        return v
    end })
    P.actor = setmetatable({}, { __index = function(_, k)
        if k == "IsValid" then return function() return true end end
        if k == "GetAddress" then return function() return P.addr end end
        if k == "PortalNameComponent" then return comp end
        if k == "setPortalEnabled" then return function(_, en)
            assert(game_thread, "setPortalEnabled called off the game thread")
            P.props.EnableTransport, P.props.PreloadEnabled = en, en
            for _, g in ipairs(P.glyphs) do g.hidden = not en end
        end end
        local v = P.props[k]
        if type(v) == "string" then return fstring(v) end
        return v
    end })
    function P.text() return cprops["display text"] end
    function P.visible()
        local s = {}
        for _, g in ipairs(P.glyphs) do if not g.hidden then s[#s + 1] = g.ch end end
        return table.concat(s)
    end
    return P
end

local world = { portals = {} }
function FindAllOf(cls)
    if cls ~= "PortalTransporter_C" then return nil end
    local out = {}
    for _, P in ipairs(world.portals) do out[#out + 1] = P.actor end
    return out
end

local level = "/LS201_SummerForest_Home/Maps/"
local gs = setmetatable({}, { __index = function(_, k)
    if k == "current level" then return fstring(level) end
end })

local regions = {
    ["/LS201_SummerForest_Home/Maps/"] = "Summer Forest",
    ["/LS202_Glimmer/Maps/"] = "Glimmer",
    ["/LS203_IdolSprings/Maps/"] = "Idol Springs",
    ["/LS204_Colossus/Maps/"] = "Colossus",
    ["/LS208_CrushsDungeon/Maps/"] = "Crush's Dungeon",
    ["/LS210_AutumnPlains_Home/Maps/"] = "Autumn Plains",
    ["/LS222_WinterTundra_Home/Maps/"] = "Winter Tundra",
    ["/LS223_MysticMarsh/Maps/"] = "Mystic Marsh",
}
local KEYS = {
    ["Glimmer"] = "Spyro 2: Glimmer Key",
    ["Idol Springs"] = "Spyro 2: Idol Springs Key",
    ["Crush's Dungeon"] = "Spyro 2: Crush's Dungeon Key",
    ["Autumn Plains"] = "Spyro 2: Autumn Plains Key",
}
local function spyro2_sd(options, level_keys)
    return {
        included_games = { "spyro2" },
        required_games = { "spyro2" },
        options = { death_link = 0 },
        games = { spyro2 = { options = options, level_keys = level_keys } },
        seed = "S2", slot = "P1",
    }
end
local SD = spyro2_sd({ level_locks = 1 }, KEYS)

-- ---------------------------------------------------------------------------
-- harness
-- ---------------------------------------------------------------------------
local lines = {}
local function fresh()
    package.loaded["spyro2.level_locks"] = nil
    queue = {}
    local L = require("spyro2.level_locks")
    lines = {}
    L.init({ log = function(l) lines[#lines + 1] = l end, regions = regions })
    level = "/LS201_SummerForest_Home/Maps/"
    world.portals = {
        new_portal("LS202", "Glimmer"),
        new_portal("LS203", "Idol Springs"),
        new_portal("LS208", "Crush's Dungeon"),
        new_portal("LS204", "Colossus"),
        new_portal("LS210", "Autumn Plains"),
    }
    return L, world.portals[1], world.portals[2], world.portals[3], world.portals[4], world.portals[5]
end
-- one async poll, then the game thread runs whatever was queued
local function ticks(L, n) for _ = 1, n do L.tick(gs); pump() end end
local function settle(L) ticks(L, 12) end

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

test("disabled when level_locks is off", function()
    local L, gl = fresh()
    L.configure(spyro2_sd({ level_locks = 0 }, {}))
    L.note_item("Spyro 2: Glimmer Key")
    settle(L)
    assert(gl.props.EnableTransport == true and gl.remakes == 0 and #queue == 0)
end)

test("old top-level slot data shape does not enable locks", function()
    local L, gl = fresh()
    L.configure({ options = { level_locks = 1 }, level_keys = KEYS })
    L.note_item("Spyro 2: Glimmer Key")
    settle(L)
    assert(gl.props.EnableTransport == true and gl.remakes == 0 and #queue == 0)
    assert(L.status() == "spyro2 enabled=false keys=0/0 locked_here=0", "got " .. L.status())
end)

test("games.spyro2 slot data shape enables locks", function()
    local L, gl, idol = fresh()
    L.configure(SD)
    L.note_item("Spyro 2: Crush's Dungeon Key")
    settle(L)
    assert(L.status():match("^spyro2 enabled=true keys=1/4"), "got " .. L.status())
    assert(gl.props.EnableTransport == false and gl.visible() == "LOCKED")
    assert(idol.props.EnableTransport == false and idol.visible() == "LOCKED")
end)

test("unprefixed key names do not unlock", function()
    local L, gl = fresh()
    L.configure(SD)
    L.note_item("Glimmer Key")
    settle(L)
    assert(gl.props.EnableTransport == false and gl.visible() == "LOCKED")
end)

test("waits for the item backlog, then the grace period", function()
    local L, gl = fresh()
    L.configure(SD)
    settle(L)
    assert(gl.props.EnableTransport == true, "locked before backlog/grace")
    now = now + 3
    ticks(L, 1)
    assert(gl.props.EnableTransport == false, "grace expiry should lock")
end)

test("locked portal: no transport, no preview, LOCKED visible", function()
    local L, gl, idol, crush, colossus, autumn = fresh()
    L.configure(SD)
    L.note_item("Spyro 2: Crush's Dungeon Key")
    settle(L)
    assert(gl.props.EnableTransport == false and gl.props.PreloadEnabled == false)
    assert(gl.text() == "LOCKED" and gl.visible() == "LOCKED" and gl.remakes == 1,
        "got text=" .. gl.text() .. " visible=" .. gl.visible())
    assert(crush.props.EnableTransport == true and crush.remakes == 0, "held key stays open")
    assert(colossus.props.EnableTransport == true and colossus.remakes == 0, "level without a key untouched")
    assert(idol.props.EnableTransport == false and idol.visible() == "LOCKED")
    assert(autumn.props.EnableTransport == true and autumn.remakes == 0,
        "a portal targeting a homeworld is never locked (TARGET_HOMES)")
end)

test("several locks queue one game-thread job at a time", function()
    local L, gl, idol = fresh()
    L.configure(SD)
    L.note_item("Spyro 2: Crush's Dungeon Key")
    ticks(L, 7)
    for _ = 1, 5 do L.tick(gs) end -- async polls while the game thread is busy
    assert(#queue == 1, "expected 1 queued job, got " .. #queue)
    assert(gl.props.EnableTransport == true and idol.props.EnableTransport == true,
        "nothing may be written before the game thread runs the job")
    pump()
    local locked = (gl.props.EnableTransport == false and 1 or 0) + (idol.props.EnableTransport == false and 1 or 0)
    assert(locked == 1, "one job locks exactly one portal")
    ticks(L, 1)
    assert(gl.props.EnableTransport == false and idol.props.EnableTransport == false, "next poll locks the other")
    assert(gl.visible() == "LOCKED" and idol.visible() == "LOCKED")
end)

test("TARGET_HOMES: a portal targeting Autumn Plains never locks without its key", function()
    local L = fresh()
    level = "/LS222_WinterTundra_Home/Maps/"
    world.portals = {
        new_portal("LS223", "Mystic Marsh"),
        new_portal("LS210", "Autumn Plains"),
    }
    L.configure(spyro2_sd({ level_locks = 1 }, {
        ["Mystic Marsh"] = "Spyro 2: Mystic Marsh Key",
        ["Autumn Plains"] = "Spyro 2: Autumn Plains Key",
    }))
    now = now + 3 -- past the connect grace period (no backlog items in this test)
    settle(L)
    assert(world.portals[1].props.EnableTransport == false and world.portals[1].visible() == "LOCKED",
        "a realm portal with an unheld key must lock")
    assert(world.portals[2].props.EnableTransport == true and world.portals[2].remakes == 0,
        "the homeworld-target portal must stay open while its key is not held")
end)

test("game re-enable is re-locked and LOCKED re-revealed without a rebuild", function()
    local L, gl = fresh()
    L.configure(SD)
    L.note_item("Spyro 2: Crush's Dungeon Key")
    settle(L)
    as_game(function() gl.actor:setPortalEnabled(true) end) -- exit-from-portal sequence finishing
    ticks(L, 1)
    assert(gl.props.EnableTransport == false and gl.remakes == 1)
    assert(gl.visible() == "LOCKED", "got visible=" .. gl.visible())
end)

test("receiving the key unlocks and restores the visible name", function()
    local L, gl, idol = fresh()
    L.configure(SD)
    L.note_item("Spyro 2: Crush's Dungeon Key")
    settle(L)
    L.note_item("Spyro 2: Glimmer Key")
    ticks(L, 1)
    assert(gl.props.EnableTransport == true and gl.props.PreloadEnabled == true)
    assert(gl.text() == "Glimmer" and gl.visible() == "Glimmer" and gl.remakes == 2,
        "got text=" .. gl.text() .. " visible=" .. gl.visible())
    assert(idol.props.EnableTransport == false, "a key for one portal does not unlock the other")
    ticks(L, 5)
    assert(gl.remakes == 2, "no further rebuilds once unlocked")
end)

test("a job that never runs is abandoned after the timeout", function()
    local L = fresh()
    L.configure(SD)
    L.note_item("Spyro 2: Crush's Dungeon Key")
    ticks(L, 8) -- first poll only records the level; 7 more reach STABLE_TICKS - 1
    L.tick(gs)
    assert(#queue == 1, "expected the lock job to be queued")
    now = now + 4
    L.tick(gs)
    assert(#queue == 1, "still waiting inside the timeout")
    now = now + 1
    L.tick(gs)
    assert(#queue == 2, "timed-out job should be abandoned and a new one submitted")
    local warned = false
    for _, l in ipairs(lines) do if l:match("never finished") then warned = true end end
    assert(warned, "abandoning a job should be logged")
end)

test("no game-thread API means no writes at all", function()
    ExecuteInGameThread = nil
    local L, gl = fresh()
    L.configure(SD)
    L.note_item("Spyro 2: Crush's Dungeon Key")
    settle(L)
    assert(gl.props.EnableTransport == true and gl.remakes == 0)
    assert(L.status():match("^spyro2 enabled=false"))
end)

test("no writes outside homeworlds or before the level settles", function()
    local L, gl = fresh()
    L.configure(SD)
    L.note_item("Spyro 2: Crush's Dungeon Key")
    ticks(L, 5)
    assert(gl.props.EnableTransport == true, "wrote before the stable-level gate")
    level = "/LS202_Glimmer/Maps/"
    settle(L)
    assert(gl.props.EnableTransport == true and gl.remakes == 0, "wrote in a non-homeworld level")
end)

test("reconfigure for a new seed forgets old keys", function()
    local L, gl = fresh()
    L.configure(SD)
    L.note_item("Spyro 2: Glimmer Key")
    settle(L)
    assert(gl.props.EnableTransport == true)
    L.configure(SD)
    L.note_item("Spyro 2: Crush's Dungeon Key")
    ticks(L, 1)
    assert(gl.props.EnableTransport == false and gl.visible() == "LOCKED")
end)

test("status reports held keys and locked portals", function()
    local L = fresh()
    L.configure(SD)
    L.note_item("Spyro 2: Crush's Dungeon Key")
    settle(L)
    local s = L.status()
    assert(s == "spyro2 enabled=true keys=1/4 locked_here=2", "got " .. s)
end)

print(string.format("%d/%d passed", tests - failed, tests))
os.exit(failed == 0 and 0 or 1)