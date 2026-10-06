-- Stub-based spec for client/ue4ss_mod/srt_bridge/Scripts/level_tracker.lua.
-- Fakes the gamestate's current-level string, injects send/regions and
-- exercises region-change detection, the announce-once rule, send-failure
-- retry and configure() resets.
-- Run from the client repo root: lua tests/lua/test_level_tracker.lua

local here = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./"
package.path = here .. "../../ue4ss_mod/srt_bridge/Scripts/?.lua;" .. package.path

local REGIONS = {
    ["/LS101_ArtisansHome/Maps/"] = "Artisans",
    ["/LS102_StoneHill/Maps/"] = "Stone Hill",
    ["/LS201_SummerForest_Home/Maps/"] = "Summer Forest",
}

local lines, sends, gs_map
local function fresh()
    package.loaded["level_tracker"] = nil
    local mod = require("level_tracker")
    lines, sends = {}, {}
    mod.init({
        log = function(l) lines[#lines + 1] = l end,
        send = function(region)
            sends[#sends + 1] = region
            return true
        end,
        regions = REGIONS,
    })
    return mod
end

local function gs(level)
    return {["current level"] = {ToString = function() return level end}}
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
end

test("idle until configured (nothing sent in menus or before connect)", function()
    local M = fresh()
    assert(#sends == 0)
    M.tick(gs("/LS101_ArtisansHome/Maps/"))
    assert(#sends == 0, "sent while not configured")
    M.configure({})
    M.tick(gs("/LS101_ArtisansHome/Maps/"))
    assert(#sends == 1, "did not send after configure")
end)

test("announce on change, once per region", function()
    local M = fresh()
    M.configure({})
    M.tick(gs("/LS101_ArtisansHome/Maps/"))
    M.tick(gs("/LS101_ArtisansHome/Maps/"))
    assert(#sends == 1 and sends[1] == "Artisans", "Artisans not announced once")
    M.tick(gs("/LS102_StoneHill/Maps/"))
    assert(#sends == 2 and sends[2] == "Stone Hill", "Stone Hill not announced")
    M.tick(gs("/LS101_ArtisansHome/Maps/"))
    assert(#sends == 3 and sends[3] == "Artisans", "return to Artisans not announced")
end)

test("unknown levels (menus, cutscenes) are skipped, not announced", function()
    local M = fresh()
    M.configure({})
    M.tick(gs(""))
    M.tick(gs("/SomeNonLevel/Maps/"))
    M.tick(gs(""))
    M.tick(gs("/LS201_SummerForest_Home/Maps/"))
    assert(#sends == 1 and sends[1] == "Summer Forest",
        "menu churn produced sends: " .. table.concat(sends, ","))
end)

test("nil/absent gamestate read is tolerated", function()
    local M = fresh()
    M.configure({})
    M.tick(gs(nil))
    M.tick({})
    M.tick(gs("/LS101_ArtisansHome/Maps/"))
    assert(#sends == 1 and sends[1] == "Artisans")
end)

test("failed send retries next tick, then sticks", function()
    local M = fresh()
    local fail = true
    package.loaded["level_tracker"] = nil
    local mod = require("level_tracker")
    lines = {}
    mod.init({
        log = function(l) lines[#lines + 1] = l end,
        send = function(region)
            if fail then return false, "not connected" end
            sends[#sends + 1] = region
            return true
        end,
        regions = REGIONS,
    })
    mod.configure({})
    mod.tick(gs("/LS101_ArtisansHome/Maps/"))
    assert(#sends == 0, "sent despite failing send")
    mod.tick(gs("/LS101_ArtisansHome/Maps/"))
    fail = false
    mod.tick(gs("/LS101_ArtisansHome/Maps/"))
    assert(#sends == 1 and sends[1] == "Artisans", "retry did not announce")
    mod.tick(gs("/LS101_ArtisansHome/Maps/"))
    assert(#sends == 1, "announced twice")
end)

test("configure resets: same region re-announced on new session", function()
    local M = fresh()
    M.configure({})
    M.tick(gs("/LS101_ArtisansHome/Maps/"))
    M.configure({}) -- reconnect (e.g. new save picked)
    M.tick(gs("/LS101_ArtisansHome/Maps/"))
    assert(#sends == 2, "region not re-announced after reset")
    -- configure(nil) on session close disarms (main's close path calls it)
    M.configure(nil)
    M.tick(gs("/LS101_ArtisansHome/Maps/"))
    assert(#sends == 2, "sent after disarming configure(nil)")
end)

test("status mentions the current region", function()
    local M = fresh()
    M.configure({})
    assert(M.status():find("nil", 1, true), "status should start nil")
    M.tick(gs("/LS101_ArtisansHome/Maps/"))
    assert(M.status():find("Artisans", 1, true), "status lost the region")
end)

print(string.format("%d/%d passed", tests - failed, tests))
os.exit(failed == 0 and 0 or 1)