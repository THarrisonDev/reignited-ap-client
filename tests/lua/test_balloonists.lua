-- Stub-based spec for client/ue4ss_mod/srt_bridge/Scripts/spyro1/balloonists.lua.
-- Fakes the UE4SS surfaces the module touches (FindAllOf, Marco actors,
-- ExecuteInGameThread) with the behaviour observed live
-- (docs/game_state_control.md §9.5.1): each CNS1127_MarcoTheBalloonist_C has
-- LevelPath (FString, spelling may differ from the level path), GoalType
-- (EInventoryItemType number) and GoalValue (int); Marcos stream in late.
-- ExecuteInGameThread only QUEUES work; pump() runs it with the game-thread
-- flag set. Every write asserts that flag.
-- Run from the client repo root: lua tests/lua/test_balloonists.lua

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

local now = 1000
os.time = function() return now end

local EIT = { gems = 1, eggs = 15, dragons = 16 }

-- ---------------------------------------------------------------------------
-- fake Marcos
-- ---------------------------------------------------------------------------
local next_addr = 100
local function new_marco(level_path, goal_type, goal_value, unlocked)
    next_addr = next_addr + 1
    local P = { addr = next_addr, writes = 0, reject = false }
    P.props = { LevelPath = level_path, GoalType = goal_type, GoalValue = goal_value, Unlocked = unlocked or false }
    P.actor = setmetatable({}, {
        __index = function(_, k)
            if k == "IsValid" then return function() return true end end
            if k == "GetAddress" then return function() return P.addr end end
            local v = P.props[k]
            if type(v) == "string" then return fstring(v) end
            return v
        end,
        __newindex = function(_, k, v)
            assert(game_thread, "property " .. k .. " written off the game thread")
            if P.explode then error("marco boom") end
            assert(k == "GoalValue", "only GoalValue may be written, got " .. k)
            assert(math.type(v) == "integer", "GoalValue must be written as an integer")
            P.writes = P.writes + 1
            if not P.reject then P.props[k] = v end
        end,
    })
    return P
end

