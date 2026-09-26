-- Stub-based spec for client/ue4ss_mod/srt_bridge/Scripts/spyro3/level_locks.lua.
-- Mirrors test_s2_level_locks.lua: fakes ExecuteInGameThread (queue +
-- pump with the game-thread flag), portal actors, glyph actors. Every portal
-- write asserts the game-thread flag. Spyro 3 specifics covered here: the
-- 4-homeworld scan gate, the TARGET_HOMES skip (a portal whose partner maps
-- to a homeworld is never locked), the FindAllOf("BasePortal_C") class, and
-- the games.spyro3 slot-data shape (no precollected spawn key — Sunrise
-- Spring is a homeworld).
-- Run from the client repo root: lua tests/lua/test_s3_level_locks.lua

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
    if cls ~= "BasePortal_C" then return nil end
    local out = {}
    for _, P in ipairs(world.portals) do out[#out + 1] = P.actor end
    return out
end

local level = "/LS301_SunriseSpring_Home/Maps/"
local gs = setmetatable({}, { __index = function(_, k)
    if k == "current level" then return fstring(level) end
end })

local regions = {
    ["/LS301_SunriseSpring_Home/Maps/"] = "Sunrise Spring",
    ["/LS302_SunnyVilla/Maps/"] = "Sunny Villa",
    ["/LS303_CloudSpires/Maps/"] = "Cloud Spires",
    ["/LS308_BuzzsDungeon/Maps/"] = "Buzz's Dungeon",
    ["/LS310_MiddayGardens_Home/Maps/"] = "Midday Gardens",
    ["/LS311_IcyPeak/Maps/"] = "Icy Peak",
    ["/LS319_EveningLake_Home/Maps/"] = "Evening Lake",
    ["/LS320_LostFleet/Maps/"] = "Lost Fleet",
    ["/LS328_MidnightMountain_Home/Maps/"] = "Midnight Mountain",
    ["/LS329_CrystalIslands/Maps/"] = "Crystal Islands",
}
local KEYS = {
    ["Sunny Villa"] = "Spyro 3: Sunny Villa Key",
    ["Cloud Spires"] = "Spyro 3: Cloud Spires Key",
    ["Buzz's Dungeon"] = "Spyro 3: Buzz's Dungeon Key",
    ["Midday Gardens"] = "Spyro 3: Midday Gardens Key",
}
local function spyro3_sd(options, level_keys)
    return {
        included_games = { "spyro3" },
        required_games = { "spyro3" },
        options = { death_link = 0 },
        games = { spyro3 = { options = options, level_keys = level_keys } },
        seed = "S3", slot = "P1",
    }
end
local SD = spyro3_sd({ level_locks = 1 }, KEYS)

-- ---------------------------------------------------------------------------
-- harness
-- ---------------------------------------------------------------------------
local lines = {}
local function fresh()
    package.loaded["spyro3.level_locks"] = nil
    queue = {}
    local L = require("spyro3.level_locks")
    lines = {}
    L.init({ log = function(l) lines[#lines + 1] = l end, regions = regions })
    level = "/LS301_SunriseSpring_Home/Maps/"
    world.portals = {
        new_portal("LS302", "Sunny Villa"),
        new_portal("LS303", "Cloud Spires"),
        new_portal("LS308", "Buzz's Dungeon"),
        new_portal("LS329", "Crystal Islands"),
        new_portal("LS310", "Midday Gardens"),
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
    local L, sunny = fresh()
    L.configure(spyro3_sd({ level_locks = 0 }, {}))
    L.note_item("Spyro 3: Sunny Villa Key")
    settle(L)
    assert(sunny.props.EnableTransport == true and sunny.remakes == 0 and #queue == 0)
end)

test("old top-level slot data shape does not enable locks", function()
    local L, sunny = fresh()
    L.configure({ options = { level_locks = 1 }, level_keys = KEYS })
    L.note_item("Spyro 3: Sunny Villa Key")
    settle(L)
    assert(sunny.props.EnableTransport == true and sunny.remakes == 0 and #queue == 0)
    assert(L.status() == "spyro3 enabled=false keys=0/0 locked_here=0", "got " .. L.status())
end)

test("games.spyro3 slot data shape enables locks", function()
    local L, sunny, cloud = fresh()
    L.configure(SD)
    L.note_item("Spyro 3: Buzz's Dungeon Key")
    settle(L)
    assert(L.status():match("^spyro3 enabled=true keys=1/4"), "got " .. L.status())
    assert(sunny.props.EnableTransport == false and sunny.visible() == "LOCKED")
    assert(cloud.props.EnableTransport == false and cloud.visible() == "LOCKED")
end)

test("unprefixed key names do not unlock", function()
    local L, sunny = fresh()
    L.configure(SD)
    L.note_item("Sunny Villa Key")
    settle(L)
    assert(sunny.props.EnableTransport == false and sunny.visible() == "LOCKED")
end)

test("waits for the item backlog, then the grace period", function()
    local L, sunny = fresh()
    L.configure(SD)
    settle(L)
    assert(sunny.props.EnableTransport == true, "locked before backlog/grace")
    now = now + 3
    ticks(L, 1)
    assert(sunny.props.EnableTransport == false, "grace expiry should lock")
end)

test("locked portal: no transport, no preview, LOCKED visible", function()
    local L, sunny, cloud, buzz, islands, gardens = fresh()
    L.configure(SD)
    L.note_item("Spyro 3: Buzz's Dungeon Key")
    settle(L)
    assert(sunny.props.EnableTransport == false and sunny.props.PreloadEnabled == false)
    assert(sunny.text() == "LOCKED" and sunny.visible() == "LOCKED" and sunny.remakes == 1,
        "got text=" .. sunny.text() .. " visible=" .. sunny.visible())
    assert(buzz.props.EnableTransport == true and buzz.remakes == 0, "held key stays open")
    assert(islands.props.EnableTransport == true and islands.remakes == 0, "level without a key untouched")
    assert(cloud.props.EnableTransport == false and cloud.visible() == "LOCKED")
    assert(gardens.props.EnableTransport == true and gardens.remakes == 0,
        "a portal targeting a homeworld is never locked (TARGET_HOMES)")
end)

test("several locks queue one game-thread job at a time", function()
    local L, sunny, cloud = fresh()
    L.configure(SD)
    L.note_item("Spyro 3: Buzz's Dungeon Key")
    ticks(L, 7)
    for _ = 1, 5 do L.tick(gs) end -- async polls while the game thread is busy
    assert(#queue == 1, "expected 1 queued job, got " .. #queue)
    assert(sunny.props.EnableTransport == true and cloud.props.EnableTransport == true,
        "nothing may be written before the game thread runs the job")
    pump()
    local locked = (sunny.props.EnableTransport == false and 1 or 0) + (cloud.props.EnableTransport == false and 1 or 0)
    assert(locked == 1, "one job locks exactly one portal")
    ticks(L, 1)
    assert(sunny.props.EnableTransport == false and cloud.props.EnableTransport == false, "next poll locks the other")
    assert(sunny.visible() == "LOCKED" and cloud.visible() == "LOCKED")
end)

test("TARGET_HOMES: a portal targeting Midday Gardens never locks without its key", function()
    local L = fresh()
    level = "/LS328_MidnightMountain_Home/Maps/"
    world.portals = {
        new_portal("LS329", "Crystal Islands"),
        new_portal("LS310", "Midday Gardens"),
    }
    L.configure(spyro3_sd({ level_locks = 1 }, {
        ["Crystal Islands"] = "Spyro 3: Crystal Islands Key",
        ["Midday Gardens"] = "Spyro 3: Midday Gardens Key",
    }))
    now = now + 3 -- past the connect grace period (no backlog items in this test)
    settle(L)
    assert(world.portals[1].props.EnableTransport == false and world.portals[1].visible() == "LOCKED",
        "a realm portal with an unheld key must lock")
    assert(world.portals[2].props.EnableTransport == true and world.portals[2].remakes == 0,
        "the homeworld-target portal must stay open while its key is not held")
end)

test("game re-enable is re-locked and LOCKED re-revealed without a rebuild", function()
    local L, sunny = fresh()
    L.configure(SD)
    L.note_item("Spyro 3: Buzz's Dungeon Key")
    settle(L)
    as_game(function() sunny.actor:setPortalEnabled(true) end) -- exit-from-portal sequence finishing
    ticks(L, 1)
    assert(sunny.props.EnableTransport == false and sunny.remakes == 1)
    assert(sunny.visible() == "LOCKED", "got visible=" .. sunny.visible())
end)

test("receiving the key unlocks and restores the visible name", function()
    local L, sunny, cloud = fresh()
    L.configure(SD)
    L.note_item("Spyro 3: Buzz's Dungeon Key")
    settle(L)
    L.note_item("Spyro 3: Sunny Villa Key")
    ticks(L, 1)
    assert(sunny.props.EnableTransport == true and sunny.props.PreloadEnabled == true)
    assert(sunny.text() == "Sunny Villa" and sunny.visible() == "SunnyVilla" and sunny.remakes == 2,
        "got text=" .. sunny.text() .. " visible=" .. sunny.visible())
    assert(cloud.props.EnableTransport == false, "a key for one portal does not unlock the other")
    ticks(L, 5)
    assert(sunny.remakes == 2, "no further rebuilds once unlocked")
end)

test("a job that never runs is abandoned after the timeout", function()
    local L = fresh()
    L.configure(SD)
    L.note_item("Spyro 3: Buzz's Dungeon Key")
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
    local L, sunny = fresh()
    L.configure(SD)
    L.note_item("Spyro 3: Buzz's Dungeon Key")
    settle(L)
    assert(sunny.props.EnableTransport == true and sunny.remakes == 0)
    assert(L.status():match("^spyro3 enabled=false"))
end)

test("no writes outside homeworlds or before the level settles", function()
    local L, sunny = fresh()
    L.configure(SD)
    L.note_item("Spyro 3: Buzz's Dungeon Key")
    ticks(L, 5)
    assert(sunny.props.EnableTransport == true, "wrote before the stable-level gate")
    level = "/LS302_SunnyVilla/Maps/"
    settle(L)
    assert(sunny.props.EnableTransport == true and sunny.remakes == 0, "wrote in a non-homeworld level")
end)

test("reconfigure for a new seed forgets old keys", function()
    local L, sunny = fresh()
    L.configure(SD)
    L.note_item("Spyro 3: Sunny Villa Key")
    settle(L)
    assert(sunny.props.EnableTransport == true)
    L.configure(SD)
    L.note_item("Spyro 3: Buzz's Dungeon Key")
    ticks(L, 1)
    assert(sunny.props.EnableTransport == false and sunny.visible() == "LOCKED")
end)

test("status reports held keys and locked portals", function()
    local L = fresh()
    L.configure(SD)
    L.note_item("Spyro 3: Buzz's Dungeon Key")
    settle(L)
    local s = L.status()
    assert(s == "spyro3 enabled=true keys=1/4 locked_here=2", "got " .. s)
end)

print(string.format("%d/%d passed", tests - failed, tests))
os.exit(failed == 0 and 0 or 1)