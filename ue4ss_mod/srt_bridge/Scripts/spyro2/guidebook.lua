-- Author: Tim Harrison
-- Created: 2026-11-03
-- Updated: 2026-11-03

-- guidebook (Spyro 2): mark a received level key's level visited, so it appears
-- in the in-game Guide Book before it has been entered, via the shared
-- guidebook_core.lua. Slot data: sd.games.spyro2.level_keys (region -> key item
-- name).
--
-- API (main.lua): init{log, regions}, configure(slot_data), note_item(name, index),
-- tick(world), status().

local core = require("guidebook_core")
local C = require("constants")

return core.new({
    game = "spyro2",
    homeworlds = C.homeworlds.spyro2,
    tag = "[GUIDE2]",
    label = " (spyro2)",
    prefix = "spyro2 ",
})
