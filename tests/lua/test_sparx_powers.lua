-- Author: Tim Harrison
-- Created: 2026-09-26
-- Updated: 2026-10-21

-- Stub-based spec for client/ue4ss_mod/srt_bridge/Scripts/spyro3/sparx_powers.lua
-- (and, through it, inventory_grants_core.lua). Fakes the gamestate's
-- inventory UFunctions (add/remove/get player inventory item count for EIT
-- types 45-48). ExecuteInGameThread only QUEUES work; H.pump() runs it with the
-- game-thread flag set, and every write asserts that flag (level_locks
-- hardlock lesson). EIT_SparxPower_GemFinder (46) must never be touched.
-- Run from the client repo root: lua tests/lua/test_sparx_powers.lua

package.path = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "support/?.lua;" .. package.path
local H = require("harness")

H.install_game_thread()
local fstring = H.fstring

-- fake gamestate: an owned flag per Sparx power type (0/1/garbage), calls
local EIT_RANGE, EIT_FINDER, EIT_HP, EIT_CHESTS = 45, 46, 47, 48
local world = { powers = {}, calls = {}, nil_types = {} }

local function record(fn, ...)
    world.calls[#world.calls + 1] = { fn = fn, args = {...}, thread = H.thread }
end

local level = "/LS301_SunriseSpring_Home/Maps/"
local gs = setmetatable({}, { __index = function(_, k)
    if k == "current level" then return fstring(level) end
    if k == "add item to player inventory" then return function(eit, n)
        assert(H.thread, "power granted off the game thread")
        record("add", eit, n)
        world.powers[eit] = 1
    end end
    if k == "remove from player inventory" then return function(eit, n)
        assert(H.thread, "power revoked off the game thread")
        record("remove", eit, n)
        if world.remove_fails then error("remove boom") end
        world.powers[eit] = 0
    end end
    if k == "get player inventory item count" then return function(eit, cur, out)
        record("get", eit, cur)
        if world.nil_types[eit] then return end
        local v = world.powers[eit]
        if v == nil then v = 0 end
        out["item count"] = v
    end end
end })

local REGIONS = {
    ["/LS301_SunriseSpring_Home/Maps/"] = "Sunrise Spring",
    ["/LS302_SunnyVilla/Maps/"] = "Sunny Villa",
}
local function sd(val)
    return {
        included_games = { "spyro1", "spyro3" }, required_games = { "spyro1" },
        games = { spyro3 = { options = { sparx_powers = val } } },
    }
end
local ON_SD, OFF_SD = sd(1), sd(0)
local RANGE = "Spyro 3: Sparx Gem Collect Range"
local HP = "Spyro 3: Sparx Extra Hit Point"
local CHESTS = "Spyro 3: Sparx Chest Breaking"

-- ---------------------------------------------------------------------------
-- harness
-- ---------------------------------------------------------------------------
local function fresh()
    H.new_fixture(REGIONS)
    package.loaded["spyro3.sparx_powers"] = nil
    package.loaded["inventory_grants_core"] = nil
    H.clear_queue()
    world.powers, world.calls, world.nil_types = {}, {}, {}
    world.remove_fails = false
    local S = require("spyro3.sparx_powers")
    H.clear_log()
    S.init({ log = H.collect, regions = REGIONS })
    level = "/LS301_SunriseSpring_Home/Maps/"
    return S
end
local function ticks(S, n) for _ = 1, n do H.tick(S, gs); H.pump() end end
local function settle(S) ticks(S, 12) end
local function calls_of(fn) return H.calls_of(world.calls, fn) end
local function touched_finder()
    for _, c in ipairs(world.calls) do
        if c.args[1] == EIT_FINDER then return true end
    end
    return false
end
local function count_lines(...)
    local needles, n = {...}, 0
    for _, l in ipairs(H.lines) do
        local all = true
        for _, s in ipairs(needles) do
            if not l:find(s, 1, true) then all = false end
        end
        if all then n = n + 1 end
    end
    return n
end

local test = H.test

test("option off never calls the game, even when owned and unreceived", function()
    local S = fresh()
    S.configure(OFF_SD)
    world.powers[EIT_HP] = 1
    S.note_item(HP, 0)
    settle(S)
    assert(#world.calls == 0, "option off must not touch the gamestate")
end)

test("missing option (or no spyro3 slot data) does nothing", function()
    local S = fresh()
    S.configure({ games = { spyro2 = { options = {} } } })
    world.powers[EIT_HP] = 1
    settle(S)
    S.configure(nil)
    settle(S)
    assert(#world.calls == 0, "missing option must not touch the gamestate")
    assert(S.status():find("powers=false", 1, true), "got " .. S.status())
end)

test("received power lands on the game thread once the level settles", function()
    local S = fresh()
    S.configure(ON_SD)
    S.note_item(RANGE, 0)
    ticks(S, 5)
    assert(#calls_of("add") == 0, "granted before the stable-level gate")
    settle(S)
    assert(world.powers[EIT_RANGE] == 1, "gem collect range not set")
    local adds = calls_of("add")
    assert(#adds == 1 and adds[1].args[1] == EIT_RANGE and adds[1].args[2] == 1,
        "expected one add(45, 1)")
    assert(count_lines("[SPARX]", RANGE, "0 -> 1 (received)") == 1, "grant not logged")
    settle(S)
    assert(#calls_of("add") == 1, "granted twice (write storm)")
end)

test("vanilla realm reward without the item is revoked; WARN logs once", function()
    local S = fresh()
    S.configure(ON_SD)
    world.powers[EIT_CHESTS] = 1
    settle(S)
    assert(world.powers[EIT_CHESTS] == 0, "realm reward not revoked")
    local removes = calls_of("remove")
    assert(#removes == 1 and removes[1].args[1] == EIT_CHESTS, "expected one remove(48, 1)")
    assert(count_lines("[SPARX] WARN", CHESTS, "Sparx realm") == 1, "expected exactly 1 WARN")
    assert(count_lines("[SPARX]", CHESTS, "1 -> 0 (not received; vanilla realm reward neutralized)") == 1,
        "revoke not logged")
    world.powers[EIT_CHESTS] = 1
    settle(S)
    assert(#calls_of("remove") == 2, "re-granted reward not revoked again")
    assert(count_lines("[SPARX] WARN", CHESTS) == 1, "WARN logged again")
end)

test("a failed revoke is not retried this session; configure re-arms it", function()
    local S = fresh()
    S.configure(ON_SD)
    world.powers[EIT_CHESTS] = 1
    world.remove_fails = true
    settle(S)
    assert(#calls_of("remove") == 1, "expected one revoke attempt, got " .. #calls_of("remove"))
    assert(count_lines("[SPARX] ERROR revoke failed for", CHESTS, "won't retry this session") == 1,
        "revoke failure not logged")
    for _ = 1, 3 do H.advance(10); settle(S) end
    level = "/LS302_SunnyVilla/Maps/"
    settle(S)
    assert(#calls_of("remove") == 1, "failed revoke resubmitted: " .. #calls_of("remove") .. " removes")
    assert(count_lines("[SPARX] ERROR") == 1, "ERROR repeated after the failed revoke")
    S.note_item(HP, 0)
    H.advance(10)
    settle(S)
    assert(world.powers[EIT_HP] == 1, "other items' grants must still land")
    world.remove_fails = false
    S.configure(ON_SD)
    settle(S)
    assert(world.powers[EIT_CHESTS] == 0 and #calls_of("remove") >= 2, "configure did not re-arm the revoke")
end)

test("EIT_SparxPower_GemFinder (46) is never touched", function()
    local S = fresh()
    S.configure(ON_SD)
    world.powers[EIT_FINDER] = 1
    S.note_item(HP, 0)
    settle(S)
    world.powers[EIT_RANGE] = 1
    settle(S)
    level = "/LS302_SunnyVilla/Maps/"
    world.powers[EIT_HP] = 0
    settle(S)
    assert(not touched_finder(), "GemFinder (46) was read or written")
    assert(world.powers[EIT_FINDER] == 1, "GemFinder flag changed")
    assert(#calls_of("add") == 2 and #calls_of("remove") == 1)
end)

test("duplicate item indexes count once; foreign items ignored", function()
    local S = fresh()
    S.configure(ON_SD)
    S.note_item(HP, 4)
    S.note_item(HP, 4)
    S.note_item("Spyro 2: Swim Ability", 5)
    S.note_item("Spyro 3: Sparx Gem Finder", 6)
    assert(count_lines("received (index") == 1, "expected one receive log")
    settle(S)
    local adds = calls_of("add")
    assert(#adds == 1 and adds[1].args[1] == EIT_HP, "expected one add(47, 1)")
end)

test("garbage readback writes nothing", function()
    local S = fresh()
    S.configure(ON_SD)
    S.note_item(HP, 0)
    world.powers[EIT_HP] = 5
    settle(S)
    assert(#calls_of("add") == 0, "wrote on a garbage readback")
    world.powers[EIT_HP] = nil
    world.nil_types[EIT_HP] = true
    settle(S)
    assert(#calls_of("add") == 0, "wrote on a nil readback")
end)

test("writes wait for a stable known level", function()
    local S = fresh()
    S.configure(ON_SD)
    S.note_item(HP, 0)
    level = "/Game/Maps/LoadScreen"
    settle(S)
    assert(#calls_of("add") == 0, "wrote on a load screen")
    level = "/LS301_SunriseSpring_Home/Maps/"
    ticks(S, 5)
    assert(#calls_of("add") == 0, "wrote before 8 stable ticks")
    ticks(S, 7)
    assert(world.powers[EIT_HP] == 1, "no grant after stabilizing")
end)

test("level change re-asserts the drive", function()
    local S = fresh()
    S.configure(ON_SD)
    S.note_item(HP, 0)
    settle(S)
    assert(world.powers[EIT_HP] == 1)
    level = "/LS302_SunnyVilla/Maps/"
    world.powers[EIT_HP] = 0
    settle(S)
    assert(world.powers[EIT_HP] == 1, "level change did not re-assert the grant")
    assert(#calls_of("add") == 2, "re-assert wrote nothing")
end)

test("configure resets received state", function()
    local S = fresh()
    S.configure(ON_SD)
    S.note_item(HP, 0)
    settle(S)
    assert(world.powers[EIT_HP] == 1)
    S.configure(ON_SD)
    assert(S.status():find("ExtraHP=-", 1, true), "received set survived configure")
    settle(S)
    assert(world.powers[EIT_HP] == 0, "stale receive kept the power after reconfigure")
    S.note_item(HP, 0)
    settle(S)
    assert(world.powers[EIT_HP] == 1, "index 0 not accepted again after configure")
end)

test("no game-thread API: logs once, never writes", function()
    ExecuteInGameThread = nil
    local S = fresh()
    assert(count_lines("[SPARX] ERROR ExecuteInGameThread unavailable") == 1)
    S.configure(ON_SD)
    S.note_item(HP, 0)
    settle(S)
    assert(#world.calls == 0, "touched the gamestate without a game-thread API")
end)

test("status() format", function()
    local S = fresh()
    S.configure(ON_SD)
    assert(S.status() == "ChestBreaking=- ExtraHP=- GemCollectRange=- powers=true", "got " .. S.status())
    S.note_item(HP, 0)
    assert(S.status() == "ChestBreaking=- ExtraHP=recv GemCollectRange=- powers=true", "got " .. S.status())
    assert(count_lines("[SPARX] configured: powers=true") == 1)
end)

H.finish()
