-- Author: Tim Harrison
-- Created: 2026-09-26
-- Updated: 2026-11-10

-- Stub-based spec for client/ue4ss_mod/srt_bridge/Scripts/fillers.lua.
-- Fakes the gamestate's inventory UFunction and the Spyro pawn's own visual
-- path (mesh material slot 0, dynamic material instances, anim flag, mesh
-- scale) — the state the module now applies and verifies. ExecuteInGameThread
-- only QUEUES work; H.pump() runs it with the game-thread flag set, and every
-- write asserts that flag (level_locks hardlock lesson).
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

-- the game's own assets: slot 0 starts on the body material, the tint base is
-- the greyscale one the module builds its MID from
local BODY = {
    IsValid = function() return true end,
    GetAddress = function() return 900 end,
    GetFullName = function() return "MaterialInstanceConstant MI_CPS1999_Spyro_Body.MI_CPS1999_Spyro_Body" end,
}
local GREY = {
    IsValid = function() return true end,
    GetAddress = function() return 901 end,
    GetFullName = function() return "MaterialInstanceConstant MI_CPS1999_Spyro_Greyscale.MI_CPS1999_Spyro_Greyscale" end,
}
local GREYSCALE_PATH = "/Game/CPS1999_Spyro/Materials/MI_CPS1999_Spyro_Greyscale.MI_CPS1999_Spyro_Greyscale"

-- the UE4SS asset lookup: only the full greyscale path resolves (the module
-- tries four candidates and keeps the first that hits). The KismetStringLibrary
-- stand-in turns a parameter name into a real FName, never a Lua string.
local FNAME_LIB = {
    IsValid = function() return true end,
    GetAddress = function() return 902 end,
    Conv_StringToName = function(_, s)
        return {IsValid = function() return true end, name = s}
    end,
    GetFullName = function() return "Class Default__KismetStringLibrary" end,
}
local found = { greyscale = GREY, calls = 0 }
local BODY_PATH = "/CPS1999_Spyro/Materials/MI_CPS1999_Spyro_Body.MI_CPS1999_Spyro_Body"
StaticFindObject = function(path)
    found.calls = found.calls + 1
    if path == GREYSCALE_PATH then return found.greyscale end
    if path == BODY_PATH then return BODY end
    if path == "/Script/Engine.Default__KismetStringLibrary" then return FNAME_LIB end
    return nil
end

--- Return the CheatTints index of an FLinearColor value, or nil.
--- @return number|nil
local function index_of(value)
    for i, t in ipairs(TINTS) do
        if value and value.R == t[1] and value.G == t[2] and value.B == t[3] then return i - 1 end
    end
    return nil
end

