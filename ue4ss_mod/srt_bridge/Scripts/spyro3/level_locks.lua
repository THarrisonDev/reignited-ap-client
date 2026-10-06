-- level_locks (Spyro 3): lock unreceived sub-level portals inside the S3
-- homeworlds, via the shared level_locks_core.lua (levers and threading there).
-- See docs/game_gates.md.

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
    -- S3 has no PortalTransporter_S3: its portals are BasePortal_C subclasses.
    portal_class = "BasePortal_C",
    homeworlds = HOMEWORLDS,
    -- Never lock a portal targeting a homeworld; the balloon/whirligig/rocket
    -- actors point at the next homeworld's LevelStart, so this covers them.
    target_homes = HOMEWORLDS,
})