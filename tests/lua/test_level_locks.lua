-- Stub-based spec for client/ue4ss_mod/srt_bridge/Scripts/spyro1/level_locks.lua.
-- Fakes the UE4SS surfaces the module touches (FindAllOf, portal actors, the
-- PortalNameComponent glyph actors, ExecuteInGameThread) with the behaviour
-- observed live (docs/game_state_control.md §9.5.1):
--   setPortalEnabled(en): EnableTransport = PreloadEnabled = en; glyphs hidden = not en
--   REMAKE text: display text = text; old glyphs destroyed, new ones spawn hidden
-- ExecuteInGameThread only QUEUES work; pump() runs it with the game-thread
-- flag set. Every write asserts that flag: a write from the async tick is the
-- 2026-09-13 hardlock.
-- Run from the client repo root: lua tests/lua/test_level_locks.lua

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
            if P.explode then error("portal boom") end
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

local level = "/LS101_ArtisansHome/Maps/"
local gs = setmetatable({}, { __index = function(_, k)
    if k == "current level" then return fstring(level) end
end })

local regions = {
    ["/LS101_ArtisansHome/Maps/"] = "Artisans",
    ["/LS102_StoneHill/Maps/"] = "Stone Hill",
    ["/LS103_DarkHollow/Maps/"] = "Dark Hollow",
    ["/LS105_Sunnyflight/Maps/"] = "Sunny Flight",
}
local KEYS = { ["Stone Hill"] = "Spyro 1: Stone Hill Key", ["Dark Hollow"] = "Spyro 1: Dark Hollow Key" }
local function spyro1_sd(options, level_keys)
    return {
        included_games = { "spyro1" },
        required_games = { "spyro1" },
        options = { death_link = 0 },
        games = { spyro1 = { options = options, level_keys = level_keys } },
        seed = "S1", slot = "P1",
    }
end
local SD = spyro1_sd({ level_locks = 1 }, KEYS)

