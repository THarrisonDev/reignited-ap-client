-- Author: Tim Harrison
-- Created: 2026-09-26
-- Updated: 2026-10-23

-- Stub-based spec for client/ue4ss_mod/srt_bridge/Scripts/spyro1/level_locks.lua.
-- The scenarios live in support/level_locks_suite.lua with the fake portals;
-- this file supplies the Spyro 1 slot-data shape plus the two job-runner cases
-- only a homeworld-lock seed exercises (a portal the game disabled mid-
-- transition, and a failing job's backoff).
-- Run from the client repo root: lua tests/lua/test_level_locks.lua

package.path = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "support/?.lua;" .. package.path
local suite = require("level_locks_suite")

suite.run({
    game = "spyro1",
    module = "spyro1.level_locks",
    portal_class = "PortalTransporter_C",
    seed = "S1",
    status_prefix = "",
    regions = {
        ["/LS101_ArtisansHome/Maps/"] = "Artisans",
        ["/LS102_StoneHill/Maps/"] = "Stone Hill",
        ["/LS103_DarkHollow/Maps/"] = "Dark Hollow",
        ["/LS105_Sunnyflight/Maps/"] = "Sunny Flight",
    },
    keys = { ["Stone Hill"] = "Spyro 1: Stone Hill Key", ["Dark Hollow"] = "Spyro 1: Dark Hollow Key" },
    keys_fraction = "1/2",
    locked_here = "1",
    shape_keys = "0/2",
    home = "/LS101_ArtisansHome/Maps/",
    realm = "/LS102_StoneHill/Maps/",
    portals = {
        { "LS102", "Stone Hill" },
        { "LS103", "Dark Hollow" },
        { "LS105", "Sunny Flight" },
    },
    key_item = "Spyro 1: Dragon",
    off_item = "Spyro 1: Dragon",
    unprefixed = "Dark Hollow Key",
    held_item = "Spyro 1: Dark Hollow Key",
    unlock_item = "Spyro 1: Stone Hill Key",
    visible_name = "StoneHill",
    held_portal = 2,
    untouched_portal = 3,
    shape_locked = { 1 },
    also_locked = {},
    explode = true,
    mid_transition = true,
})
