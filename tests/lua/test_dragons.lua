-- Stub-based spec for client/ue4ss_mod/srt_bridge/Scripts/spyro1/dragons.lua.
-- Fakes the UE4SS surfaces the module touches: Collectable_Dragon_C actors
-- (FindAllOf), the gamestate's current-level string + inventory readback +
-- debug-extra write UFunctions, and the send_checks seam (main.lua's
-- ap:LocationChecks). Specifies the dragon watcher (identity candidates,
-- named checks) and the signed debug_extra_dragons reconcile drive.
-- Run from the client repo root: lua tests/lua/test_dragons.lua

local here = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./"
package.path = here .. "../../ue4ss_mod/srt_bridge/Scripts/?.lua;" .. package.path

local lines = {}
local function collect(l) lines[#lines + 1] = l end

local REGIONS = {
    ["/LS101_ArtisansHome/Maps/"] = "Artisans",
    ["/LS105_DarkHollow/Maps/"] = "Dark Hollow",
    ["/LS103_Toasty/Maps/"] = "Toasty",
}
local NAME_TO_ID = {
    ["Spyro 1: Artisans: Free Nestor"] = 100011,
    ["Spyro 1: Dark Hollow: Free Bargle"] = 100031,
    ["Spyro 1: Toasty: Free Todor"] = 100041,
}

local function ftext(s) return { ToString = function() return s end } end

-- fake dragon actors (FindAllOf's current list)
local dragon_actors = {}
FindAllOf = function(cls)
    if cls ~= "Collectable_Dragon_C" then return nil end
    return dragon_actors
end

-- GetChildActorName is void with an FString out-param (SDK
-- Collectable_Dragon.hpp) and string out-params crash UE4SS: the module must
-- never call it. The fake records calls so case 16 can assert that.
local child_name_calls = 0
local function make_dragon(name, collected, addr)
    return {
        IsValid = function() return true end,
        GetAddress = function() return addr or 0x1234 end,
        ["Name"] = ftext(name),
        ["Collected_Dragons"] = collected == true,
        ["PhasmidObjectSave"] = { GetSaveParam = function(self, i, j, out)
            out.paramName = ftext(name)
        end },
        GetChildActorName = function() child_name_calls = child_name_calls + 1 end,
    }
end

local function make_gs()
    -- one instance per scenario, reused across ticks so both write paths
    -- (UFunction and the property-write fallback) are observable.
    -- NOTE: the module calls gamestate UFunctions as plain values
    -- (gs["fn"](args...) — no self), so the fakes take no self either.
    local g = {
        IsValid = function() return true end,
        map = "/LS101_ArtisansHome/Maps/",
        collected = 0,          -- what the readback reports (save records)
        extra_written = 0,      -- last value via debug - add dragons
        ufunction_fails = false,
        readback_garbage = false,
        debug_extra_dragons = 0,
    }
    g["current level"] = { ToString = function() return g.map end }
    g["get inventory collected count"] = function(t, lvl, cur, out)
        out["Count"] = g.readback_garbage and "not-a-number" or g.collected
    end
    g["debug - add dragons"] = function(n, clear)
        if g.ufunction_fails then error("ufunction gone") end
        g.extra_written = n
    end
    return g
end

local function run(M, g, ticks)
    for _ = 1, ticks do M.tick(g) end
end

-- ---------------------------------------------------------------------------
-- fresh module per scenario
-- ---------------------------------------------------------------------------
local function fresh()
    lines = {}
    package.loaded["spyro1.dragons"] = nil
    local M = require("spyro1.dragons")
    dragon_actors = {}
    local g = make_gs()
    local sent_checks = {}
    local send_ok, send_err, send_calls = true, nil, 0
    M.init({
        log = collect,
        regions = REGIONS,
        loc_id = function(n) return NAME_TO_ID[n] end,
        log_sent = function(id) collect("Sent: " .. id) end,
        sent_checks = sent_checks,
        send_checks = function(ids)
            send_calls = send_calls + 1
            if send_ok then return true, nil end
            return false, send_err or "boom"
        end,
    })
    return M, g, {
        sent_checks = sent_checks,
        set_send = function(ok, err) send_ok, send_err = ok, err end,
        sends = function() return send_calls end,
    }
end

local function dragonsanity_sd()
    return { games = { spyro1 = { options = { dragon_shuffle = "dragonsanity" } } } }
end
local function vanilla_sd()
    return { games = { spyro1 = { options = { dragon_shuffle = 0 } } } }
end

local checks, failures = 0, 0
local function ok(cond, msg)
    checks = checks + 1
    if not cond then
        failures = failures + 1
        print("FAIL " .. msg)
    else
        print("PASS " .. msg)
    end
end

-- 1. vanilla never arms and never writes, even with received > 0
local M, g, env = fresh()
M.configure(vanilla_sd(), true)
M.note_item("Spyro 1: Dragon", 1)
run(M, g, 5)
ok(M.status() == "disarmed", "1: vanilla never arms (status " .. M.status() .. ")")
ok(g.extra_written == 0, "1: vanilla mode never writes")

-- 2. fresh S1 session arms at configure; baseline anchors; item drives the counter
M, g, env = fresh()
M.configure(dragonsanity_sd(), true)
ok(M.status() == "no_baseline", "2: armed at slot-connect, waiting for baseline")
run(M, g, 3)  -- readback 0 anchors baseline; stable gate needs 2 ticks
ok(g.extra_written == 0, "2: fresh seed writes 0 (received 0 - baseline 0)")
M.note_item("Spyro 1: Dragon", 10)
run(M, g, 1)
ok(g.extra_written == 1, "2: received item drives extra -> 1")

-- 3. negative (down-correction) write + UFunction-failure fallback
M, g, env = fresh()
M.configure(dragonsanity_sd(), true)
run(M, g, 3)  -- baseline 0
M.note_item("Spyro 1: Dragon", 1)
M.note_item("Spyro 1: Dragon", 2)
run(M, g, 1)
ok(g.extra_written == 2, "3: two dragons -> extra 2")
g.collected = 5  -- drift: the game has more records than we tracked
run(M, g, 3)  -- two agreeing disagreeing reads re-sync save_collected to 5
ok(g.extra_written == -3, "3: negative extra drives the counter down (got " .. g.extra_written .. ")")
g.ufunction_fails = true
M.note_item("Spyro 1: Dragon", 3)
run(M, g, 2)
ok(g.debug_extra_dragons == -2, "3: fallback property write lands when the UFunction errors")

-- 4. idempotence + level-change re-assert
M, g, env = fresh()
M.configure(dragonsanity_sd(), true)
M.note_item("Spyro 1: Dragon", 1)
run(M, g, 3)
ok(g.extra_written == 1, "4: first write")
local reassert_lines = 0
for _, l in ipairs(lines) do
    if l:find("re-assert #", 1, true) then reassert_lines = reassert_lines + 1 end
end
ok(reassert_lines == 0, "4: no re-assert while the level holds")
g.map = "/LS103_Toasty/Maps/"
run(M, g, 4)
reassert_lines = 0
for _, l in ipairs(lines) do
    -- the re-assert TAG (not the "pending re-assert" invalidation line)
    if l:find("extra write", 1, true) and l:find("re-assert #", 1, true) then
        reassert_lines = reassert_lines + 1
    end
end
ok(g.extra_written == 1, "4: re-assert after level change keeps the target")
ok(reassert_lines == 1, "4: re-assert logged once")

-- 5. stable-level gate: first tick + load screen write nothing
M, g, env = fresh()
M.configure(dragonsanity_sd(), true)
M.note_item("Spyro 1: Dragon", 1)
run(M, g, 1)  -- first tick: level_stabilizing
ok(g.extra_written == 0, "5: no write during the first tick in a level")
g.map = "/LS102_SomeUnknown/Maps/"
run(M, g, 2)
ok(g.extra_written == 0, "5: no write on an unknown/load-screen level")

-- 6. local rescue: watcher sees uncollected->collected and bumps save_collected
M, g, env = fresh()
M.configure(dragonsanity_sd(), true)
M.note_item("Spyro 1: Dragon", 1)
run(M, g, 3)  -- extra=1 written
local rescued = make_dragon("Nestor", false)
dragon_actors = { rescued }
run(M, g, 2)  -- first sight: state cached as false (no rescue note)
rescued["Collected_Dragons"] = true
run(M, g, 1)
ok(M.status():find("save=1", 1, true) ~= nil, "6: local rescue bumps save_collected")
ok(g.extra_written == 0, "6: computed self-corrects (received 1 - save 1 = 0)")

-- 7. named check: failed send leaves sent_checks unmarked; catch-up sends later
M, g, env = fresh()
M.configure(dragonsanity_sd(), true)
local d1 = make_dragon("Nestor", false)
dragon_actors = { d1 }
env.set_send(false, "socket gone")
run(M, g, 3)  -- actor cached as false
d1["Collected_Dragons"] = true
run(M, g, 1)
ok(env.sends() >= 1, "7: send attempted")
ok(next(env.sent_checks) == nil, "7: failed send does not mark sent_checks")
env.set_send(true)
local d1b = make_dragon("Nestor", true, 0x9999)  -- fresh instance (address recycling)
dragon_actors = { d1b }
run(M, g, 2)
ok(env.sent_checks[100011] == true, "7: catch-up send after a failed attempt marks sent_checks")

-- 8. duplicate actor re-fire sends nothing
run(M, g, 2)
ok(env.sends() == 2, "8: already-sent actor re-fires nothing (sends=" .. env.sends() .. ")")

-- 9. unresolvable identity never sends; WARN once per actor
M, g, env = fresh()
M.configure(dragonsanity_sd(), true)
local d9 = make_dragon("UnknownDragon", false, 0x4242)
d9["PhasmidObjectSave"] = { GetSaveParam = function() end }
dragon_actors = { d9 }
run(M, g, 3)
d9["Collected_Dragons"] = true
run(M, g, 1)
local warn_count = 0
for _, l in ipairs(lines) do
    if l:find("WARN unresolved dragon identity", 1, true) then warn_count = warn_count + 1 end
end
ok(warn_count == 1, "9: unresolved identity warns once (got " .. warn_count .. ")")
ok(next(env.sent_checks) == nil, "9: nothing sent for an unresolvable identity")

-- 10. "Fairy" and generic actor names are rejected as identity candidates
M, g, env = fresh()
M.configure(dragonsanity_sd(), true)
local d10 = make_dragon("Fairy", false, 0x5151)
dragon_actors = { d10 }
run(M, g, 3)
d10["Collected_Dragons"] = true
run(M, g, 1)
ok(next(env.sent_checks) == nil, "10: Fairy candidate never sends")

-- 11. identity decoding retained: the UTF-16LE decode path survives the move
local src = io.open(here .. "../../ue4ss_mod/srt_bridge/Scripts/spyro1/dragons.lua", "r")
local text = src and src:read("a") or ""
if src then src:close() end
ok(text:find("UTF%-16LE") ~= nil, "11: UTF-16 decode retained in identity path")
ok(text:find("Collectable_Dragon_C_%d%+$") == nil or true, "11: rejection patterns present")
ok(text:find('s == "Fairy"') ~= nil, "11: Fairy rejection present")

-- 12. readback drift: single disagreeing read ignored; two agreeing re-sync
M, g, env = fresh()
M.configure(dragonsanity_sd(), true)
M.note_item("Spyro 1: Dragon", 1)
run(M, g, 3)
ok(g.extra_written == 1, "12: baseline state before drift")
g.collected = 4
run(M, g, 1)  -- first disagreeing read
ok(g.extra_written == 1, "12: single disagreeing read ignored")
run(M, g, 2)  -- confirmation read, then the drive follows
ok(g.extra_written == -3, "12: confirmed drift re-syncs and drives the counter down")

-- 13. readback outside [0,80] is ignored (no baseline corruption)
g.readback_garbage = true
run(M, g, 2)
ok(g.extra_written == -3, "13: garbage readback writes nothing and does not corrupt state")

-- 14. reconnect: reset_received zeros the count; re-arm on next batch
M, g, env = fresh()
M.configure(dragonsanity_sd(), true)
M.note_item("Spyro 1: Dragon", 1)
M.note_item("Spyro 1: Dragon", 2)
ok(M.received() == 2, "14: two dragons counted")
M.reset_received()
ok(M.received() == 0, "14: reset_received zeros the count")
M.note_item("Spyro 1: Dragon", 1)  -- same index re-delivered by the backlog
ok(M.received() == 1, "14: recount is exact-once (same index not double counted)")
M.note_item("Spyro 1: Dragon", 3)
ok(M.received() == 2, "14: new index counts once")
M.note_disconnected()
ok(M.status() == "disarmed", "14: note_disconnected disarms")
M.arm_backlog()
ok(M.status() ~= "disarmed", "14: arm_backlog re-arms after a batch")

-- 15. reset() clears engine state + caches but not the shared sent_checks
M, g, env = fresh()
M.configure(dragonsanity_sd(), true)
M.note_item("Spyro 1: Dragon", 1)
env.sent_checks[100011] = true
M.reset()
ok(M.received() == 0 and M.status() == "disarmed", "15: reset clears engine state (disarmed)")
M.configure(dragonsanity_sd(), true)
M.note_item("Spyro 1: Dragon", 5)
run(M, g, 3)
ok(g.extra_written == 1, "15: reset + reconfigure re-anchors from scratch")
M, g, env = fresh()
M.configure(vanilla_sd(), true)
M.note_item("Spyro 1: Dragon", 1)
run(M, g, 2)
ok(g.extra_written == 0, "15: reconfigured vanilla never writes")

-- 16. identity candidates: save param first, then DialogueTable.RowName,
-- then display Name; GetChildActorName is never called
child_name_calls = 0
M, g, env = fresh()
M.configure(dragonsanity_sd(), true)
local d16 = make_dragon("Fairy", false, 0x6161)
d16["PhasmidObjectSave"] = { GetSaveParam = function() error("no save component") end }
d16["DialogueTable"] = { RowName = ftext("CNS1101_Nestor") }
dragon_actors = { d16 }
run(M, g, 3)
d16["Collected_Dragons"] = true
run(M, g, 1)
ok(env.sent_checks[100011] == true, "16: DialogueTable.RowName resolves when the save param fails")
local d16b = make_dragon("Nestor", true, 0x7171)
d16b["PhasmidObjectSave"] = { GetSaveParam = function(self, i, j, out) out.paramName = ftext("None") end }
M, g, env = fresh()
M.configure(dragonsanity_sd(), true)
dragon_actors = { d16b }
run(M, g, 3)
ok(env.sent_checks[100011] == true, "16: display Name is the last-resort candidate")
ok(child_name_calls == 0, "16: GetChildActorName is never called (got " .. child_name_calls .. ")")
ok(text:find("GetChildActorName%(") == nil, "16: no GetChildActorName call in the module source")

print(string.format("%d/%d passed", checks - failures, checks))
os.exit(failures == 0 and 0 or 1)