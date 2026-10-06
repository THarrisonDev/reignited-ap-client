-- level_locks (Spyro 1): Archipelago level locks — a homeworld portal whose
-- level has a key in this seed (slot_data.games.spyro1.level_keys) stays locked
-- until that key item is received. Implementation shared in
-- level_locks_core.lua; this wrapper pins the Spyro 1 shape: PortalTransporter_C
-- portals, the 6 homeworlds, and no target-homeworld skip (Spyro 1 homeworld
-- portals are never lock targets — balloonists.lua gates homeworlds instead).
--
-- API (main.lua): init{log, regions}, configure(slot_data), note_item(name),
-- tick(gamestate), status().

local core = require("level_locks_core")

return core.new({
    game = "spyro1",
    tag = "[LOCKS]",
    label = "",
    prefix = "",
    portal_class = "PortalTransporter_C",
    homeworlds = {
        ["Artisans"] = true, ["Peace Keepers"] = true, ["Magic Crafters"] = true,
        ["Beast Makers"] = true, ["Dream Weavers"] = true, ["Gnorc Gnexus"] = true,
    },
})