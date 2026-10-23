-- Author: Tim Harrison
-- Created: 2026-09-26
-- Updated: 2026-10-21

-- Stub-based spec for client/ue4ss_mod/srt_bridge/Scripts/spyro2/level_locks.lua.
-- The scenarios live in support/level_locks_suite.lua with the fake portals;
-- this file supplies the Spyro 2 slot-data shape and the game's own extras: the
-- 3-homeworld scan gate and the TARGET_HOMES skip (a portal whose partner maps
-- to a homeworld is never locked). The Summer Forest key is precollected in
-- real seeds, so it is left out of KEYS; TARGET_HOMES keeps homeworld portals
-- open.
-- Run from the client repo root: lua tests/lua/test_s2_level_locks.lua

package.path = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "support/?.lua;" .. package.path
local suite = require("level_locks_suite")

suite.run({
    game = "spyro2",
    module = "spyro2.level_locks",
    portal_class = "PortalTransporter_C",
    seed = "S2",
    status_prefix = "spyro2 ",
    regions = {
        ["/LS201_SummerForest_Home/Maps/"] = "Summer Forest",
        ["/LS202_Glimmer/Maps/"] = "Glimmer",
        ["/LS203_IdolSprings/Maps/"] = "Idol Springs",
        ["/LS204_Colossus/Maps/"] = "Colossus",
        ["/LS208_CrushsDungeon/Maps/"] = "Crush's Dungeon",
        ["/LS210_AutumnPlains_Home/Maps/"] = "Autumn Plains",
        ["/LS222_WinterTundra_Home/Maps/"] = "Winter Tundra",
        ["/LS223_MysticMarsh/Maps/"] = "Mystic Marsh",
    },
    keys = {
        ["Glimmer"] = "Spyro 2: Glimmer Key",
        ["Idol Springs"] = "Spyro 2: Idol Springs Key",
        ["Crush's Dungeon"] = "Spyro 2: Crush's Dungeon Key",
        ["Autumn Plains"] = "Spyro 2: Autumn Plains Key",
    },
    keys_fraction = "1/4",
    locked_here = "2",
    shape_keys = "1/4",
    home = "/LS201_SummerForest_Home/Maps/",
    realm = "/LS202_Glimmer/Maps/",
    portals = {
        { "LS202", "Glimmer" },
        { "LS203", "Idol Springs" },
        { "LS208", "Crush's Dungeon" },
        { "LS204", "Colossus" },
        { "LS210", "Autumn Plains" },
    },
    key_item = "Spyro 2: Crush's Dungeon Key",
    off_item = "Spyro 2: Glimmer Key",
    unprefixed = "Glimmer Key",
    held_item = "Spyro 2: Crush's Dungeon Key",
    unlock_item = "Spyro 2: Glimmer Key",
    visible_name = "Glimmer",
    held_portal = 3,
    untouched_portal = 4,
    home_portal = 5,
    shape_locked = { 1, 2 },
    also_locked = { 2 },
    unlocked_other = 2,
    homeworld_target = {
        target = "Autumn Plains",
        level = "/LS222_WinterTundra_Home/Maps/",
        portals = { { "LS223", "Mystic Marsh" }, { "LS210", "Autumn Plains" } },
        keys = {
            ["Mystic Marsh"] = "Spyro 2: Mystic Marsh Key",
            ["Autumn Plains"] = "Spyro 2: Autumn Plains Key",
        },
    },
})
