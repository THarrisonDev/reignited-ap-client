-- Author: Tim Harrison
-- Created: 2026-09-26
-- Updated: 2026-10-11

-- Stub-based spec for client/ue4ss_mod/srt_bridge/Scripts/death_link.lua.
-- Fakes the Spyro pawn with a GAS health attribute set behind an Outer chain
-- (IsDead reads hp <= 0, so a HealthCurrent=0 write really kills it) and
-- injects send/now/me. ExecuteInGameThread only QUEUES work; pump() runs it
-- with the game-thread flag set, and every write asserts that flag.
-- Run from the client repo root: lua tests/lua/test_death_link.lua

local here = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./"
package.path = here .. "../../ue4ss_mod/srt_bridge/Scripts/?.lua;" .. package.path

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

local now = 1000
os.time = function() return now end

-- ---------------------------------------------------------------------------
-- fake world + pawn
-- ---------------------------------------------------------------------------
local world = { pawn = nil, enemy_sets = nil }

local next_addr = 100
local function new_pawn(opts)
    next_addr = next_addr + 1
    local P = { addr = next_addr, hp = 3, reject_write = false }
    P.health = nil
    if not (opts and opts.no_health) then
        P.health = setmetatable({}, {
            __index = function(_, k)
                if k == "IsValid" then return function() return true end end
                if k == "GetAddress" then return function() return P.addr + 0x100 end end
                if k == "GetOuter" then return function()
                    assert(game_thread, "GetOuter off the game thread")
                    return P.health_outer or P.actor
                end end
                if k == "HealthCurrent" then return P.hp end
                return nil
            end,
            __newindex = function(_, k, v)
                if k == "HealthCurrent" then
                    assert(game_thread, "HealthCurrent written off the game thread")
                    if P.reject_write then P.hp = 2 return end
                    P.hp = v
                end
            end,
        })
    end
    P.actor = setmetatable({}, { __index = function(_, k)
        if k == "IsValid" then return function() return true end end
        if k == "GetAddress" then return function() return P.addr end end
        if k == "GetOuter" then return function()
            assert(game_thread, "GetOuter off the game thread")
            return P.health_outer or P.actor
        end end
        if k == "IsDead" then return function() return P.hp <= 0 end end
        return nil
    end })
    return P
end
-- an enemy's own health set: Outer chain set -> enemy actor, never the pawn
local function enemy_set(addr)
    local E = { hp = 5 }
    local enemy = setmetatable({}, { __index = function(_, k)
        if k == "IsValid" then return function() return true end end
        if k == "GetAddress" then return function() return addr end end
        if k == "GetOuter" then return function() return nil end end
    end })
    E.set = setmetatable({}, {
        __index = function(_, k)
            if k == "IsValid" then return function() return true end end
            if k == "GetAddress" then return function() return addr + 0x100 end end
            if k == "GetOuter" then return function() return enemy end end
            if k == "HealthCurrent" then return E.hp end
        end,
        __newindex = function(_, k, v) if k == "HealthCurrent" then E.hp = v end end,
    })
    return E
end
-- UE4SS lookups take the short class name: the U-prefixed name, and
-- FindFirstOf for the health-set class at all, answer nil so a regression to
-- either fails the kill specs. FindAllOf lists world.enemy_sets first, then
-- the pawn's; nil when empty, like UE4SS.
function FindFirstOf(cls)
    if cls == "BP_CPS1999_Playable_C" then return world.pawn and world.pawn.actor or nil end
    return nil
