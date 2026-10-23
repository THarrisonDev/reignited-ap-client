-- Author: Tim Harrison
-- Created: 2026-09-27
-- Updated: 2026-10-16

-- spyro2 orbs: the signed debug_extra_orbs reconcile (spyro2_orb_shuffle;
-- spec = tests/lua/test_orbs.lua). Drives the orb counter so the game's orb
-- doors open on received Orb items. Orb checks themselves are checkd's (the
-- save's EIT_S2GreenOrb records), so only the reconcile is here; the shared
-- drive (threading, gates, logs) is reconcile_core.lua. UNPROVEN live: that the
-- type-23 readback anchors and that the orb doors read save+extra; a readback
-- that never anchors leaves the module inert (vanilla counters, server-side
-- logic still routes the doors through items).
--
-- API (main.lua): init{log}, configure(slot_data, in_s2_session),
-- note_item(name, index), is_item(name), received(), last_extra(),
-- arm_backlog(), reset_received(), note_disconnected(), tick(world), reset(),
-- status().

local core = require("reconcile_core")
local C = require("constants")

local M = core.new({
    game = "spyro2",
    tag = "[ORBS2]",
    kind = "orbs",
    item = "Spyro 2: Orb",
    save_type = C.eit.EIT_S2GreenOrb, -- the save-record type checkd scans
    total = C.totals.orbs,
    ufunction = "debug - add s2 orbs",
    property = "debug_extra_orbs",
    option_name = "orb_shuffle",
    option_label = "orb_shuffle",
})

return M
