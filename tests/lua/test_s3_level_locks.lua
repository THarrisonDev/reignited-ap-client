-- Author: Tim Harrison
-- Created: 2026-09-26
-- Updated: 2026-10-23

-- Stub-based spec for client/ue4ss_mod/srt_bridge/Scripts/spyro3/level_locks.lua.
-- The scenarios live in support/level_locks_suite.lua with the fake portals;
-- this file supplies the Spyro 3 slot-data shape and the game's own extras: the
-- 4-homeworld scan gate, the FindAllOf("BasePortal_C") class and the
-- TARGET_HOMES skip. There is no precollected spawn key — Sunrise Spring is a
-- homeworld.
-- Run from the client repo root: lua tests/lua/test_s3_level_locks.lua

package.path = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "support/?.lua;" .. package.path
local suite = require("level_locks_suite")

suite.run({
    game = "spyro3",
    module = "spyro3.level_locks",
    portal_class = "BasePortal_C",
    seed = "S3",
    status_prefix = "spyro3 ",
    regions = {
        ["/LS301_SunriseSpring_Home/Maps/"] = "Sunrise Spring",
        ["/LS302_SunnyVilla/Maps/"] = "Sunny Villa",
        ["/LS303_CloudSpires/Maps/"] = "Cloud Spires",
        ["/LS308_BuzzsDungeon/Maps/"] = "Buzz's Dungeon",
        ["/LS310_MiddayGardens_Home/Maps/"] = "Midday Gardens",
        ["/LS311_IcyPeak/Maps/"] = "Icy Peak",
        ["/LS319_EveningLake_Home/Maps/"] = "Evening Lake",
        ["/LS320_LostFleet/Maps/"] = "Lost Fleet",
        ["/LS328_MidnightMountain_Home/Maps/"] = "Midnight Mountain",
        ["/LS329_CrystalIslands/Maps/"] = "Crystal Islands",
    },
    keys = {
        ["Sunny Villa"] = "Spyro 3: Sunny Villa Key",
        ["Cloud Spires"] = "Spyro 3: Cloud Spires Key",
        ["Buzz's Dungeon"] = "Spyro 3: Buzz's Dungeon Key",
        ["Midday Gardens"] = "Spyro 3: Midday Gardens Key",
    },
    keys_fraction = "1/4",
    locked_here = "2",
    shape_keys = "1/4",
    home = "/LS301_SunriseSpring_Home/Maps/",
    realm = "/LS302_SunnyVilla/Maps/",
    portals = {
        { "LS302", "Sunny Villa" },
        { "LS303", "Cloud Spires" },
        { "LS308", "Buzz's Dungeon" },
        { "LS329", "Crystal Islands" },
        { "LS310", "Midday Gardens" },
    },
    key_item = "Spyro 3: Buzz's Dungeon Key",
    off_item = "Spyro 3: Sunny Villa Key",
    unprefixed = "Sunny Villa Key",
    held_item = "Spyro 3: Buzz's Dungeon Key",
    unlock_item = "Spyro 3: Sunny Villa Key",
    visible_name = "SunnyVilla",
    held_portal = 3,
    untouched_portal = 4,
    home_portal = 5,
    shape_locked = { 1, 2 },
    also_locked = { 2 },
    unlocked_other = 2,
    homeworld_target = {
        target = "Midday Gardens",
        level = "/LS328_MidnightMountain_Home/Maps/",
        portals = { { "LS329", "Crystal Islands" }, { "LS310", "Midday Gardens" } },
        keys = {
            ["Crystal Islands"] = "Spyro 3: Crystal Islands Key",
            ["Midday Gardens"] = "Spyro 3: Midday Gardens Key",
        },
    },
})
