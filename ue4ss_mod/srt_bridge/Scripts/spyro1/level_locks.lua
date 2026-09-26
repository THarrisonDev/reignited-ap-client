-- level_locks (Spyro 1): Archipelago level locks. Every homeworld level
-- portal whose level has a key in this seed (slot_data.games.spyro1.
-- level_keys: region -> key item name) stays locked until that key item is
-- received. The whole implementation lives in level_locks_core.lua; this
-- wrapper only pins the Spyro 1 shape: PortalTransporter_C portals, the 6
-- homeworlds, and no target-homeworld skip (Spyro 1 homeworld portals are
-- never lock targets — the balloonists gate homeworlds instead).
--
-- API (main.lua): init{log, regions}, configure(slot_data) on slot connect,
-- note_item(name) per received item, tick(gamestate) from the poll loop,
-- status() for the heartbeat.

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