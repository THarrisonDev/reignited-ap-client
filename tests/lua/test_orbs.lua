-- Author: Tim Harrison
-- Created: 2026-09-27
-- Updated: 2026-10-21

-- Stub-based spec for client/ue4ss_mod/srt_bridge/Scripts/spyro2/orbs.lua.
-- Fakes the gamestate's current-level string + inventory readback +
-- debug-extra write UFunctions. The module has no actor watcher (orb checks
-- are checkd's), so the cases from support/reconcile.lua cover the signed
-- debug_extra_orbs reconcile drive only. Run from the client repo root:
--   lua tests/lua/test_orbs.lua

package.path = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "support/?.lua;" .. package.path
local H = require("harness")
local R = require("reconcile")

-- Glimmer is the stable home level; Canyon is the level-change case.
local REGIONS = {
    ["/LS201_Glimmer/Maps/"] = "Glimmer",
    ["/LS203_Canyon/Maps/"] = "Canyon",
}

local ctx = {
    module = "spyro2.orbs",
    regions = REGIONS,
    write = "debug - add s2 orbs",
    item = "Spyro 2: Orb",
    noun = "orbs",
    game_name = "Spyro 2",
    fallback = "debug_extra_orbs",
    map = "/LS201_Glimmer/Maps/",
    level2 = "/LS203_Canyon/Maps/",
    load_screen = "", -- an empty path is the load screen
    load_screen_msg = "no write on a load-screen (empty) level",
    garbage_msg = "garbage readback writes nothing",
    out_of_domain = 99,
    sd = function() return { games = { spyro2 = { options = { orb_shuffle = 1 } } } } end,
    vanilla_sd = function() return { games = { spyro2 = { options = { orb_shuffle = 0 } } } } end,
}

function ctx.fresh() return R.load(ctx) end

R.standard(ctx)

H.finish()
