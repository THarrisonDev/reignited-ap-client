-- Author: Tim Harrison
-- Created: 2026-11-03
-- Updated: 2026-11-03

-- guidebook (Spyro 1): mark a received level key's level visited, so it appears
-- in the in-game Guide Book before it has been entered. Implementation shared in
-- guidebook_core.lua (levers, threading and design notes there); this wrapper
-- pins the Spyro 1 shape. Slot data: sd.games.spyro1.level_keys (region -> key
-- item name).
--
-- API (main.lua): init{log, regions}, configure(slot_data), note_item(name, index),
-- tick(world), status().

local core = require("guidebook_core")

return core.new({
    game = "spyro1",
    tag = "[GUIDE]",
    label = "",
    prefix = "",
})