local next_addr = 100
local function new_pawn(opts)
    next_addr = next_addr + 1
    local P = { addr = next_addr, tint = nil, modes = {}, cheat_tints = 0 }
    local raw = {}
    for i, t in ipairs(TINTS) do raw[i] = { R = t[1], G = t[2], B = t[3], A = 1 } end
    P.tints = raw
    local tints = { ForEach = function(_, cb)
        for i, c in ipairs(raw) do cb(i, { get = function() return c end }) end
    end }

    -- the anim instance: the game's big head lives in the anim graph's flag
    local anim = { CheatBigHeadEnabled = false, notified = nil }
    anim.GetFullName = function() return "AnimBlueprintGeneratedClass ABP_CPS1999_C.ABP_CPS1999_C" end
    anim.INotifyCheatBigHead = function(_, on)
        assert(H.thread, "INotifyCheatBigHead off the game thread")
        anim.notified = on
        P.modes.ICheatCodeBigHeadMode = on
        -- the game's big-head enable rebuilds the mesh material, dropping a tint
        if on then P.mesh.material0, P.tint = BODY, 0 end
    end

    -- the pawn's skeletal mesh component
    local mesh = {
        material0 = BODY,
        scale = { X = 1, Y = 1, Z = 1 },
        mid_count = 0,
        mids = {},
        sets = {},
        anim = anim,
        skeletal = "SkeletalMesh SK_CPS1999_Spyro.SK_CPS1999_Spyro",
    }
    if opts and opts.skin then mesh.skeletal = opts.skin end
    mesh.SkeletalMesh = { GetFullName = function() return mesh.skeletal end }
    mesh.IsValid = function() return true end
    mesh.GetMaterial = function(_, slot)
        assert(slot == 0, "unexpected material slot " .. tostring(slot))
        return mesh.material0
    end
    mesh.SetMaterial = function(_, slot, mat)
        assert(H.thread, "SetMaterial off the game thread")
        assert(slot == 0, "unexpected material slot " .. tostring(slot))
        mesh.sets[#mesh.sets + 1] = mat
        if mesh.refuse then return end        -- the game keeps its own material on slot 0
        mesh.material0 = mat
        P.tint = mat.color_index or 0
    end
    mesh.CreateDynamicMaterialInstance = function(_, slot, base)
        assert(H.thread, "MID created off the game thread")
        assert(slot == 0, "unexpected material slot " .. tostring(slot))
        if opts and opts.null_mid then
            -- UE4SS constructs a null-object userdata for a failed create; a
            -- method call on it faults natively, so it must be validity-checked
            return { IsValid = function() return false end }
        end
        mesh.mid_count = mesh.mid_count + 1
        local mid = {
            base = base,
            addr = 2000 + mesh.mid_count,
            IsValid = function() return true end,
            GetAddress = function() return 2000 + mesh.mid_count end,
            GetFullName = function() return "MaterialInstanceDynamic MID_CPS1999_Spyro" end,
        }
        mid.SetVectorParameterValue = function(_, name, value)
            assert(H.thread, "SetVectorParameterValue off the game thread")
            mid.param, mid.value = name, value
            mid.color_index = index_of(value)
        end
        mesh.mids[#mesh.mids + 1] = mid
        return mid
    end
    mesh.GetAnimInstance = function() return mesh.anim end
    mesh.SetWorldScale3D = function(_, v)
        assert(H.thread, "SetWorldScale3D off the game thread")
        mesh.scale = { X = v.X, Y = v.Y, Z = v.Z }
        P.modes.ICheatCodeFlatSpyroMode = v.X < 1
    end
    mesh.GetComponentScale = function() return mesh.scale end
    mesh.K2_GetComponentScale = function() return mesh.scale end
    P.mesh = mesh

    P.health = nil
    if not (opts and opts.no_health) then
        P.health = A.health_set(H, P)
        P.hp = 3
    end
    P.actor = setmetatable({}, { __index = function(_, k)
        if k == "IsValid" then return function() return true end end
        if k == "GetAddress" then return function() return P.addr end end
        if k == "Mesh" then return P.mesh end
        if k == "CheatTints" then
            if opts and opts.no_tints then return nil end
            return tints
        end
        if k == "GetOuter" then return function()
            assert(H.thread, "GetOuter off the game thread")
            return P.health_outer or P.actor
        end end
        -- the game's own Big Head handler: it notifies the anim BP and writes
        -- the code.bighead global (the lever the shipped mod always used)
        -- the game's handler exists, but the mod must not need it (its gates
        -- skipped the apply in the field); count calls so a regression shows
        if k == "ICheatCodeBigHeadMode" then return function(_, on)
            P.handler_bighead_calls = (P.handler_bighead_calls or 0) + 1
            world.floats["code.bighead"] = on and 1 or 0
        end end
        -- the game's own tint handler: the degraded path when no MID can be built
        if k == "ICheatCodeSetSpyroTintColor" then return function()
            assert(H.thread, "tint applied off the game thread")
            P.cheat_tints = P.cheat_tints + 1
            P.tint = world.floats["code.color"]
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
local session_game = 0 -- the open session's game index (SESSION.SPYRO1 default)

local function fresh(keep_state)
    H.new_fixture(regions)
    session_game = 0
    package.loaded["fillers"] = nil
    package.loaded["srtap_state"] = nil -- a fresh process: no cached file contents
    H.clear_queue()
    if not keep_state then
        os.remove(DIR .. "srtap_S1_P1.txt")
        os.remove(DIR .. "srtap_S2_P1.txt")
        world.lives = 0
        world.floats = {}
        world.health = nil
    end
    found.greyscale, found.calls = GREY, 0
    A.install(world) -- restore the actor lookups a test may have replaced
    local F = require("fillers")
    H.clear_log()
    F.init({ log = H.collect, regions = regions, dir = DIR,
             game = function() return session_game end })
    level = "/LS102_StoneHill/Maps/"
    world.pawn = new_pawn()
    return F
end
local function ticks(F, n) for _ = 1, n do H.tick(F, gs); H.pump() end end
local function settle(F) ticks(F, 12) end

--- Grant a red tint and settle: it must have landed on the pawn's slot 0.
--- @return table The module under test.
local function red_applied()
    local F = fresh()
    F.configure(SD)
    F.note_item("Turn Spyro Red", 0)
    settle(F)
    assert(world.pawn.mesh.material0.color_index == 1,
        "color not applied: " .. tostring(world.pawn.mesh.material0.GetFullName()))
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

test("a reconnect backlog replays no color or mode", function()
    local F = fresh()
    F.configure(SD)
    F.note_item("Turn Spyro Red", 0)
    F.note_item("Big Head Mode", 1)
    settle(F)
    assert(world.pawn.mesh.material0.color_index == 1, "setup: colour not applied")
    H.advance(31)
    ticks(F, 1)
    assert(world.pawn.mesh.material0 == BODY, "setup: colour did not expire")
    -- AP re-delivers the whole history on every connect with the same indexes
    F = fresh(true)
    F.configure(SD)
    F.note_item("Turn Spyro Red", 0)
    F.note_item("Big Head Mode", 1)
    settle(F)
    assert(world.pawn.mesh.material0 == BODY, "a replayed colour was re-applied")
    assert(world.pawn.mesh.anim.CheatBigHeadEnabled == false, "a replayed mode was re-applied")
    assert(H.queued() == 0, "queued work for a replayed backlog")
end)

test("an item newer than the replayed backlog still applies", function()
    local F = fresh()
    F.configure(SD)
    F.note_item("Turn Spyro Red", 0)
    settle(F)
    H.advance(31)
    ticks(F, 1)
    F = fresh(true)
    F.configure(SD)
    F.note_item("Turn Spyro Red", 0)
    settle(F)
    F.note_item("Turn Spyro Green", 1)
    ticks(F, 1)
    assert(world.pawn.mesh.material0.color_index == 5,
        "new item after a replay did not apply: " .. tostring(world.pawn.mesh.material0.color_index))
end)

test("the look follows the pawn the player controller is driving", function()
    local F = fresh()
    F.configure(SD)
    local P = world.pawn
    -- a parked Spyro from another world is what a bare class lookup can find;
    -- the controller names the one actually being played
    local parked = new_pawn()
    local restore = FindFirstOf
    FindFirstOf = function(cls)
        if cls == "BP_Controller_Player_C" then
            return { IsValid = function() return true end,
                     CurrentControlledPawn = P.actor }
        end
        if cls == "BP_CPS1999_Playable_C" then return parked.actor end
        return nil
    end
    F.note_item("Turn Spyro Red", 0)
    settle(F)
    assert(P.mesh.material0.color_index == 1, "the live pawn was not tinted")
    assert(parked.mesh.material0 == BODY, "the parked pawn was tinted instead")
    FindFirstOf = restore
end)

test("a revert restores the vanilla body material, never a captured pointer", function()
    local F = red_applied()
    local P = world.pawn
    -- the game had its own MID in slot 0 when we tinted; once replaced it is
    -- unreferenced and the GC may free it, so it must never be restored
    local game_mid = { IsValid = function() return false end,
                       GetFullName = function() return "MaterialInstanceDynamic game_tint" end }
    P.mesh.mids[1].IsValid = function() return false end -- also drop ours
    H.advance(31)
    P.mesh.material0 = game_mid
    ticks(F, 1)
    assert(P.mesh.material0 == BODY, "revert did not restore the body material")
    assert(P.mesh.sets[#P.mesh.sets] == BODY, "restored something other than the body material")
end)

test("a grant writes the shared state file and keeps the banner's key", function()
    local F = fresh()
    local S = require("srtap_state")
    S.open(SD, DIR)
    S.set("seen_upto", 40) -- the hud_banner module's key in the same file
    S.flush()
    F.configure(SD)
    F.note_item("Extra Life", 0)
    settle(F)
    local text = H.read_file(DIR .. "srtap_S1_P1.txt")
    assert(text:find("lives_granted=1", 1, true), text)
    assert(text:find("seen_upto=40", 1, true), text)
    -- a later process reloads the count from the same file
    S.open({ seed = "S9", slot = "P9" }, DIR) -- a different slot drops the cache
    F.configure(SD)
    assert(F.status():find("lives granted=1", 1, true), F.status())
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

test("a granted color reaches slot 0 through a MID with its CheatTints entry", function()
    local F = red_applied()
    local P = world.pawn
    assert(P.mesh.mid_count == 1, "MIDs created: " .. P.mesh.mid_count)
    local mid = P.mesh.mids[1]
    assert(mid.base == GREY, "MID built from " .. tostring(mid.base and mid.base.GetFullName()))
    assert(mid.param ~= nil and mid.param.name == "Tint Color", "vector parameter: " .. tostring(mid.param and mid.param.name))
    assert(mid.value ~= P.tints[2] and mid.value.R == P.tints[2].R and mid.value.G == P.tints[2].G,
        "the CheatTints colour must be marshalled as a plain FLinearColor table")
    assert(P.mesh.material0 == mid, "slot 0 is not our MID")
    assert(world.floats["code.color"] == 1, "code.color: " .. tostring(world.floats["code.color"]))
    assert(H.logged("Turn Spyro Red -> CheatTints[1] (0.90,0.10,0.10) applied (material verified)", true),
        table.concat(H.lines, " | "))
end)

test("a global that says applied while slot 0 is not our MID re-applies", function()
    local F = red_applied()
    local P = world.pawn
    -- the old failure mode: code.color says the tint is on, the mesh is vanilla
    P.mesh.material0, P.tint = BODY, 0
    assert(world.floats["code.color"] == 1)
    ticks(F, 1)
    -- the game dropped our MID from slot 0, so a fresh one is built from the base
    local mid = P.mesh.material0
    assert(mid ~= nil and mid.base == GREY, "colour not re-applied on the pawn")
    assert(mid.color_index == 1, "tint " .. tostring(mid.color_index))
end)

test("the game replacing slot 0 mid-level is re-asserted on the next tick", function()
    local F = red_applied()
    local P = world.pawn
    -- the game writes its own material back into slot 0 (its own tint, a skin,
    -- a cutscene rebuild): same pawn, look dropped
    P.mesh.material0 = { GetFullName = function() return "MaterialInstanceDynamic game_tint" end }
    ticks(F, 1)
    assert(P.mesh.material0.base == GREY, "slot 0 not re-asserted")
    assert(P.mesh.material0.color_index == 1, "tint " .. tostring(P.mesh.material0.color_index))
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
    assert(world.pawn.mesh.mid_count == 1, "a later colour change rebuilt the MID")
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
    assert(warns == 1, "expected one warn before the retry backs off, got " .. warns)
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
    assert(world.pawn.mesh.mid_count == 1, "an active tint was rebuilt: " .. world.pawn.mesh.mid_count)
end)

test("a color after a revert builds a fresh MID; the reverted one may be collected", function()
    local F = red_applied()
    local P = world.pawn
    local first = P.mesh.mids[1]
    H.advance(31)
    ticks(F, 1)
    assert(P.mesh.material0 == BODY, "colour did not revert")
    -- the game's GC frees an unreferenced MID: touching it would fault natively
    first.IsValid = function() return false end
    first.SetVectorParameterValue = function() P.mesh.touched_collected = true end
    first.SetMaterial = function() P.mesh.touched_collected = true end
    F.note_item("Turn Spyro Green", 2)
    ticks(F, 1)
    assert(not P.mesh.touched_collected, "called into the collected MID")
    assert(P.mesh.mid_count == 2, "reused the reverted MID (MIDs built: " .. P.mesh.mid_count .. ")")
    assert(P.mesh.material0 == P.mesh.mids[2], "slot 0 is not the fresh MID")
    assert(P.mesh.material0.color_index == 5, "fresh MID colour: " .. tostring(P.mesh.material0.color_index))
end)

test("a null MID degrades to the cheat handler instead of calling a method on it", function()
    local F = fresh()
    F.configure(SD)
    world.pawn = new_pawn({ null_mid = true })
    F.note_item("Turn Spyro Red", 0)
    settle(F)
    local warned = false
    for _, l in ipairs(H.lines) do
        if l:find("CreateDynamicMaterialInstance unavailable", 1, true) then warned = true end
    end
    assert(warned, "no WARN: " .. table.concat(H.lines, " | "))
    assert(world.pawn.cheat_tints > 0, "cheat handler not used")
    assert(world.floats["code.color"] == 1, "code.color: " .. tostring(world.floats["code.color"]))
end)

test("big head works through the flag+notify when the anim flag is unreadable", function()
    local F = fresh()
    F.configure(SD)
    -- a live UE4SS build can read the write back as nil even though it landed;
    -- that must not turn into a WARN loop or a handler fallback
    local real = world.pawn.mesh.anim
    world.pawn.mesh.GetAnimInstance = function()
        return setmetatable({}, {
            __index = function(_, k)
                if k == "CheatBigHeadEnabled" then return nil end
                return real[k]
            end,
            __newindex = function(_, k, v)
                if k ~= "CheatBigHeadEnabled" then real[k] = v end
            end,
        })
    end
    F.note_item("Big Head Mode", 0)
    settle(F)
    assert(world.pawn.modes.ICheatCodeBigHeadMode == true, "the notify did not run")
    assert(world.pawn.handler_bighead_calls == nil, "used the gated pawn handler")
    assert(H.count_logged("flag not readable", true) == 1, table.concat(H.lines, " | "))
    assert(H.count_logged("did not stick", true) == 0, "false failure on a working apply")
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

test("big head sets the anim flag and calls the notify on and off", function()
    local F = fresh()
    F.configure(SD)
    F.note_item("Big Head Mode", 0)
    settle(F)
    local anim = world.pawn.mesh.anim
    assert(anim.CheatBigHeadEnabled == true, "anim flag not set")
    assert(anim.notified == true, "INotifyCheatBigHead(true) not called")
    assert(world.floats["code.bighead"] == 1, "code.bighead: " .. tostring(world.floats["code.bighead"]))
    assert(H.logged("BigHeadMode on (anim flag verified)", true), table.concat(H.lines, " | "))
    H.advance(31)
    ticks(F, 1)
    assert(anim.CheatBigHeadEnabled == false, "anim flag not cleared")
    assert(anim.notified == false, "INotifyCheatBigHead(false) not called")
    assert(world.floats["code.bighead"] == 0, "code.bighead: " .. tostring(world.floats["code.bighead"]))
    assert(H.logged("BigHeadMode off (anim flag verified)", true), table.concat(H.lines, " | "))
end)

test("flat spyro squashes the mesh scale and restores it on expiry", function()
    local F = fresh()
    F.configure(SD)
    F.note_item("Flat Spyro Mode", 0)
    settle(F)
    local scale = world.pawn.mesh.scale
    assert(scale.X == 0.2 and scale.Y == 1 and scale.Z == 1,
        string.format("scale %.2f,%.2f,%.2f", scale.X, scale.Y, scale.Z))
    assert(H.logged("flat spyro on (mesh scale verified)", true), table.concat(H.lines, " | "))
    H.advance(31)
    ticks(F, 1)
    scale = world.pawn.mesh.scale
    assert(scale.X == 1 and scale.Y == 1 and scale.Z == 1,
        string.format("scale %.2f,%.2f,%.2f", scale.X, scale.Y, scale.Z))
    assert(H.logged("flat spyro off (mesh scale verified)", true), table.concat(H.lines, " | "))
end)

test("a skinned Spyro is left untinted with one WARN and no MID", function()
    local F = fresh()
    F.configure(SD)
    world.pawn = new_pawn({ skin = "SkeletalMesh SK_CPS1999_Spyro_Legendary.SK_CPS1999_Spyro_Legendary" })
    F.note_item("Turn Spyro Red", 0)
    settle(F)
    assert(world.pawn.mesh.mid_count == 0, "created a MID for a skinned pawn")
    assert(world.pawn.mesh.material0 == BODY, "touched a skinned pawn's material")
    assert(world.pawn.tint == nil, "tinted a skinned pawn")
    assert(H.count_logged("tint skipped: skin active", true) == 1,
        "skin WARNs: " .. H.count_logged("tint skipped: skin active", true))
end)

test("missing greyscale falls back to the cheat handler and stops retrying the MID path", function()
    local F = fresh()
    F.configure(SD)
    found.greyscale = nil
    F.note_item("Turn Spyro Red", 0)
    settle(F)
    assert(world.pawn.tint == 1, "fallback tint: " .. tostring(world.pawn.tint))
    assert(world.pawn.mesh.mid_count == 0, "built a MID without a base material")
    assert(world.pawn.cheat_tints == 1, "cheat handler calls: " .. world.pawn.cheat_tints)
    assert(H.count_logged("greyscale material not found", true) == 1,
        "WARNs: " .. H.count_logged("greyscale material not found", true))
    local lookups = found.calls
    settle(F)
    assert(world.pawn.cheat_tints == 1, "retried the fallback on a settled pawn")
    assert(found.calls == lookups, "retried the asset lookup for the same pawn")
end)

test("a look write that does not stick backs off instead of hot-looping", function()
    local F = red_applied()
    local P = world.pawn
    -- the game keeps its own material on slot 0, so the write never verifies
    P.mesh.refuse = true
    P.mesh.material0, P.tint = BODY, 0
    local before = #P.mesh.sets
    H.clear_log()
    ticks(F, 1)
    assert(H.count_logged("did not stick", true) == 1, table.concat(H.lines, " | "))
    assert(#P.mesh.sets == before + 1, "set attempts: " .. #P.mesh.sets)
    for _ = 1, 4 do H.tick(F, gs) end
    assert(H.queued() == 0, "resubmitted during the backoff")
    assert(H.count_logged("did not stick", true) == 1, "warned once per tick")
    H.advance(3)
    H.tick(F, gs)
    assert(H.queued() == 1, "no retry after the backoff expired")
    H.pump()
    assert(#P.mesh.sets == before + 2, "retried: " .. #P.mesh.sets)
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
    assert(world.pawn.mesh.material0 == BODY, "pre-tint material not restored")
    assert(world.floats["code.color"] == 0, "code.color not reset")
    assert(H.logged("color reverted to default (verified)", true), table.concat(H.lines, " | "))
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
    -- the game wipes the tint mid-level (death/respawn/cutscene): slot 0 back to
    -- the body material and code.color back to 0, same pawn
    world.pawn.mesh.material0, world.pawn.tint = BODY, 0
    world.floats["code.color"] = 0
    ticks(F, 1)
    assert(world.floats["code.color"] == 1, "code.color not re-asserted: " .. tostring(world.floats["code.color"]))
    assert(world.pawn.mesh.material0.base == GREY and world.pawn.mesh.material0.color_index == 1,
        "color not re-applied on the same pawn")
end)

test("a mode the game dropped is re-asserted on the next tick", function()
    local F = fresh()
    F.configure(SD)
    F.note_item("Big Head Mode", 0)
    settle(F)
    assert(world.pawn.modes.ICheatCodeBigHeadMode == true)
    -- the game resets the cheat mid-level (same pawn): the anim flag drops
    world.pawn.mesh.anim.CheatBigHeadEnabled = false
    world.pawn.modes.ICheatCodeBigHeadMode = false
    world.floats["code.bighead"] = 0
    ticks(F, 1)
    assert(world.pawn.mesh.anim.CheatBigHeadEnabled == true, "big head not re-asserted")
end)

test("a mode grant never clobbers a color granted in the same job", function()
    local F = fresh()
    F.configure(SD)
    F.note_item("Turn Spyro Black", 0)
    F.note_item("Big Head Mode", 1)
    settle(F)
    -- the mode handler drops the mesh material on enable; the tint is written last
    assert(world.floats["code.color"] == 6, "mode clobbered the color: " .. tostring(world.floats["code.color"]))
    assert(world.pawn.mesh.material0.color_index == 6, "tint lost to a mode: " .. tostring(world.pawn.tint))
end)

test("a later mode grant re-asserts an active tint in the same job", function()
    local F = red_applied()
    local P = world.pawn
    F.note_item("Big Head Mode", 1)
    ticks(F, 1)
    -- the notify rebuilds the material on enable, so the job must tint last
    assert(P.mesh.material0.base == GREY, "tint dropped by the mode grant")
    assert(P.mesh.material0.color_index == 1, "wrong tint after the mode grant")
    assert(P.modes.ICheatCodeBigHeadMode == true, "big head not applied")
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

os.remove(DIR .. "srtap_S1_P1.txt")
os.remove(DIR .. "srtap_S2_P1.txt")
H.finish()