end
function FindAllOf(cls)
    if cls ~= "PhasmidHealthSystemAttributeSet" then return nil end
    local all = {}
    for _, e in ipairs(world.enemy_sets or {}) do all[#all + 1] = e.set end
    if world.pawn and world.pawn.health then all[#all + 1] = world.pawn.health end
    if #all == 0 then return nil end
    return all
end

-- ---------------------------------------------------------------------------
-- harness
-- ---------------------------------------------------------------------------
local lines = {}
local sent = {}
local fail_send = false
local server_now = 5000.0
local slot_name = "P1"
local inject = {
    log = function(l) lines[#lines + 1] = l end,
    send = function(data)
        if fail_send then return false end
        sent[#sent + 1] = data
        return true
    end,
    now = function() return server_now end,
    me = function() return slot_name end,
}

local function fresh()
    package.loaded["death_link"] = nil
    queue = {}
    lines, sent, fail_send = {}, {}, false
    server_now = 5000.0
    slot_name = "P1"
    world.pawn = new_pawn()
    ExecuteInGameThread = queue_fn
    local D = require("death_link")
    D.init(inject)
    return D
end

local SD_ON = { options = { death_link = 1 }, seed = "S1", slot = "P1" }
local SD_OFF = { options = { death_link = 0 }, seed = "S1", slot = "P1" }

local function bounce(source, t)
    return { tags = {"DeathLink"}, data = { source = source, time = t, cause = "death" } }
end

local function died_of(...)
    for _, l in ipairs(lines) do
        for _, pat in ipairs({...}) do
            if l:find(pat, 1, true) then return true end
        end
    end
    return false
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
    ExecuteInGameThread = queue_fn
end

local function ticks(D, n) for _ = 1, n or 1 do D.tick({}); pump() end end

test("disabled option: death edge sends nothing, foreign bounce does not kill", function()
    local D = fresh()
    D.configure(SD_OFF)
    D.on_bounced(bounce("Other", server_now + 10))
    world.pawn.hp = 0
    ticks(D, 3)
    assert(#sent == 0, "sent " .. #sent)
    assert(world.pawn.hp == 0, "kill applied while disabled")
    assert(died_of("kill pending") == false)
end)

test("enabled: death edge bounces once; still dead does not resend", function()
    local D = fresh()
    D.configure(SD_ON)
    ticks(D, 1)
    world.pawn.hp = 0
    ticks(D, 1)
    assert(#sent == 1, "sent " .. #sent)
    assert(sent[1].source == "P1" and sent[1].cause == "death", "payload wrong")
    assert(type(sent[1].time) == "number")
    ticks(D, 3)
    assert(#sent == 1, "resent while dead")
end)

test("revive then die again sends a second bounce", function()
    local D = fresh()
    D.configure(SD_ON)
    world.pawn.hp = 0
    ticks(D, 1)
    assert(#sent == 1)
    world.pawn.hp = 3
    ticks(D, 1)
    world.pawn.hp = 0
    ticks(D, 1)
    assert(#sent == 2, "sent " .. #sent)
end)

test("own bounce echo is ignored", function()
    local D = fresh()
    D.configure(SD_ON)
    D.on_bounced(bounce("P1", server_now + 100))
    assert(died_of("echo"), "echo not logged")
    ticks(D, 1)
    assert(world.pawn.hp == 3, "own echo killed us")
end)

test("stale bounce (time <= our last bounce) is ignored", function()
    local D = fresh()
    D.configure(SD_ON)
    world.pawn.hp = 0
    ticks(D, 1)
    assert(#sent == 1)
    world.pawn.hp = 3
    ticks(D, 1)
    D.on_bounced(bounce("Other", sent[1].time))
    D.on_bounced(bounce("Other", sent[1].time - 1))
    ticks(D, 1)
    assert(world.pawn.hp == 3, "stale bounce killed us")
end)

test("foreign bounce kills on the game thread; induced death does not bounce", function()
    local D = fresh()
    D.configure(SD_ON)
    ticks(D, 1)
    D.on_bounced(bounce("Other", server_now + 100))
    assert(died_of("kill pending"), "no pending-kill log")
    D.tick({})
    assert(#queue == 1, "kill not queued")
    assert(world.pawn.hp == 3, "written before the game thread ran")
    pump()
    assert(world.pawn.hp == 0, "hp is " .. tostring(world.pawn.hp))
    ticks(D, 2)
    assert(#sent == 0, "induced death bounced out")
    assert(died_of("suppressed"), "no suppression log")
    assert(died_of("kill applied"), "no kill-applied log")
end)

test("after the induced death, a natural death bounces again", function()
    local D = fresh()
    D.configure(SD_ON)
    D.on_bounced(bounce("Other", server_now + 100))
    ticks(D, 2)
    assert(world.pawn.hp == 0)
    world.pawn.hp = 3
    ticks(D, 1)
    world.pawn.hp = 0
    ticks(D, 1)
    assert(#sent == 1, "sent " .. #sent)
    assert(sent[1].source == "P1")
end)

test("kill write does not stick: WARN, no retry, no bounce", function()
    local D = fresh()
    D.configure(SD_ON)
    world.pawn.reject_write = true
    D.on_bounced(bounce("Other", server_now + 100))
    D.tick({})
    pump()
    assert(died_of("write did not stick"), "no WARN")
    ticks(D, 5)
    assert(#queue == 0, "kill retried")
    assert(#sent == 0, "bounced anyway")
    world.pawn.reject_write = false
    assert(world.pawn.hp == 2, "fake should have rejected the write")
end)

test("no health set: WARN, kill dropped", function()
    local D = fresh()
    D.configure(SD_ON)
    world.pawn = new_pawn({ no_health = true })
    D.on_bounced(bounce("Other", server_now + 100))
    ticks(D, 3)
    assert(died_of("health attribute set not found"), "no WARN")
    assert(#queue == 0, "retried with no health set")
end)

test("kill hits Spyro's set when an enemy's set comes first", function()
    local D = fresh()
    D.configure(SD_ON)
    local e = enemy_set(999)
    world.enemy_sets = { e }
    D.on_bounced(bounce("Other", server_now + 100))
    D.tick({})
    pump()
    world.enemy_sets = nil
    assert(world.pawn.hp == 0, "spyro hp " .. tostring(world.pawn.hp))
    assert(e.hp == 5, "enemy set was killed")
    assert(died_of("kill applied"), "no kill-applied log")
end)

test("no set belongs to the pawn: WARN, kill dropped, enemies untouched", function()
    local D = fresh()
    D.configure(SD_ON)
    world.pawn = new_pawn({ no_health = true })
    local e1, e2 = enemy_set(997), enemy_set(998)
    world.enemy_sets = { e1, e2 }
    D.on_bounced(bounce("Other", server_now + 100))
    ticks(D, 3)
    world.enemy_sets = nil
    assert(died_of("health attribute set not found"), "no WARN")
    assert(#queue == 0, "retried with no health set")
    assert(e1.hp == 5 and e2.hp == 5, "an enemy set was killed")
end)

test("no pawn: tick no-ops and the pending kill is held", function()
    local D = fresh()
    D.configure(SD_ON)
    world.pawn = nil
    D.on_bounced(bounce("Other", server_now + 100))
    ticks(D, 3)
    assert(#queue == 0)
    assert(D.status():find("pending=true", 1, true), "status: " .. D.status())
    world.pawn = new_pawn()
    ticks(D, 2)
    assert(world.pawn.hp == 0, "held kill never applied")
end)

test("send failure: no retry on the same death edge", function()
    local D = fresh()
    D.configure(SD_ON)
    fail_send = true
    world.pawn.hp = 0
    ticks(D, 3)
    assert(#sent == 0)
    assert(died_of("bounce send failed"), "no failure log")
    fail_send = false
    world.pawn.hp = 3
    ticks(D, 1)
    world.pawn.hp = 0
    ticks(D, 1)
    assert(#sent == 1, "next death should send")
end)

test("status() reports state", function()
    local D = fresh()
    D.configure(SD_ON)
    local s = D.status()
    assert(type(s) == "string" and s:find("enabled=", 1, true), "got " .. tostring(s))
end)

print(string.format("%d/%d passed", tests - failed, tests))
os.exit(failed == 0 and 0 or 1)