-- Author: Tim Harrison
-- Created: 2026-09-26
-- Updated: 2026-10-23

-- Stub-based spec for client/ue4ss_mod/srt_bridge/Scripts/fillers.lua.
-- Fakes the gamestate's inventory UFunction and the Spyro pawn's cheat-code
-- handlers. ExecuteInGameThread only QUEUES work; H.pump() runs it with the
-- game-thread flag set, and every write asserts that flag (level_locks
-- hardlock lesson).
-- Run from the client repo root: lua tests/lua/test_fillers.lua

package.path = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "support/?.lua;" .. package.path
local H = require("harness")
local A = require("actors")

H.install_game_thread()
local fstring = H.fstring

-- ---------------------------------------------------------------------------
-- fake gamestate + pawn
-- ---------------------------------------------------------------------------
local world = { lives = 0, pawn = nil, health = nil }
local level = "/LS102_StoneHill/Maps/"
local gs = setmetatable({}, { __index = function(_, k)
    if k == "current level" then return fstring(level) end
    if k == "enabledCheat" then return fstring("") end
    if k == "add item to player inventory" then return function(item, n)
        assert(H.thread, "lives granted off the game thread")
        assert(item == 18, "expected EIT_Life")
        world.lives = math.min(99, world.lives + n)
    end end
    if k == "SetGlobalFloatValue" then return function(_, key, v)
        assert(H.thread, "global float set off the game thread")
        world.floats[key] = v
        return true
    end end
    -- game signature: GetGlobalFloatValue(FString Key, float& Value)
    if k == "GetGlobalFloatValue" then return function(_, key, out)
        out.Value = world.floats[key] or 0
        return true
    end end
end })

-- default purple first, like a real tint table would plausibly start
local TINTS = { {0.5, 0.2, 0.8}, {0.9, 0.1, 0.1}, {0.1, 0.2, 0.9}, {1, 0.5, 0.7},
                {1, 0.9, 0.1}, {0.1, 0.8, 0.2}, {0.05, 0.05, 0.05} }

local next_addr = 100
local function new_pawn(opts)
    next_addr = next_addr + 1
    local P = { addr = next_addr, tint = nil, modes = {} }
    local tints = { ForEach = function(_, cb)
        for i, t in ipairs(TINTS) do
            cb(i, { get = function() return { R = t[1], G = t[2], B = t[3], A = 1 } end })
        end
    end }
    P.health = nil
    if not (opts and opts.no_health) then
        P.health = A.health_set(H, P)
        P.hp = 3
    end
    P.actor = setmetatable({}, { __index = function(_, k)
        if k == "IsValid" then return function() return true end end
        if k == "GetAddress" then return function() return P.addr end end
        if k == "CheatTints" then
            if opts and opts.no_tints then return nil end
            return tints
        end
        if k == "GetOuter" then return function()
            assert(H.thread, "GetOuter off the game thread")
            return P.health_outer or P.actor
        end end
        -- the game's tint routine reads the gamestate's code.color global float
        if k == "ICheatCodeSetSpyroTintColor" then return function()
            assert(H.thread, "tint applied off the game thread")
            P.tint = world.floats["code.color"]
        end end
        if k == "ICheatCodeBigHeadMode" or k == "ICheatCodeFlatSpyroMode" then return function(_, on)
            assert(H.thread, k .. " called off the game thread")
            P.modes[k] = on
            -- the game mirrors the cheat in its own global float
            world.floats[k == "ICheatCodeBigHeadMode" and "code.bighead" or "code.flat"] = on and 1 or 0
            -- and, on enable, rebuilds the mesh material, dropping any tint
            if on then P.tint, world.floats["code.color"] = nil, 0 end
        end end
    end })
    return P
end
local enemy_set = A.enemy_set
A.install(world)

--- Report whether a trap WARN about the missing health set was logged.
--- @return boolean
local function warned_no_health()
    for _, l in ipairs(H.lines) do
        if l:find("health attribute set not found", 1, true) then return true end
    end
    return false
end