-- ---------------------------------------------------------------------------
-- harness
-- ---------------------------------------------------------------------------
local lines = {}
local function fresh()
    package.loaded["spyro1.level_locks"] = nil
    queue = {}
    local L = require("spyro1.level_locks")
    lines = {}
    L.init({ log = function(l) lines[#lines + 1] = l end, regions = regions })
    level = "/LS101_ArtisansHome/Maps/"
    world.portals = {
        new_portal("LS102", "Stone Hill"),
        new_portal("LS103", "Dark Hollow"),
        new_portal("LS105", "Sunny Flight"),
    }
    return L, world.portals[1], world.portals[2], world.portals[3]
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
    local L, sh = fresh()
    L.configure(spyro1_sd({ level_locks = 0 }, {}))
    L.note_item("Spyro 1: Dragon")
    settle(L)
    assert(sh.props.EnableTransport == true and sh.remakes == 0 and #queue == 0)
end)

test("old top-level slot data shape does not enable locks", function()
    local L, sh = fresh()
    L.configure({ options = { level_locks = 1 }, level_keys = KEYS })
    L.note_item("Spyro 1: Dragon")
    settle(L)
    assert(sh.props.EnableTransport == true and sh.remakes == 0 and #queue == 0)
    assert(L.status() == "enabled=false keys=0/0 locked_here=0", "got " .. L.status())
end)

test("games.spyro1 slot data shape enables locks", function()
    local L, sh = fresh()
    L.configure(SD)
    L.note_item("Spyro 1: Dragon")
    settle(L)
    assert(L.status():match("^enabled=true keys=0/2"), "got " .. L.status())
    assert(sh.props.EnableTransport == false and sh.visible() == "LOCKED")
end)

test("unprefixed key names do not unlock", function()
    local L, sh = fresh()
    L.configure(SD)
    L.note_item("Dark Hollow Key")
    settle(L)
    assert(sh.props.EnableTransport == false and sh.visible() == "LOCKED")
end)

test("waits for the item backlog, then the grace period", function()
    local L, sh = fresh()
    L.configure(SD)
    settle(L)
    assert(sh.props.EnableTransport == true, "locked before backlog/grace")
    now = now + 3
    ticks(L, 1)
    assert(sh.props.EnableTransport == false, "grace expiry should lock")
end)

test("locked portal: no transport, no preview, LOCKED visible", function()
    local L, sh, dh, sf = fresh()
    L.configure(SD)
    L.note_item("Spyro 1: Dark Hollow Key")
    settle(L)
    assert(sh.props.EnableTransport == false and sh.props.PreloadEnabled == false)
    assert(sh.text() == "LOCKED" and sh.visible() == "LOCKED" and sh.remakes == 1,
        "got text=" .. sh.text() .. " visible=" .. sh.visible())
    assert(dh.props.EnableTransport == true and dh.remakes == 0, "held key stays open")
    assert(sf.props.EnableTransport == true and sf.remakes == 0, "level without a key untouched")
end)

test("several locks queue one game-thread job at a time", function()
    local L, sh, dh = fresh()
    L.configure(SD)
    L.note_item("Spyro 1: Dragon")
    ticks(L, 7)
    for _ = 1, 5 do L.tick(gs) end -- async polls while the game thread is busy
    assert(#queue == 1, "expected 1 queued job, got " .. #queue)
    assert(sh.props.EnableTransport == true and dh.props.EnableTransport == true,
        "nothing may be written before the game thread runs the job")
    pump()
    local locked = (sh.props.EnableTransport == false and 1 or 0) + (dh.props.EnableTransport == false and 1 or 0)
    assert(locked == 1, "one job locks exactly one portal")
    ticks(L, 1)
    assert(sh.props.EnableTransport == false and dh.props.EnableTransport == false, "next poll locks the other")
    assert(sh.visible() == "LOCKED" and dh.visible() == "LOCKED")
end)

test("game re-enable is re-locked and LOCKED re-revealed without a rebuild", function()
    local L, sh = fresh()
    L.configure(SD)
    L.note_item("Spyro 1: Dark Hollow Key")
    settle(L)
    as_game(function() sh.actor:setPortalEnabled(true) end) -- exit-from-portal sequence finishing
    ticks(L, 1)
    assert(sh.props.EnableTransport == false and sh.remakes == 1)
    assert(sh.visible() == "LOCKED", "got visible=" .. sh.visible())
end)

test("a portal disabled by the game before the job runs is left alone", function()
    local L, sh = fresh()
    L.configure(SD)
    L.note_item("Spyro 1: Dark Hollow Key")
    ticks(L, 8)
    L.tick(gs) -- decides to lock, queues the job
    assert(#queue == 1, "expected the lock job to be queued")
    as_game(function() sh.actor:setPortalEnabled(false) end) -- enter transition started
    pump()
    assert(sh.remakes == 0, "must not relabel a portal mid-transition")
end)

test("receiving the key unlocks and restores the visible name", function()
    local L, sh = fresh()
    L.configure(SD)
    L.note_item("Spyro 1: Dark Hollow Key")
    settle(L)
    L.note_item("Spyro 1: Stone Hill Key")
    ticks(L, 1)
    assert(sh.props.EnableTransport == true and sh.props.PreloadEnabled == true)
    assert(sh.text() == "Stone Hill" and sh.visible() == "StoneHill" and sh.remakes == 2,
        "got text=" .. sh.text() .. " visible=" .. sh.visible())
    ticks(L, 5)
    assert(sh.remakes == 2, "no further rebuilds once unlocked")
end)

test("a job that never runs is abandoned after the timeout", function()
    local L = fresh()
    L.configure(SD)
    L.note_item("Spyro 1: Dragon")
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

test("a failing job backs off instead of resubmitting every tick", function()
    local L, sh = fresh()
    L.configure(SD)
    L.note_item("Spyro 1: Dark Hollow Key")
    sh.explode = true
    settle(L)
    ticks(L, 8)
    local function errors()
        local n = 0
        for _, l in ipairs(lines) do if l:find("ERROR lock Stone Hill: ", 1, true) then n = n + 1 end end
        return n
    end
    assert(errors() == 1, "expected 1 ERROR inside the backoff, got " .. errors())
    now = now + 4
    ticks(L, 4)
    assert(errors() == 1, "resubmitted inside the backoff")
    now = now + 1
    ticks(L, 1)
    assert(errors() == 2, "expected one retry after the backoff, got " .. errors())
    sh.explode = false
    now = now + 5
    ticks(L, 1)
    assert(sh.props.EnableTransport == false and sh.visible() == "LOCKED", "lock never landed")
end)

test("no game-thread API means no writes at all", function()
    ExecuteInGameThread = nil
    local L, sh = fresh()
    L.configure(SD)
    L.note_item("Spyro 1: Dragon")
    settle(L)
    assert(sh.props.EnableTransport == true and sh.remakes == 0)
    assert(L.status():match("^enabled=false"))
end)

test("no writes outside homeworlds or before the level settles", function()
    local L, sh = fresh()
    L.configure(SD)
    L.note_item("Spyro 1: Dark Hollow Key")
    ticks(L, 5)
    assert(sh.props.EnableTransport == true, "wrote before the stable-level gate")
    level = "/LS102_StoneHill/Maps/"
    settle(L)
    assert(sh.props.EnableTransport == true and sh.remakes == 0, "wrote in a non-homeworld level")
end)

test("reconfigure for a new seed forgets old keys", function()
    local L, sh = fresh()
    L.configure(SD)
    L.note_item("Spyro 1: Stone Hill Key")
    settle(L)
    assert(sh.props.EnableTransport == true)
    L.configure(SD)
    L.note_item("Spyro 1: Dark Hollow Key")
    ticks(L, 1)
    assert(sh.props.EnableTransport == false and sh.visible() == "LOCKED")
end)

test("status reports held keys and locked portals", function()
    local L = fresh()
    L.configure(SD)
    L.note_item("Spyro 1: Dark Hollow Key")
    settle(L)
    local s = L.status()
    assert(s == "enabled=true keys=1/2 locked_here=1", "got " .. s)
end)

print(string.format("%d/%d passed", tests - failed, tests))
os.exit(failed == 0 and 0 or 1)