local world = { marcos = {} }
function FindAllOf(cls)
    if cls ~= "CNS1127_MarcoTheBalloonist_C" then return nil end
    local out = {}
    for _, P in ipairs(world.marcos) do out[#out + 1] = P.actor end
    return out
end

local level = "/LS101_ArtisansHome/Maps/"
local gs = setmetatable({}, { __index = function(_, k)
    if k == "current level" then return fstring(level) end
end })

local regions = {
    ["/LS101_ArtisansHome/Maps/"] = "Artisans",
    ["/LS102_StoneHill/Maps/"] = "Stone Hill",
    ["/LS107_PeacekeeperHome/Maps/"] = "Peace Keepers",
    ["/LS113_MagicCraftersHome/Maps/"] = "Magic Crafters",
    ["/LS119_BeastHome/Maps/"] = "Beast Makers",
}
local GATES = {
    ["Peace Keepers"] = { type = "dragons", needed = 11 },
    ["Magic Crafters"] = { type = "gems", needed = 1300 },
    ["Beast Makers"] = { type = "eggs", needed = 5 },
}
local function sd_with(reqs)
    return {
        included_games = { "spyro1" },
        options = { death_link = 0 },
        games = { spyro1 = { options = {}, level_keys = {}, gate_requirements = reqs } },
    }
end
local SD = sd_with(GATES)

-- ---------------------------------------------------------------------------
-- harness
-- ---------------------------------------------------------------------------
local lines = {}
local function fresh()
    package.loaded["spyro1.balloonists"] = nil
    queue = {}
    local B = require("spyro1.balloonists")
    lines = {}
    B.init({ log = function(l) lines[#lines + 1] = l end, regions = regions })
    level = "/LS101_ArtisansHome/Maps/"
    world.marcos = { new_marco("/LS107_PeacekeeperHome/Maps/", EIT.dragons, 10) }
    return B, world.marcos[1]
end
local function ticks(B, n) for _ = 1, n do B.tick(gs); pump() end end
local function settle(B) ticks(B, 4) end
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

test("raises a gate below the seed's number and logs it", function()
    local B, pk = fresh()
    B.configure(SD)
    settle(B)
    assert(pk.props.GoalValue == 11, "got " .. tostring(pk.props.GoalValue))
    assert(logged("%[BALLOON%] Peace Keepers gate 10 %-> 11 %(dragons%)"), "raise not logged")
    assert(B.status() == "enabled=true gates=3 raised_here=1", "got " .. B.status())
end)

test("configured line reports enabled and gate count", function()
    local B = fresh()
    B.configure(SD)
    assert(logged("^%[BALLOON%] configured: enabled=true gates=3$"))
end)

test("acts within a couple of polls of the level settling", function()
    local B, pk = fresh()
    B.configure(SD)
    ticks(B, 2)
    assert(pk.writes == 0, "wrote on the level's first settled poll")
    ticks(B, 1)
    assert(pk.props.GoalValue == 11, "not raised by the 3rd poll")
end)

test("never lowers a gate", function()
    local B, pk = fresh()
    pk.props.GoalValue = 15
    B.configure(SD)
    settle(B)
    assert(pk.props.GoalValue == 15 and pk.writes == 0)
end)

test("equal gate is left alone (vanilla seed is a no-op)", function()
    local B, pk = fresh()
    B.configure(sd_with({ ["Peace Keepers"] = { type = "dragons", needed = 10 } }))
    settle(B)
    assert(pk.writes == 0 and #queue == 0)
end)

test("GoalType mismatch: no write, one WARN per actor", function()
    local B, pk = fresh()
    pk.props.GoalType = EIT.gems
    B.configure(SD)
    settle(B)
    ticks(B, 5)
    assert(pk.writes == 0 and pk.props.GoalValue == 10)
    assert(count_logged("WARN Peace Keepers Marco GoalType=1") == 1,
        "expected exactly one mismatch WARN, got " .. count_logged("WARN Peace Keepers Marco GoalType"))
end)

test("non-gated and unknown LevelPath are ignored", function()
    local B = fresh()
    local back = new_marco("/LS102_StoneHill/Maps/", EIT.dragons, 0)
    local odd = new_marco("/LS199_Nowhere/Maps/", EIT.dragons, 0)
    local junk = new_marco("garbage", EIT.dragons, 0)
    world.marcos = { back, odd, junk }
    B.configure(SD)
    settle(B)
    assert(back.writes == 0 and odd.writes == 0 and junk.writes == 0)
end)

test("destination matched by LS code despite a different path spelling", function()
    local B = fresh()
    local mc = new_marco("/LS113_MagicHome/Maps/", EIT.gems, 1200)
    world.marcos = { mc }
    level = "/LS107_PeacekeeperHome/Maps/"
    B.configure(SD)
    settle(B)
    assert(mc.props.GoalValue == 1300, "got " .. tostring(mc.props.GoalValue))
end)

test("Marcos that stream in late are handled", function()
    local B = fresh()
    world.marcos = {}
    B.configure(SD)
    settle(B)
    local pk = new_marco("/LS107_PeacekeeperHome/Maps/", EIT.dragons, 10)
    world.marcos = { pk }
    ticks(B, 1)
    assert(pk.props.GoalValue == 11)
end)

test("several Marcos: one job per poll, all raised", function()
    local B, pk = fresh()
    local mc = new_marco("/LS113_MagicHome/Maps/", EIT.gems, 1200)
    world.marcos = { pk, mc }
    B.configure(SD)
    ticks(B, 2)
    B.tick(gs)
    assert(#queue == 1, "expected 1 queued job, got " .. #queue)
    pump()
    ticks(B, 1)
    assert(pk.props.GoalValue == 11 and mc.props.GoalValue == 1300)
    assert(B.status() == "enabled=true gates=3 raised_here=2", "got " .. B.status())
end)

test("level change resets per-actor state and waits for the new level", function()
    local B, pk = fresh()
    B.configure(SD)
    settle(B)
    assert(B.status():match("raised_here=1$"))
    level = "/LS107_PeacekeeperHome/Maps/"
    local mc = new_marco("/LS113_MagicHome/Maps/", EIT.gems, 1200)
    world.marcos = { mc }
    B.tick(gs)
    assert(B.status():match("raised_here=0$"), "state not reset: " .. B.status())
    assert(#queue == 0, "submitted on the level-change poll")
    settle(B)
    assert(mc.props.GoalValue == 1300)
    assert(pk.writes == 1)
end)

test("no writes outside homeworlds", function()
    local B, pk = fresh()
    level = "/LS102_StoneHill/Maps/"
    B.configure(SD)
    settle(B)
    assert(pk.writes == 0 and #queue == 0)
end)

test("nothing submitted while a job is in flight; abandoned after timeout", function()
    local B = fresh()
    B.configure(SD)
    for _ = 1, 3 do B.tick(gs) end
    assert(#queue == 1, "expected the raise job to be queued")
    for _ = 1, 5 do B.tick(gs) end
    assert(#queue == 1, "submitted while a job was in flight")
    now = now + 4
    B.tick(gs)
    assert(#queue == 1, "still waiting inside the timeout")
    now = now + 1
    B.tick(gs)
    assert(#queue == 2, "timed-out job should be abandoned and a new one submitted")
    assert(logged("never finished"), "abandoning a job should be logged")
end)

test("a failing job backs off instead of resubmitting every tick", function()
    local B, pk = fresh()
    pk.explode = true
    B.configure(SD)
    ticks(B, 20)
    assert(count_logged("ERROR raise Peace Keepers: ") == 1,
        "expected 1 ERROR inside the backoff, got " .. count_logged("ERROR raise Peace Keepers: "))
    now = now + 4
    ticks(B, 4)
    assert(count_logged("ERROR raise Peace Keepers: ") == 1, "resubmitted inside the backoff")
    now = now + 1
    ticks(B, 1)
    assert(count_logged("ERROR raise Peace Keepers: ") == 2, "expected one retry after the backoff")
    pk.explode = false
    now = now + 5
    ticks(B, 1)
    assert(pk.props.GoalValue == 11, "raise never landed")
end)

test("no game-thread API means no writes at all", function()
    ExecuteInGameThread = nil
    local B, pk = fresh()
    B.configure(SD)
    settle(B)
    assert(pk.writes == 0)
    assert(B.status():match("^enabled=false"))
    assert(logged("ExecuteInGameThread unavailable"))
end)

test("missing gate_requirements disables the module", function()
    local B, pk = fresh()
    B.configure({ games = { spyro1 = { options = {} } } })
    settle(B)
    assert(pk.writes == 0 and B.status() == "enabled=false gates=0 raised_here=0", "got " .. B.status())
    assert(logged("configured: enabled=false gates=0"))
    B.configure(nil)
    settle(B)
    assert(pk.writes == 0)
end)

test("malformed gate entries are skipped", function()
    local B, pk = fresh()
    B.configure(sd_with({
        ["Peace Keepers"] = { type = "orbs", needed = 99 },
        ["Magic Crafters"] = { type = "gems", needed = "lots" },
        ["Beast Makers"] = "eggs",
        [7] = { type = "eggs", needed = 5 },
        ["Dream Weavers"] = { type = "dragons", needed = -1 },
    }))
    settle(B)
    assert(pk.writes == 0 and B.status() == "enabled=false gates=0 raised_here=0", "got " .. B.status())
    B.configure(sd_with("nope"))
    assert(B.status():match("^enabled=false gates=0"))
end)

test("float needed from JSON is written as an integer", function()
    local B, pk = fresh()
    B.configure(sd_with({ ["Peace Keepers"] = { type = "dragons", needed = 12.0 } }))
    settle(B)
    assert(pk.props.GoalValue == 12 and math.type(pk.props.GoalValue) == "integer")
end)

test("blueprint reset is re-raised", function()
    local B, pk = fresh()
    B.configure(SD)
    settle(B)
    pk.props.GoalValue = 10
    ticks(B, 1)
    assert(pk.props.GoalValue == 11 and pk.writes == 2)
    assert(count_logged("gate 10 %-> 11") == 2)
end)

test("bad readback is warned, throttled, and retried", function()
    local B, pk = fresh()
    pk.reject = true
    B.configure(SD)
    ticks(B, 30)
    assert(pk.writes > 3, "expected retries")
    local warns = count_logged("WARN Peace Keepers gate write 10 %-> 11 read back 10")
    assert(warns >= 1 and warns <= 4, "got " .. warns .. " WARNs")
    assert(B.status():match("raised_here=0$"))
end)

test("Unlocked already true on first sight is logged once, never written", function()
    local B = fresh()
    local pk = new_marco("/LS107_PeacekeeperHome/Maps/", EIT.dragons, 10, true)
    world.marcos = { pk }
    B.configure(SD)
    settle(B)
    ticks(B, 5)
    assert(count_logged("Peace Keepers Marco already Unlocked on first sight") == 1)
    assert(pk.props.Unlocked == true and pk.props.GoalValue == 11)
end)

test("reconfigure replaces the gates", function()
    local B, pk = fresh()
    B.configure(SD)
    settle(B)
    B.configure(sd_with({ ["Peace Keepers"] = { type = "dragons", needed = 12 } }))
    settle(B)
    assert(pk.props.GoalValue == 12)
    assert(B.status() == "enabled=true gates=1 raised_here=1", "got " .. B.status())
end)

print(string.format("%d/%d passed", tests - failed, tests))
os.exit(failed == 0 and 0 or 1)
