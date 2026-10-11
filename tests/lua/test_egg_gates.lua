-- Author: Tim Harrison
-- Created: 2026-09-27
-- Updated: 2026-10-11

-- Spec for client/ue4ss_mod/srt_bridge/Scripts/spyro3/egg_gates.lua, using
-- fakes for the UE4SS surfaces the module touches. Covers the
-- vanilla-minus-received tuning, TargetName matching, the homeworld gate,
-- and received-item bookkeeping.
-- Run from the client repo root: lua tests/lua/test_egg_gates.lua

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
-- fake PortalControllers
-- ---------------------------------------------------------------------------
-- The target is the engine TargetName (e.g. "LS304_MoltenCrater"), not the
-- display name, matching the real game.
local next_addr = 100
local function new_controller(target, egg_req, gem_req, opts)
    opts = opts or {}
    next_addr = next_addr + 1
    local P = { addr = next_addr, writes = 0, opens = 0 }
    P.props = { TargetName = target, EggRequirement = egg_req, GemRequirement = gem_req or 0 }
    -- QuestActions: a fake object reference, valid unless opts.no_actions.
    -- open_fails makes the Open() call throw (Lua-caught path).
    -- Do not write this as `opts.no_actions and nil or {...}`; that idiom
    -- always picks the `or` branch when the `and` branch is nil.
    local actions = nil
    if not opts.no_actions then
        actions = { IsValid = function() return true end }
    end
    P.actor = setmetatable({}, {
        __index = function(_, k)
            if k == "IsValid" then return function() return true end end
            if k == "GetAddress" then return function() return P.addr end end
            if k == "QuestActions" then return actions end
            if k == "Open" then
                return function(_, given_actions)
                    assert(game_thread, "Open() called off the game thread")
                    assert(given_actions == actions, "Open() called with the wrong QuestActions")
                    if opts.open_fails then error("Open() blew up") end
                    P.opens = P.opens + 1
                end
            end
            local v = P.props[k]
            if type(v) == "string" then return { ToString = function() return v end } end
            return v
        end,
        __newindex = function(_, k, v)
            assert(game_thread, "property " .. k .. " written off the game thread")
            assert(k == "EggRequirement", "only EggRequirement may be written, got " .. k)
            assert(math.type(v) == "integer", "EggRequirement must be written as an integer")
            P.writes = P.writes + 1
            P.props[k] = v
        end,
    })
    return P
end