local regions = {
    ["/LS101_ArtisansHome/Maps/"] = "Artisans",
    ["/LS102_StoneHill/Maps/"] = "Stone Hill",
}
local SD = {
    included_games = { "spyro1" }, required_games = { "spyro1" },
    options = { death_link = 0 }, games = { spyro1 = { options = {}, level_keys = {} } },
    seed = "S1", slot = "P1",
}
local DIR = os.tmpname()
os.remove(DIR)
DIR = DIR .. "-"

-- ---------------------------------------------------------------------------
-- harness
-- ---------------------------------------------------------------------------
local function fresh(keep_state)
    H.new_fixture(regions)
    package.loaded["fillers"] = nil
    H.clear_queue()
    if not keep_state then
        os.remove(DIR .. "fillers_S1_P1.txt")
        os.remove(DIR .. "fillers_S2_P1.txt")
        world.lives = 0
        world.floats = {}
        world.health = nil
    end
    local F = require("fillers")
    H.clear_log()
    F.init({ log = H.collect, regions = regions, dir = DIR })
    level = "/LS102_StoneHill/Maps/"
    world.pawn = new_pawn()
    return F
end
local function ticks(F, n) for _ = 1, n do H.tick(F, gs); H.pump() end end
local function settle(F) ticks(F, 12) end

--- Grant a red tint and settle: it must have landed on the pawn.
--- @return table The module under test.
local function red_applied()
    local F = fresh()
    F.configure(SD)
    F.note_item("Turn Spyro Red", 0)
    settle(F)
    assert(world.pawn.tint == 1, "color not applied: " .. tostring(world.pawn.tint))
    return F
end

local test = H.test

test("extra lives land on the game thread once the level settles", function()
    local F = fresh()
    F.configure(SD)
    for i = 0, 2 do F.note_item("Extra Life", i) end
    ticks(F, 5)
    assert(world.lives == 0, "granted before the stable-level gate")
    settle(F)
    assert(world.lives == 3, "got " .. world.lives)
    settle(F)
    assert(world.lives == 3, "granted twice")
end)

test("reconnect backlog does not re-grant, even after a game restart", function()
    local F = fresh()
    F.configure(SD)
    F.note_item("Extra Life", 0)
    F.note_item("Extra Life", 1)
    settle(F)
    assert(world.lives == 2)
    F = fresh(true)
    F.configure(SD)
    F.note_item("Extra Life", 0)
    F.note_item("Extra Life", 1)
    settle(F)
    assert(world.lives == 2, "backlog re-granted: " .. world.lives)
    F.note_item("Extra Life", 7)
    ticks(F, 1)
    assert(world.lives == 3, "new life after reconnect: " .. world.lives)
end)

test("a duplicate index in one session counts once", function()
    local F = fresh()
    F.configure(SD)
    F.note_item("Extra Life", 4)
    F.note_item("Extra Life", 4)
    settle(F)
    assert(world.lives == 1, "got " .. world.lives)
end)

test("a different seed keeps its own life count", function()
    local F = fresh()
    F.configure(SD)
    F.note_item("Extra Life", 0)
    settle(F)
    F.configure({ games = { spyro1 = {} }, seed = "S2", slot = "P1" })
    F.note_item("Extra Life", 0)
    ticks(F, 1)
    assert(world.lives == 2, "got " .. world.lives)
end)

test("no writes on the load screen", function()
    local F = fresh()
    F.configure(SD)
    F.note_item("Extra Life", 0)
    F.note_item("Turn Spyro Red", 1)
    level = "/Game/Maps/Loading"
    settle(F)
    assert(world.lives == 0 and world.pawn.tint == nil and H.queued() == 0)
end)

test("color picks the nearest CheatTints entry; latest color wins", function()
    local F = fresh()
    F.configure(SD)
    F.note_item("Turn Spyro Red", 0)
    F.note_item("Turn Spyro Blue", 1)
    settle(F)
    assert(world.pawn.tint == 2, "got tint " .. tostring(world.pawn.tint))
    F.note_item("Turn Spyro Black", 2)
    ticks(F, 1)
    assert(world.pawn.tint == 6, "got tint " .. tostring(world.pawn.tint))
end)

