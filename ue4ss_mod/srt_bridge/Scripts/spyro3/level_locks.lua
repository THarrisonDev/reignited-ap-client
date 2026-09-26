-- level_locks (Spyro 3): mirrors spyro2/level_locks.lua via the shared
-- level_locks_core.lua — same levers (setPortalEnabled, REMAKE "LOCKED",
-- glyph reveal) and the same game-thread discipline. Spyro 3 shape:
--   * no PortalTransporter_S3 class: its level portals are ABasePortal_C
--     subclasses (AS3BalloonTransporter_C, AS3RocketTransporter_C,
--     AS3WhirligigTransporter_C, ABalloon_TargetPoint_C, ...), so
--     FindAllOf("BasePortal_C") finds them (and everything else standing
--     in the level — the PartnerPortalName parse filters)
--   * portals are scanned only inside the 4 S3 homeworlds; return portals
--     standing in realms are never touched
--   * TARGET_HOMES: a portal whose target region is a homeworld is never
--     locked — the homeworld transport actors (balloon/whirligig/rocket)
--     point at the next homeworld's LevelStart, so the skip covers them
--     (Midnight Mountain has no onward transport)
--   * slot data: sd.games.spyro3.options.level_locks +
--     sd.games.spyro3.level_keys (all 33 sub-levels; NO precollected key —
--     the spawn level Sunrise Spring is a homeworld)
--
-- API (main.lua): init{log, regions}, configure(slot_data) on slot connect,
-- note_item(name) per received item, tick(gamestate) from the poll loop,
-- status() for the heartbeat.

local core = require("level_locks_core")

local HOMEWORLDS = {
    ["Sunrise Spring"] = true, ["Midday Gardens"] = true,
    ["Evening Lake"] = true, ["Midnight Mountain"] = true,
}

return core.new({
    game = "spyro3",
    tag = "[LOCKS3]",
    label = " (spyro3)",
    prefix = "spyro3 ",
    portal_class = "BasePortal_C",
    homeworlds = HOMEWORLDS,
    target_homes = HOMEWORLDS,
})