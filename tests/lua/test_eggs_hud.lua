-- Author: Tim Harrison
-- Created: 2026-09-27
-- Updated: 2026-10-11

-- Spec for client/ue4ss_mod/srt_bridge/Scripts/spyro3/eggs_hud.lua. The
-- module has no actor watcher (checkd owns egg checks), so this covers the
-- signed debug_extra reconcile drive only. Run from the client repo root:
--   lua tests/lua/test_eggs_hud.lua

local here = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./"
package.path = here .. "../../ue4ss_mod/srt_bridge/Scripts/?.lua;" .. package.path

local lines = {}
local function collect(l) lines[#lines + 1] = l end

local function make_gs()
    -- One instance per scenario, reused across ticks so both write paths
    -- (UFunction and property-write fallback) are observable. The module
    -- calls gamestate UFunctions as plain values with no self, so the fakes
    -- take no self either.
    local g = {
        IsValid = function() return true end,
        map = "/LS301_SunriseSpring_Home/Maps/",
        collected = 0,          -- value the readback reports
        extra_written = 0,      -- last value written via "debug - add s3 eggs"
        ufunction_fails = false,
        readback_garbage = false,
    }
    g["current level"] = { ToString = function() return g.map end }
    g["get inventory collected count"] = function(t, lvl, cur, out)
        out["Count"] = g.readback_garbage and "not-a-number" or g.collected
    end
    g["debug - add s3 eggs"] = function(n, clear)
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
    package.loaded["spyro3.eggs_hud"] = nil
    local M = require("spyro3.eggs_hud")
    local g = make_gs()
    M.init({ log = collect })
    return M, g
end

local function egg_shuffle_sd()
    return { games = { spyro3 = { options = { egg_shuffle = 1 } } } }
end
local function vanilla_sd()
    return { games = { spyro3 = { options = { egg_shuffle = 0 } } } }
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

-- 1. Vanilla sessions never arm or write, even with received items.
local M, g = fresh()
M.configure(vanilla_sd(), true)
M.note_item("Spyro 3: Dragon Egg", 1)
run(M, g, 5)
ok(M.status() == "disarmed", "1: vanilla never arms (status " .. M.status() .. ")")
ok(g.extra_written == 0, "1: vanilla mode never writes")

-- 2. A fresh Spyro 3 session arms at configure, anchors a baseline, and counts items.
M, g = fresh()
M.configure(egg_shuffle_sd(), true)
ok(M.status() == "no_baseline", "2: armed at slot-connect, waiting for baseline")
run(M, g, 3)  -- readback 0 anchors the baseline; the stable gate needs 2 ticks
ok(g.extra_written == 0, "2: fresh seed writes 0 (received 0 - baseline 0)")
M.note_item("Spyro 3: Dragon Egg", 10)
run(M, g, 1)
ok(g.extra_written == 1, "2: received item drives extra -> 1")

-- 3. Negative down-correction writes and the UFunction-failure fallback.
M, g = fresh()
M.configure(egg_shuffle_sd(), true)
run(M, g, 3)  -- baseline 0
M.note_item("Spyro 3: Dragon Egg", 1)
M.note_item("Spyro 3: Dragon Egg", 2)
run(M, g, 1)
ok(g.extra_written == 2, "3: two eggs -> extra 2")
g.collected = 5  -- drift: the game has more records than we tracked
run(M, g, 3)  -- two agreeing disagreeing reads re-sync save_collected to 5
ok(g.extra_written == -3, "3: negative extra drives the counter down (got " .. g.extra_written .. ")")
g.ufunction_fails = true
M.note_item("Spyro 3: Dragon Egg", 3)
run(M, g, 2)
-- The fallback property write is read back off the fake gamestate.
ok(g["debug extra s3 eggs"] == -2, "3: fallback property write lands when the UFunction errors")

-- 4. Writes are idempotent and are re-asserted after a level change.
M, g = fresh()
M.configure(egg_shuffle_sd(), true)
M.note_item("Spyro 3: Dragon Egg", 1)
run(M, g, 3)
ok(g.extra_written == 1, "4: first write")
local reassert_lines = 0
for _, l in ipairs(lines) do
    if l:find("re-assert #", 1, true) then reassert_lines = reassert_lines + 1 end
end
ok(reassert_lines == 0, "4: no re-assert while the level holds")
g.map = "/LS304_MoltenCrater/Maps/"
run(M, g, 4)
reassert_lines = 0
for _, l in ipairs(lines) do
    -- Match the re-assert tag, not the "pending re-assert" invalidation line.
    if l:find("extra write", 1, true) and l:find("re-assert #", 1, true) then
        reassert_lines = reassert_lines + 1
    end
end
ok(g.extra_written == 1, "4: re-assert after level change keeps the target")
ok(reassert_lines == 1, "4: re-assert logged once")

-- 5. The stable-level gate writes nothing on the first tick or on a load screen.
M, g = fresh()
M.configure(egg_shuffle_sd(), true)
M.note_item("Spyro 3: Dragon Egg", 1)
run(M, g, 1)  -- first tick: level_stabilizing
ok(g.extra_written == 0, "5: no write during the first tick in a level")
g.map = ""
run(M, g, 2)
ok(g.extra_written == 0, "5: no write on a load-screen (empty) level")

-- 6. A readback outside the [0, 146] domain never anchors a baseline.
M, g = fresh()
M.configure(egg_shuffle_sd(), true)
g.collected = 200  -- out of domain (garbage readback)
run(M, g, 4)
ok(M.status() == "no_baseline", "6: out-of-domain readback never anchors")
ok(g.extra_written == 0, "6: out-of-domain readback writes nothing")

-- 7. One disagreeing read is ignored; two agreeing reads re-sync.
M, g = fresh()
M.configure(egg_shuffle_sd(), true)
M.note_item("Spyro 3: Dragon Egg", 1)
run(M, g, 3)
ok(g.extra_written == 1, "7: baseline state before drift")
g.collected = 4
run(M, g, 1)  -- first disagreeing read
ok(g.extra_written == 1, "7: single disagreeing read ignored")
run(M, g, 2)  -- confirmation read, then the drive follows
ok(g.extra_written == -3, "7: confirmed drift re-syncs and drives the counter down")

-- 8. Garbage readbacks write nothing and do not corrupt state.
g.readback_garbage = true
run(M, g, 2)
ok(g.extra_written == -3, "8: garbage readback writes nothing")

-- 9. reset_received zeros the count and the module re-arms on the next batch.
M, g = fresh()
M.configure(egg_shuffle_sd(), true)
M.note_item("Spyro 3: Dragon Egg", 1)
M.note_item("Spyro 3: Dragon Egg", 2)
ok(M.received() == 2, "9: two eggs counted")
M.reset_received()
ok(M.received() == 0, "9: reset_received zeros the count")
M.note_item("Spyro 3: Dragon Egg", 1)  -- the backlog re-delivers the same index
ok(M.received() == 1, "9: recount is exact-once (same index not double counted)")
M.note_item("Spyro 3: Dragon Egg", 3)
ok(M.received() == 2, "9: new index counts once")
M.note_disconnected()
ok(M.status() == "disarmed", "9: note_disconnected disarms")
M.arm_backlog()
ok(M.status() ~= "disarmed", "9: arm_backlog re-arms after a batch")

-- 10. reset() clears the engine state.
M, g = fresh()
M.configure(egg_shuffle_sd(), true)
M.note_item("Spyro 3: Dragon Egg", 1)
run(M, g, 3)
M.reset()
ok(M.received() == 0 and M.status() == "disarmed", "10: reset clears engine state (disarmed)")
M.configure(egg_shuffle_sd(), true)
M.note_item("Spyro 3: Dragon Egg", 5)
run(M, g, 3)
ok(g.extra_written == 1, "10: reset + reconfigure re-anchors from scratch")

-- 11. Configuring a non-Spyro 3 session never arms.
M, g = fresh()
M.configure(egg_shuffle_sd(), false)
M.note_item("Spyro 3: Dragon Egg", 1)
run(M, g, 5)
ok(M.status() == "disarmed", "11: no arm outside a Spyro 3 session")

-- 12. is_egg only recognizes the Dragon Egg item name.
M, g = fresh()
ok(M.is_egg("Spyro 3: Dragon Egg") == true, "12: is_egg true for the real item")
ok(M.is_egg("Spyro 1: Dragon Egg") == false, "12: is_egg false for another game's egg item")

print(string.format("%d/%d passed", checks - failures, checks))
os.exit(failures == 0 and 0 or 1)
