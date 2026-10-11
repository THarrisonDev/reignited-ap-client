-- Author: Tim Harrison
-- Created: 2026-09-26
-- Updated: 2026-10-11

-- level_locks (Spyro 2): lock homeworld portals whose level has a key in this
-- seed until that key is received. Implementation shared in
-- level_locks_core.lua; this wrapper pins the Spyro 2 shape:
-- APortalTransporter_S2_C subclasses PortalTransporter_C (so FindAllOf finds
-- S2 portals too), only the 3 S2 homeworlds are scanned, and a portal whose
-- target region is a homeworld is never locked (locking a homeworld's own
-- return portal could trap the player). Slot data:
-- sd.games.spyro2.options.level_locks + sd.games.spyro2.level_keys.
--
-- API (main.lua): init{log, regions}, configure(slot_data), note_item(name),
-- tick(gamestate), status().

local core = require("level_locks_core")

local HOMEWORLDS = {
    ["Summer Forest"] = true, ["Autumn Plains"] = true, ["Winter Tundra"] = true,
}

return core.new({
    game = "spyro2",
    tag = "[LOCKS2]",
    label = " (spyro2)",
    prefix = "spyro2 ",
    portal_class = "PortalTransporter_C",
    homeworlds = HOMEWORLDS,
    target_homes = HOMEWORLDS,
})