test("unreadable CheatTints retries against the same pawn instead of giving up until reload", function()
    local F = fresh()
    F.configure(SD)
    world.pawn = new_pawn({ no_tints = true })
    F.note_item("Turn Spyro Red", 0)
    settle(F)
    local warns = 0
    for _, l in ipairs(H.lines) do
        if l:find("CheatTints unreadable", 1, true) then warns = warns + 1 end
    end
    assert(warns == 1, "expected one warn before the job backs off, got " .. warns)
    H.advance(6)
    ticks(F, 1)
    warns = 0
    for _, l in ipairs(H.lines) do
        if l:find("CheatTints unreadable", 1, true) then warns = warns + 1 end
    end
    assert(warns == 2, "expected a retry against the same pawn after backoff, got " .. warns)
end)

test("a second color change on the same pawn applies without a new pawn", function()
    local F = fresh()
    F.configure(SD)
    F.note_item("Turn Spyro Black", 0)
    F.note_item("Big Head Mode", 1)
    settle(F)
    assert(world.pawn.tint == 6, "first color: " .. tostring(world.pawn.tint))
    assert(world.pawn.modes.ICheatCodeBigHeadMode == true, "big head not applied")
    F.note_item("Turn Spyro Green", 2)
    ticks(F, 1)
    assert(world.pawn.tint == 5, "second color did not apply live: " .. tostring(world.pawn.tint))
    assert(world.pawn.modes.ICheatCodeBigHeadMode == true, "big head mode was lost on an unrelated color change")
end)

test("Big Head / Flat Spyro wear off on their own after MODE_DURATION", function()
    local F = fresh()
    F.configure(SD)
    F.note_item("Big Head Mode", 0)
    F.note_item("Flat Spyro Mode", 1)
    settle(F)
    assert(world.pawn.modes.ICheatCodeBigHeadMode == true, "big head not applied")
    assert(world.pawn.modes.ICheatCodeFlatSpyroMode == true, "flat spyro not applied")
    H.advance(31)
    ticks(F, 1)
    assert(world.pawn.modes.ICheatCodeBigHeadMode == false, "big head did not wear off")
    assert(world.pawn.modes.ICheatCodeFlatSpyroMode == false, "flat spyro did not wear off")
    local s = F.status()
    assert(not s:find("BigHeadMode", 1, true) and not s:find("FlatSpyroMode", 1, true),
        "status still reports expired modes: " .. s)
end)

test("a duplicate mode grant restarts its clock instead of stacking", function()
    local F = fresh()
    F.configure(SD)
    F.note_item("Big Head Mode", 0)
    settle(F)
    assert(world.pawn.modes.ICheatCodeBigHeadMode == true)
    H.advance(20)
    F.note_item("Big Head Mode", 1)
    H.advance(20)
    ticks(F, 1)
    -- 40s since the first grant (would have expired), but only 20s since the
    -- second: still on
    assert(world.pawn.modes.ICheatCodeBigHeadMode == true, "duplicate grant did not restart the timer")
end)

test("a color wears off to default after COLOR_DURATION", function()
    local F = red_applied()
    H.advance(31)
    ticks(F, 1)
    assert(world.pawn.tint == 0, "color did not revert: " .. tostring(world.pawn.tint))
    assert(world.floats["code.color"] == 0, "code.color not reset")
    local s = F.status()
    assert(s:find("look=default", 1, true), "status still reports the expired color: " .. s)
end)

test("a duplicate color grant restarts its clock instead of reverting", function()
    local F = fresh()
    F.configure(SD)
    F.note_item("Turn Spyro Red", 0)
    settle(F)
    H.advance(20)
    F.note_item("Turn Spyro Red", 1)
    H.advance(20)
    ticks(F, 1)
    assert(world.pawn.tint == 1, "color reverted despite a fresh grant")
end)

test("a new color mid-window supersedes, then its own timer reverts", function()
    local F = fresh()
    F.configure(SD)
    F.note_item("Turn Spyro Red", 0)
    settle(F)
    assert(world.pawn.tint == 1, "red not applied")
    H.advance(20)
    F.note_item("Turn Spyro Green", 1)
    ticks(F, 1)
    assert(world.pawn.tint == 5, "green did not supersede: " .. tostring(world.pawn.tint))
    -- 40s after red's grant (red's window is over) but only 20s into green's
    H.advance(20)
    ticks(F, 1)
    assert(world.pawn.tint == 5, "green reverted on red's old clock")
    H.advance(11)
    ticks(F, 1)
    assert(world.pawn.tint == 0, "green did not revert on its own clock: " .. tostring(world.pawn.tint))
