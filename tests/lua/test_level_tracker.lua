-- Author: Tim Harrison
-- Created: 2026-10-05
-- Updated: 2026-10-21

-- Stub-based spec for client/ue4ss_mod/srt_bridge/Scripts/level_tracker.lua.
-- Fakes the gamestate's current-level string, injects send/regions and
-- exercises region-change detection, the announce-once rule, send-failure
-- retry and configure() resets.
-- Run from the client repo root: lua tests/lua/test_level_tracker.lua

package.path = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "support/?.lua;" .. package.path
local H = require("harness")

local REGIONS = {
    ["/LS101_ArtisansHome/Maps/"] = "Artisans",
    ["/LS102_StoneHill/Maps/"] = "Stone Hill",
    ["/LS201_SummerForest_Home/Maps/"] = "Summer Forest",
}

local sends
local function fresh()
    H.new_fixture(REGIONS)
    package.loaded["level_tracker"] = nil
    local mod = require("level_tracker")
    H.clear_log()
    sends = {}
    mod.init({
        log = H.collect,
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

local test = H.test

test("idle until configured (nothing sent in menus or before connect)", function()
    local M = fresh()
    assert(#sends == 0)
    H.tick(M, gs("/LS101_ArtisansHome/Maps/"))
    assert(#sends == 0, "sent while not configured")
    M.configure({})
    H.tick(M, gs("/LS101_ArtisansHome/Maps/"))
    assert(#sends == 1, "did not send after configure")
end)

test("announce on change, once per region", function()
    local M = fresh()
    M.configure({})
    H.tick(M, gs("/LS101_ArtisansHome/Maps/"))
    H.tick(M, gs("/LS101_ArtisansHome/Maps/"))
    assert(#sends == 1 and sends[1] == "Artisans", "Artisans not announced once")
    H.tick(M, gs("/LS102_StoneHill/Maps/"))
    assert(#sends == 2 and sends[2] == "Stone Hill", "Stone Hill not announced")
    H.tick(M, gs("/LS101_ArtisansHome/Maps/"))
    assert(#sends == 3 and sends[3] == "Artisans", "return to Artisans not announced")
end)

test("unknown levels (menus, cutscenes) are skipped, not announced", function()
    local M = fresh()
    M.configure({})
    H.tick(M, gs(""))
    H.tick(M, gs("/SomeNonLevel/Maps/"))
    H.tick(M, gs(""))
    H.tick(M, gs("/LS201_SummerForest_Home/Maps/"))
    assert(#sends == 1 and sends[1] == "Summer Forest",
        "menu churn produced sends: " .. table.concat(sends, ","))
end)

test("nil/absent gamestate read is tolerated", function()
    local M = fresh()
    M.configure({})
    H.tick(M, gs(nil))
    H.tick(M, {})
    H.tick(M, gs("/LS101_ArtisansHome/Maps/"))
    assert(#sends == 1 and sends[1] == "Artisans")
end)

test("failed send retries next tick, then sticks", function()
    local M = fresh()
    local fail = true
    H.new_fixture(REGIONS)
    package.loaded["level_tracker"] = nil
    local mod = require("level_tracker")
    H.clear_log()
    mod.init({
        log = H.collect,
        send = function(region)
            if fail then return false, "not connected" end
            sends[#sends + 1] = region
            return true
        end,
        regions = REGIONS,
    })
    mod.configure({})
    H.tick(mod, gs("/LS101_ArtisansHome/Maps/"))
    assert(#sends == 0, "sent despite failing send")
    H.tick(mod, gs("/LS101_ArtisansHome/Maps/"))
    fail = false
    H.tick(mod, gs("/LS101_ArtisansHome/Maps/"))
    assert(#sends == 1 and sends[1] == "Artisans", "retry did not announce")
    H.tick(mod, gs("/LS101_ArtisansHome/Maps/"))
    assert(#sends == 1, "announced twice")
end)

test("configure resets: same region re-announced on new session", function()
    local M = fresh()
    M.configure({})
    H.tick(M, gs("/LS101_ArtisansHome/Maps/"))
    M.configure({}) -- reconnect (e.g. new save picked)
    H.tick(M, gs("/LS101_ArtisansHome/Maps/"))
    assert(#sends == 2, "region not re-announced after reset")
    -- configure(nil) on session close disarms (main's close path calls it)
    M.configure(nil)
    H.tick(M, gs("/LS101_ArtisansHome/Maps/"))
    assert(#sends == 2, "sent after disarming configure(nil)")
end)

test("status mentions the current region", function()
    local M = fresh()
    M.configure({})
    assert(M.status():find("nil", 1, true), "status should start nil")
    H.tick(M, gs("/LS101_ArtisansHome/Maps/"))
    assert(M.status():find("Artisans", 1, true), "status lost the region")
end)

H.finish()