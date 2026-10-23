-- Author: Tim Harrison
-- Created: 2026-09-26
-- Updated: 2026-10-21

-- Stub-based spec for client/ue4ss_mod/srt_bridge/Scripts/spyro2/abilities.lua.
-- Fakes the gamestate's ability inventory UFunctions (add/remove/get player
-- inventory item count for EIT types 30-33). ExecuteInGameThread only QUEUES
-- work; H.pump() runs it with the game-thread flag set, and every write asserts
-- that flag (level_locks hardlock lesson).
-- Run from the client repo root: lua tests/lua/test_abilities.lua

package.path = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "support/?.lua;" .. package.path
local H = require("harness")

H.install_game_thread()
local fstring = H.fstring

-- fake gamestate: an owned flag per EIT type (0/1/garbage), recorded calls
local EIT_CLIMBING, EIT_HEADBASH, EIT_SWIMMING, EIT_SUPERFLAME = 30, 31, 32, 33
local world = { abilities = {}, calls = {}, level = nil, nil_types = {} }
local wrapped_readback = false

local function record(fn, ...)
    world.calls[#world.calls + 1] = { fn = fn, args = {...}, thread = H.thread }
    return nil
end

local level = "/LS201_SummerForest_Home/Maps/"
local gs = setmetatable({}, { __index = function(_, k)
    if k == "current level" then return fstring(level) end
    if k == "add item to player inventory" then return function(eit, n)
        assert(H.thread, "ability granted off the game thread")
        record("add", eit, n)
        assert(eit ~= EIT_SUPERFLAME, "grant for forbidden type 33")
        world.abilities[eit] = 1
    end end
    if k == "remove from player inventory" then return function(eit, n)
        assert(H.thread, "ability revoked off the game thread")
        record("remove", eit, n)
        assert(eit ~= EIT_SUPERFLAME, "revoke for forbidden type 33")
        if world.remove_fails then error("remove boom") end
        world.abilities[eit] = 0
    end end
    if k == "get player inventory item count" then return function(eit, cur, out)
        record("get", eit, cur)
        if world.nil_types[eit] then return end
        local v = world.abilities[eit]
        if v == nil then v = 0 end
        if wrapped_readback and v ~= nil then
            out["item count"] = { value = v }
        else
            out["item count"] = v
        end
    end end
end })

local REGIONS = {
    ["/LS201_SummerForest_Home/Maps/"] = "Summer Forest",
    ["/LS210_AutumnPlains_Home/Maps/"] = "Autumn Plains",
    ["/LS222_WinterTundra_Home/Maps/"] = "Winter Tundra",
}
local SANITY_SD = {
    included_games = { "spyro1", "spyro2" }, required_games = { "spyro1" },
    games = { spyro2 = { options = { moneybags_abilities = 1 } } },
}
local VANILLA_SD = {
    included_games = { "spyro1", "spyro2" }, required_games = { "spyro1" },
    games = { spyro2 = { options = { moneybags_abilities = 0 } } },
}
local SWIM = "Spyro 2: Swim Ability"
local CLIMB = "Spyro 2: Climb Ability"
local HEADBASH = "Spyro 2: Headbash Ability"

-- ---------------------------------------------------------------------------
-- harness
-- ---------------------------------------------------------------------------
local function fresh(keep_state)
    H.new_fixture(REGIONS)
    package.loaded["spyro2.abilities"] = nil
    H.clear_queue()
    if not keep_state then
        world.abilities = {}
        world.calls = {}
        world.nil_types = {}
        world.remove_fails = false
        wrapped_readback = false
    end
    local A = require("spyro2.abilities")
    H.clear_log()
    A.init({ log = H.collect, regions = REGIONS })
    level = "/LS201_SummerForest_Home/Maps/"
    return A
end
local function ticks(A, n) for _ = 1, n do H.tick(A, gs); H.pump() end end
local function settle(A) ticks(A, 12) end
local function calls_of(fn) return H.calls_of(world.calls, fn) end
local function wrote_superflame()
    for _, c in ipairs(world.calls) do
        if c.fn == "add" or c.fn == "remove" then
            if c.args[1] == EIT_SUPERFLAME then return true end
        end
    end
    return false
end

local test = H.test

test("vanilla mode never writes, even when owned and unreceived", function()
    local A = fresh()
    A.configure(VANILLA_SD)
    world.abilities[EIT_SWIMMING] = 1
    settle(A)
    assert(#calls_of("add") == 0 and #calls_of("remove") == 0,
        "vanilla mode must not touch ability flags")
end)

test("received ability lands on the game thread once the level settles", function()
    local A = fresh()
    A.configure(SANITY_SD)
    A.note_item(SWIM, 0)
    ticks(A, 5)
    assert(#calls_of("add") == 0, "granted before the stable-level gate")
    settle(A)
    assert(world.abilities[EIT_SWIMMING] == 1, "swim flag not set")
    assert(#calls_of("add") == 1 and calls_of("add")[1].args[1] == EIT_SWIMMING,
        "expected one add(32, 1)")
    settle(A)
    assert(#calls_of("add") == 1, "granted twice (write storm)")
end)

test("vanilla purchase without the item is revoked; WARN logs once", function()
    local A = fresh()
    A.configure(SANITY_SD)
    world.abilities[EIT_SWIMMING] = 1
    settle(A)
    assert(world.abilities[EIT_SWIMMING] == 0, "purchase not revoked")
    assert(#calls_of("remove") == 1 and calls_of("remove")[1].args[1] == EIT_SWIMMING,
        "expected one remove(32, 1)")
    local warns = 0
    for _, l in ipairs(H.lines) do
        if l:find("WARN", 1, true) and l:find("Swim", 1, true) then warns = warns + 1 end
    end
    assert(warns == 1, "expected exactly 1 early-pay WARN, got " .. warns)
    settle(A)
    assert(#calls_of("remove") == 1, "revoked twice")
    warns = 0
    for _, l in ipairs(H.lines) do
        if l:find("WARN", 1, true) and l:find("Swim", 1, true) then warns = warns + 1 end
    end
    assert(warns == 1, "WARN logged again after the revoke")
end)

test("a failed revoke is not retried this session; the item still lands", function()
    local A = fresh()
    A.configure(SANITY_SD)
    world.abilities[EIT_SWIMMING] = 1
    world.remove_fails = true
    settle(A)
    local errs = 0
    for _, l in ipairs(H.lines) do
        if l:find("ERROR revoke failed for " .. SWIM, 1, true) and l:find("won't retry this session", 1, true) then
            errs = errs + 1
        end
    end
    assert(errs == 1, "expected one revoke-failed ERROR, got " .. errs)
    for _ = 1, 3 do H.advance(10); settle(A) end
    assert(#calls_of("remove") == 1, "failed revoke resubmitted: " .. #calls_of("remove") .. " removes")
    for _, l in ipairs(H.lines) do
        assert(not l:find("write failed", 1, true), "failed revoke retried as a write: " .. l)
    end
    world.abilities[EIT_SWIMMING] = 0
    A.note_item(SWIM, 0)
    H.advance(10)
    settle(A)
    assert(world.abilities[EIT_SWIMMING] == 1, "received item blocked by the failed revoke")
end)

test("garbage readback writes nothing", function()
    local A = fresh()
    A.configure(SANITY_SD)
    A.note_item(SWIM, 0)
    world.abilities[EIT_SWIMMING] = 5
    settle(A)
    assert(#calls_of("add") == 0, "wrote on a garbage readback")
    world.abilities[EIT_SWIMMING] = nil
    world.nil_types[EIT_SWIMMING] = true
    settle(A)
    assert(#calls_of("add") == 0, "wrote on a nil readback")
end)

test("table-wrapped out-params are unwrapped", function()
    local A = fresh()
    A.configure(SANITY_SD)
    wrapped_readback = true
    world.abilities[EIT_SWIMMING] = 0
    A.note_item(SWIM, 0)
    settle(A)
    assert(world.abilities[EIT_SWIMMING] == 1, "grant missed through wrapped readback")
end)

test("level change re-asserts the drive", function()
    local A = fresh()
    A.configure(SANITY_SD)
    A.note_item(SWIM, 0)
    settle(A)
    assert(world.abilities[EIT_SWIMMING] == 1)
    -- the game re-restores state at world transitions: flag forced back off,
    -- module must re-apply it after the new level stabilizes
    level = "/LS210_AutumnPlains_Home/Maps/"
    world.abilities[EIT_SWIMMING] = 0
    settle(A)
    assert(world.abilities[EIT_SWIMMING] == 1,
        "level change did not re-assert the grant")
    local adds = calls_of("add")
    assert(#adds >= 2, "re-assert wrote nothing")
end)

test("writes wait for a stable known level", function()
    local A = fresh()
    A.configure(SANITY_SD)
    A.note_item(SWIM, 0)
    level = "/Game/Maps/LoadScreen"
    settle(A)
    assert(#calls_of("add") == 0, "wrote on a load screen")
    level = "/LS201_SummerForest_Home/Maps/"
    ticks(A, 5)
    assert(#calls_of("add") == 0, "wrote before 8 stable ticks")
    ticks(A, 7)
    assert(world.abilities[EIT_SWIMMING] == 1, "no grant after stabilizing")
end)

test("EIT_Superflame is never touched", function()
    local A = fresh()
    A.configure(SANITY_SD)
    A.note_item(SWIM, 0)
    world.abilities[EIT_SUPERFLAME] = 1
    settle(A)
    assert(not wrote_superflame(), "Superflame (33) was written")
    local adds = calls_of("add")
    assert(#adds == 1 and adds[1].args[1] == EIT_SWIMMING)
    -- a revoke pass (vanilla purchase without the item) must also skip 33
    world.abilities[EIT_HEADBASH] = 1
    settle(A)
    assert(not wrote_superflame(), "Superflame (33) was written on revoke pass")
    local removes = calls_of("remove")
    assert(#removes == 1 and removes[1].args[1] == EIT_HEADBASH)
end)

test("duplicate item indexes count once", function()
    local A = fresh()
    A.configure(SANITY_SD)
    A.note_item(SWIM, 4)
    A.note_item(SWIM, 4)
    settle(A)
    assert(#calls_of("add") == 1, "duplicate index granted twice")
end)

test("status() is a string naming the abilities", function()
    local A = fresh()
    A.configure(SANITY_SD)
    local s = A.status()
    assert(type(s) == "string" and s:find("Swim", 1, true) and s:find("Climb", 1, true)
        and s:find("Headbash", 1, true), "got " .. s)
end)

H.finish()