end)

test("a color the game cleared is re-asserted on the next tick", function()
    local F = red_applied()
    -- the game wipes the tint mid-level (death/respawn/cutscene): code.color
    -- back to 0, same pawn
    world.floats["code.color"] = 0
    world.pawn.tint = nil
    ticks(F, 1)
    assert(world.floats["code.color"] == 1, "code.color not re-asserted: " .. tostring(world.floats["code.color"]))
    assert(world.pawn.tint == 1, "color not re-applied on the same pawn: " .. tostring(world.pawn.tint))
end)

test("a mode the game dropped is re-asserted on the next tick", function()
    local F = fresh()
    F.configure(SD)
    F.note_item("Big Head Mode", 0)
    settle(F)
    assert(world.pawn.modes.ICheatCodeBigHeadMode == true)
    -- the game resets the cheat mid-level (same pawn): its global drops too
    world.pawn.modes.ICheatCodeBigHeadMode = false
    world.floats["code.bighead"] = 0
    ticks(F, 1)
    assert(world.pawn.modes.ICheatCodeBigHeadMode == true, "big head not re-asserted")
end)

test("a mode grant never clobbers a color granted in the same job", function()
    local F = fresh()
    F.configure(SD)
    F.note_item("Turn Spyro Black", 0)
    F.note_item("Big Head Mode", 1)
    settle(F)
    -- whichever order run_job wrote them, code.color must still name the color
    assert(world.floats["code.color"] == 6, "mode clobbered the color: " .. tostring(world.floats["code.color"]))
    assert(world.pawn.tint == 6, "tint lost to a mode: " .. tostring(world.pawn.tint))
end)

test("a new pawn after a color expires does not get the old color", function()
    local F = fresh()
    F.configure(SD)
    F.note_item("Turn Spyro Green", 0)
    settle(F)
    H.advance(31)
    ticks(F, 1)
    level = "/LS101_ArtisansHome/Maps/"
    world.pawn = new_pawn()
    settle(F)
    assert(world.pawn.tint == nil, "expired color leaked to a new pawn: " .. tostring(world.pawn.tint))
end)

test("a new pawn after a level load gets the look re-applied", function()
    local F = fresh()
    F.configure(SD)
    F.note_item("Turn Spyro Green", 0)
    F.note_item("Big Head Mode", 1)
    settle(F)
    assert(world.pawn.tint == 5 and world.pawn.modes.ICheatCodeBigHeadMode == true)
    level = "/LS101_ArtisansHome/Maps/"
    world.pawn = new_pawn()
    settle(F)
    assert(world.pawn.tint == 5, "new pawn color: " .. tostring(world.pawn.tint))
    assert(world.pawn.modes.ICheatCodeBigHeadMode == true, "new pawn lost big head")
    assert(world.pawn.modes.ICheatCodeFlatSpyroMode == nil)
end)

test("the look waits for a pawn; lives do not", function()
    local F = fresh()
    F.configure(SD)
    world.pawn = nil
    F.note_item("Extra Life", 0)
    F.note_item("Flat Spyro Mode", 1)
    settle(F)
    assert(world.lives == 1)
    world.pawn = new_pawn()
    ticks(F, 1)
    assert(world.pawn.modes.ICheatCodeFlatSpyroMode == true)
end)

test("one game-thread job at a time", function()
    local F = fresh()
    F.configure(SD)
    F.note_item("Extra Life", 0)
    F.note_item("Turn Spyro Pink", 1)
    ticks(F, 8)
    for _ = 1, 5 do H.tick(F, gs) end
    assert(H.queued() == 1, "expected 1 queued job, got " .. H.queued())
    assert(world.lives == 0 and world.pawn.tint == nil, "nothing written before the game thread runs")
    H.pump()
    assert(world.lives == 1 and world.pawn.tint == 3)
    for _ = 1, 3 do H.tick(F, gs) end
    assert(H.queued() == 0, "no work left, nothing queued")
end)

test("unrelated items are ignored", function()
    local F = fresh()
    F.configure(SD)
    F.note_item("Spyro 1: Dragon", 0)
    F.note_item("Spyro 1: Stone Hill Key", 1)
    settle(F)
    assert(H.queued() == 0 and world.lives == 0 and world.pawn.tint == nil)
end)