local world = { controllers = {} }
function FindAllOf(cls)
    if cls ~= "PortalController" then return nil end
    local out = {}
    for _, P in ipairs(world.controllers) do out[#out + 1] = P.actor end
    return out
end

local level = "/LS301_SunriseSpring_Home/Maps/"
local gs = setmetatable({}, { __index = function(_, k)
    if k == "current level" then return { ToString = function() return level end } end
end })

local regions = {
    ["/LS301_SunriseSpring_Home/Maps/"] = "Sunrise Spring",
    ["/LS310_MiddayGardens_Home/Maps/"] = "Midday Gardens",
    ["/LS302_SunnyVilla/Maps/"] = "Sunny Villa",
    ["/LS304_MoltenCrater/Maps/"] = "Molten Crater",
    ["/LS305_SeashellShore/Maps/"] = "Seashell Shore",
}
local SD = {
    included_games = { "spyro3" },
    options = { death_link = 0 },
    games = { spyro3 = {
        options = { egg_shuffle = 1 },
        egg_gates = { ["Molten Crater"] = 10, ["Seashell Shore"] = 14 },
    } },
}
local SD_OFF = {
    options = {},
    games = { spyro3 = { options = { egg_shuffle = 0 }, egg_gates = { ["Molten Crater"] = 10 } } },
}

-- ---------------------------------------------------------------------------
-- harness
-- ---------------------------------------------------------------------------
local lines = {}
local function fresh()
    package.loaded["spyro3.egg_gates"] = nil
    queue = {}
    local E = require("spyro3.egg_gates")
    lines = {}
    E.init({ log = function(l) lines[#lines + 1] = l end, regions = regions })
    level = "/LS301_SunriseSpring_Home/Maps/"
    world.controllers = { new_controller("LS304_MoltenCrater", 10) }
    return E, world.controllers[1]
end
local function ticks(E, n) for _ = 1, n do E.tick(gs); pump() end end
local function settle(E) ticks(E, 3) end
local function logged(pat)
    for _, l in ipairs(lines) do if l:find(pat) then return true end end
    return false
end
local function count_logged(pat)
    local n = 0
    for _, l in ipairs(lines) do if l:find(pat) then n = n + 1 end end
    return n
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

test("tunes a vanilla requirement down by received items", function()
    local E, c = fresh()
    E.configure(SD)
    E.note_item("Spyro 3: Dragon Egg")
    E.note_item("Spyro 3: Dragon Egg")
    settle(E)
    assert(c.props.EggRequirement == 8, "got " .. tostring(c.props.EggRequirement))
    assert(logged("Molten Crater egg gate 10 %-> 8 %(received 2%)"), "tune not logged")
    assert(c.opens == 0, "a partial tune must not force the gate open")
end)

test("requirement at or below received is zeroed (portal opens outright)", function()
    local E, c = fresh()
    E.configure(SD)
    for _ = 1, 10 do E.note_item("Spyro 3: Dragon Egg") end
    settle(E)
    assert(c.props.EggRequirement == 0, "got " .. tostring(c.props.EggRequirement))
    assert(c.opens == 1, "reaching 0 must force the gate open via Open(QuestActions)")
    assert(logged("Molten Crater egg gate forced open"), "forced-open not logged")
end)

test("QuestActions invalid at 0: WARN, no forced open, write still lands", function()
    local E = fresh()
    local c = new_controller("LS304_MoltenCrater", 10, nil, { no_actions = true })
    world.controllers = { c }
    E.configure(SD)
    for _ = 1, 10 do E.note_item("Spyro 3: Dragon Egg") end
    settle(E)
    assert(c.props.EggRequirement == 0, "the requirement write must still land")
    assert(c.opens == 0, "no Open() call without a valid QuestActions")
    assert(logged("QuestActions unreadable"), "missing-actions case not logged")
end)

test("Open() call throwing is Lua-caught: WARN, no crash, write stands", function()
    local E = fresh()
    local c = new_controller("LS304_MoltenCrater", 10, nil, { open_fails = true })
    world.controllers = { c }
    E.configure(SD)
    for _ = 1, 10 do E.note_item("Spyro 3: Dragon Egg") end
    settle(E)
    assert(c.props.EggRequirement == 0, "the requirement write must still land")
    assert(c.opens == 0, "opens must not increment when Open() throws")
    assert(logged("Open%(%) call failed"), "failed-open case not logged")
end)

test("never raises a requirement and leaves 0 alone", function()
    local E, c = fresh()
    c.props.EggRequirement = 0
    E.configure(SD)
    settle(E)
    assert(c.props.EggRequirement == 0 and c.writes == 0)
end)

test("no Dragon Egg received: vanilla number stays (no write)", function()
    local E, c = fresh()
    E.configure(SD)
    settle(E)
    assert(c.props.EggRequirement == 10 and c.writes == 0)
end)

test("controllers outside the slot's egg_gates are ignored", function()
    local E = fresh()
    local other = new_controller("LS302_SunnyVilla", 5)
    local unknown = new_controller("Nowhere", 7)
    world.controllers = { other, unknown }
    E.configure(SD)
    settle(E)
    assert(other.writes == 0 and unknown.writes == 0)
end)

test("egg_shuffle off: module is inert", function()
    local E, c = fresh()
    E.configure(SD_OFF)
    settle(E)
    assert(c.writes == 0 and c.props.EggRequirement == 10)
    assert(logged("^%[EGGS3%] configured: enabled=false"), "configure line wrong")
end)

test("non-egg items are ignored", function()
    local E, c = fresh()
    E.configure(SD)
    E.note_item("Spyro 3: Sunny Villa Key")
    E.note_item("Spyro 1: Dragon")
    settle(E)
    assert(c.props.EggRequirement == 10)
end)

test("received items after the tune drive a further tune", function()
    local E, c = fresh()
    E.configure(SD)
    settle(E)
    for _ = 1, 4 do E.note_item("Spyro 3: Dragon Egg") end
    settle(E)
    assert(c.props.EggRequirement == 6, "got " .. tostring(c.props.EggRequirement))
end)

test("no writes outside homeworlds", function()
    local E, c = fresh()
    level = "/LS304_MoltenCrater/Maps/"
    E.configure(SD)
    E.note_item("Spyro 3: Dragon Egg")
    settle(E)
    assert(c.writes == 0 and c.props.EggRequirement == 10)
end)

test("level change resets per-actor state and re-tunes fresh actors", function()
    local E, c = fresh()
    E.configure(SD)
    E.note_item("Spyro 3: Dragon Egg")
    settle(E)
    assert(E.status():match("received=1 tuned_here=1"))
    level = "/LS310_MiddayGardens_Home/Maps/"
    local c2 = new_controller("LS304_MoltenCrater", 10)
    world.controllers = { c2 }
    E.tick(gs)
    assert(#queue == 0, "submitted on the level-change poll")
    settle(E)
    assert(c2.props.EggRequirement == 9, "fresh actor not re-tuned")
    assert(c2.writes == 1, "fresh actor tuned more than once")
    assert(logged("Molten Crater egg gate 10 %-> 9 %(received 1%)"))
end)

test("several controllers: one job per poll, all tuned", function()
    local E, c = fresh()
    local c2 = new_controller("LS305_SeashellShore", 14)
    world.controllers = { c, c2 }
    E.configure(SD)
    for _ = 1, 3 do E.note_item("Spyro 3: Dragon Egg") end
    ticks(E, 3)
    E.tick(gs)
    assert(#queue == 1, "expected 1 queued job, got " .. #queue)
    pump()
    ticks(E, 2)
    assert(c.props.EggRequirement == 7 and c2.props.EggRequirement == 11)
    assert(E.status() == "enabled=true gates=2 received=3 tuned_here=2 bad=0",
        "got " .. E.status())
end)

test("unreadable EggRequirement at plan time: silently skipped", function()
    local E = fresh()
    local bad = new_controller("LS304_MoltenCrater", 10)
    bad.props.EggRequirement = nil
    world.controllers = { bad }
    E.configure(SD)
    E.note_item("Spyro 3: Dragon Egg")
    settle(E)
    ticks(E, 5)
    assert(bad.writes == 0)
    assert(E.status():match("tuned_here=0 "), "got " .. E.status())
end)

test("EggRequirement going unreadable between plan and job: WARN, no write", function()
    local E, bad = fresh()
    E.configure(SD)
    E.note_item("Spyro 3: Dragon Egg")
    settle(E)
    assert(bad.props.EggRequirement == 9, "precondition: tuned to 9")
    -- A second egg arrives, so the next settled poll submits a job for 8.
    E.note_item("Spyro 3: Dragon Egg")
    E.tick(gs)
    assert(#queue == 1, "job not submitted")
    bad.props.EggRequirement = nil -- the actor dies mid-flight
    pump()
    assert(bad.props.EggRequirement == nil, "the mid-flight job must not write")
    assert(bad.writes == 1, "expected only the settle's tune write")
    assert(count_logged("WARN EggRequirement unreadable") == 1,
        "expected one throttled WARN, got " .. count_logged("WARN EggRequirement unreadable"))
end)

test("configure line reports enabled and gate count", function()
    local E = fresh()
    E.configure(SD)
    assert(logged("^%[EGGS3%] configured: enabled=true gates=2 %(egg_shuffle=1%)$"))
end)

print(string.format("\n%d/%d passed", tests - failed, tests))
os.exit(failed == 0 and 0 or 1)