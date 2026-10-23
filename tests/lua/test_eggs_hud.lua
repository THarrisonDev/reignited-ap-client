-- Author: Tim Harrison
-- Created: 2026-09-27
-- Updated: 2026-10-21

-- Spec for client/ue4ss_mod/srt_bridge/Scripts/spyro3/eggs_hud.lua. The
-- module has no actor watcher (checkd owns egg checks), so the cases from
-- support/reconcile.lua cover the signed debug_extra reconcile drive only.
-- Run from the client repo root: lua tests/lua/test_eggs_hud.lua

package.path = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "support/?.lua;" .. package.path
local H = require("harness")
local R = require("reconcile")

-- Sunrise Spring is the stable home level; Molten Crater the level-change case.
local REGIONS = {
    ["/LS301_SunriseSpring_Home/Maps/"] = "Sunrise Spring",
    ["/LS304_MoltenCrater/Maps/"] = "Molten Crater",
}

local ctx = {
    module = "spyro3.eggs_hud",
    regions = REGIONS,
    write = "debug - add s3 eggs",
    item = "Spyro 3: Dragon Egg",
    noun = "eggs",
    game_name = "Spyro 3",
    fallback = "debug extra s3 eggs",
    map = "/LS301_SunriseSpring_Home/Maps/",
    level2 = "/LS304_MoltenCrater/Maps/",
    load_screen = "", -- an empty path is the load screen
    load_screen_msg = "no write on a load-screen (empty) level",
    garbage_msg = "garbage readback writes nothing",
    out_of_domain = 200,
    sd = function() return { games = { spyro3 = { options = { egg_shuffle = 1 } } } } end,
    vanilla_sd = function() return { games = { spyro3 = { options = { egg_shuffle = 0 } } } } end,
}

function ctx.fresh() return R.load(ctx) end

R.standard(ctx)

-- 12. is_item only recognizes the Dragon Egg item name.
local M = ctx.fresh()
H.ok(M.is_item("Spyro 3: Dragon Egg") == true, "12: is_item true for the real item")
H.ok(M.is_item("Spyro 1: Dragon Egg") == false, "12: is_item false for another game's egg item")

H.finish()
