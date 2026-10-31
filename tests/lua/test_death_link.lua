-- Author: Tim Harrison
-- Created: 2026-09-26
-- Updated: 2026-10-23

-- Stub-based spec for client/ue4ss_mod/srt_bridge/Scripts/death_link.lua.
-- Fakes the Spyro pawn with a GAS health attribute set behind an Outer chain
-- (IsDead reads hp <= 0, so a HealthCurrent=0 write really kills it) and
-- injects send/now/me. ExecuteInGameThread only QUEUES work; H.pump() runs it
-- with the game-thread flag set, and every write asserts that flag.
-- Run from the client repo root: lua tests/lua/test_death_link.lua

package.path = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "support/?.lua;" .. package.path
local H = require("harness")
local A = require("actors")

H.install_game_thread()

-- ---------------------------------------------------------------------------
-- fake world + pawn
-- ---------------------------------------------------------------------------
local world = { pawn = nil, enemy_sets = nil }
A.install(world)

local next_addr = 100
local function new_pawn(opts)
    next_addr = next_addr + 1
    local P = { addr = next_addr, hp = 3, reject_write = false }
    P.actor = setmetatable({}, { __index = function(_, k)
        if k == "IsValid" then return function() return true end end
        if k == "GetAddress" then return function() return P.addr end end
        if k == "GetOuter" then return function()
            assert(H.thread, "GetOuter off the game thread")
            return P.health_outer or P.actor
        end end
        if k == "IsDead" then return function() return P.hp <= 0 end end
        return nil
    end })
    P.health = nil
    if not (opts and opts.no_health) then P.health = A.health_set(H, P) end
    return P
end
local enemy_set = A.enemy_set

-- ---------------------------------------------------------------------------
-- harness
-- ---------------------------------------------------------------------------
local sent = {}
local fail_send = false
local server_now = 5000.0
local slot_name = "P1"
local inject = {
    log = H.collect,
    send = function(data)
        if fail_send then return false end
        sent[#sent + 1] = data
        return true
    end,
    now = function() return server_now end,
    me = function() return slot_name end,
}

local function fresh()
    H.new_fixture({})
    package.loaded["death_link"] = nil
    H.clear_queue()
    H.clear_log()
    sent, fail_send = {}, false
    server_now = 5000.0
    slot_name = "P1"
    world.pawn = new_pawn()
    ExecuteInGameThread = H.queue_fn
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
    for _, l in ipairs(H.lines) do
        for _, pat in ipairs({...}) do
            if l:find(pat, 1, true) then return true end
        end
    end
    return false
end

local test = H.test

local function ticks(D, n) for _ = 1, n or 1 do H.tick(D, {}); H.pump() end end

--- Configure an enabled session, die once (the bounce fills sent[1]), then revive.
--- @param D table The module under test.
local function die_and_revive(D)
    D.configure(SD_ON)
    world.pawn.hp = 0
    ticks(D, 1)
    assert(#sent == 1)
    world.pawn.hp = 3
    ticks(D, 1)
end

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
    die_and_revive(D)
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
    die_and_revive(D)
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
    H.tick(D, {})
    assert(H.queued() == 1, "kill not queued")
    assert(world.pawn.hp == 3, "written before the game thread ran")
    H.pump()
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
    H.tick(D, {})
    H.pump()
    assert(died_of("write did not stick"), "no WARN")
    ticks(D, 5)
    assert(H.queued() == 0, "kill retried")
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
    assert(H.queued() == 0, "retried with no health set")
end)

test("kill hits Spyro's set when an enemy's set comes first", function()
    local D = fresh()
    D.configure(SD_ON)
    local e = enemy_set(999)
    world.enemy_sets = { e }
    D.on_bounced(bounce("Other", server_now + 100))
    H.tick(D, {})
    H.pump()
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
    assert(H.queued() == 0, "retried with no health set")
    assert(e1.hp == 5 and e2.hp == 5, "an enemy set was killed")
end)

test("no pawn: tick no-ops and the pending kill is held", function()
    local D = fresh()
    D.configure(SD_ON)
    world.pawn = nil
    D.on_bounced(bounce("Other", server_now + 100))
    ticks(D, 3)
    assert(H.queued() == 0)
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

H.finish()