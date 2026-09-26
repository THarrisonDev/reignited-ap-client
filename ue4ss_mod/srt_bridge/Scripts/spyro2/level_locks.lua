-- level_locks (Spyro 2): mirrors spyro1/level_locks.lua via the shared
-- level_locks_core.lua — same levers (setPortalEnabled, REMAKE "LOCKED",
-- glyph reveal) and the same game-thread discipline. Spyro 2 shape:
--   * APortalTransporter_S2_C subclasses APortalTransporter_C, so
--     FindAllOf("PortalTransporter_C") finds S2 portals too; the same
--     PartnerPortalName "LS###_LevelStart" -> region parse applies
--   * portals are scanned only inside the 3 S2 homeworlds; return portals
--     standing in realms are never touched
--   * TARGET_HOMES: a portal whose target region is a homeworld is never
--     locked — homeworld-to-homeworld transitions stay open (locking a
--     homeworld's own return portal could trap the player)
--   * slot data: sd.games.spyro2.options.level_locks +
--     sd.games.spyro2.level_keys (region -> "Spyro 2: <Level> Key")
--
-- API (main.lua): init{log, regions}, configure(slot_data) on slot connect,
-- note_item(name) per received item, tick(gamestate) from the poll loop,
-- status() for the heartbeat.

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