test("damage trap drops health by one hit, once per item", function()
    local F = fresh()
    F.configure(SD)
    world.pawn = new_pawn()
    world.pawn.hp = 3
    F.note_item("Damage Trap", 5)
    ticks(F, 1)
    H.pump()
    assert(world.pawn.hp == 2, "got " .. tostring(world.pawn.hp))
    settle(F)
    assert(world.pawn.hp == 2, "trap re-applied")
    F.note_item("Damage Trap", 6)
    ticks(F, 1)
    H.pump()
    assert(world.pawn.hp == 1, "second trap: " .. tostring(world.pawn.hp))
end)

test("duplicate trap index fires once; health never goes below 0", function()
    local F = fresh()
    F.configure(SD)
    world.pawn = new_pawn()
    world.pawn.hp = 1
    F.note_item("Damage Trap", 9)
    F.note_item("Damage Trap", 9)
    ticks(F, 1)
    H.pump()
    assert(world.pawn.hp == 0)
    F.note_item("Damage Trap", 10)
    ticks(F, 1)
    H.pump()
    assert(world.pawn.hp == 0, "health went below 0")
end)

test("trap without a health set degrades to a WARN no-op", function()
    local F = fresh()
    F.configure(SD)
    world.pawn = new_pawn({ no_health = true })
    F.note_item("Damage Trap", 3)
    ticks(F, 1)
    H.pump()
    assert(warned_no_health(), "no WARN logged: " .. table.concat(H.lines, " | "))
end)

test("trap hits Spyro's set when an enemy's set comes first", function()
    local F = fresh()
    F.configure(SD)
    world.pawn = new_pawn()
    world.pawn.hp = 3
    local e = enemy_set(999)
    world.enemy_sets = { e }
    F.note_item("Damage Trap", 4)
    ticks(F, 1)
    H.pump()
    world.enemy_sets = nil
    assert(world.pawn.hp == 2, "spyro hp " .. tostring(world.pawn.hp))
    assert(e.hp == 5, "enemy set was damaged")
end)

test("trap skipped when no health set in the world belongs to the pawn", function()
    local F = fresh()
    F.configure(SD)
    world.pawn = new_pawn({ no_health = true })
    local e1, e2 = enemy_set(997), enemy_set(998)
    world.enemy_sets = { e1, e2 }
    F.note_item("Damage Trap", 4)
    ticks(F, 1)
    H.pump()
    world.enemy_sets = nil
    assert(warned_no_health(), "no WARN logged: " .. table.concat(H.lines, " | "))
    assert(e1.hp == 5 and e2.hp == 5, "an enemy set was damaged")
end)

test("traps fire on the game thread", function()
    local F = fresh()
    F.configure(SD)
    world.pawn = new_pawn()
    world.pawn.hp = 2
    F.note_item("Damage Trap", 1)
    H.tick(F, gs)
    assert(H.queued() == 1)
    assert(world.pawn.hp == 2, "written before the game thread ran")
    H.pump()
    assert(world.pawn.hp == 1)
end)

test("status reports the trap count", function()
    local F = fresh()
    F.configure(SD)
    world.pawn = new_pawn()
    F.note_item("Damage Trap", 0)
    F.note_item("Damage Trap", 1)
    H.tick(F, gs); H.pump()
    local s = F.status()
    assert(s:find("traps=0", 1, true), "got " .. s)
end)

test("no game-thread API means no writes at all", function()
    ExecuteInGameThread = nil
    local F = fresh()
    F.configure(SD)
    F.note_item("Extra Life", 0)
    settle(F)
    assert(world.lives == 0)
end)

test("status reports lives and look", function()
    local F = fresh()
    F.configure(SD)
    F.note_item("Extra Life", 0)
    F.note_item("Turn Spyro Yellow", 1)
    F.note_item("Big Head Mode", 2)
    settle(F)
    local s = F.status()
    assert(s == "lives granted=1 received=1 look=Turn Spyro Yellow+BigHeadMode traps=0", "got " .. s)
end)

os.remove(DIR .. "fillers_S1_P1.txt")
os.remove(DIR .. "fillers_S2_P1.txt")
H.finish()
