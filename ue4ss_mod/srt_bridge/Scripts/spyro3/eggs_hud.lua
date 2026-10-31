-- Author: Tim Harrison
-- Created: 2026-09-27
-- Updated: 2026-10-23

-- eggs_hud (Spyro 3): drive the signed debug-extra egg counter so the HUD
-- matches the received Dragon Egg items (spyro3_egg_shuffle). Display only: it
-- leaves the pure save record the egg gates read untouched, so it can never
-- open a door. The shared drive (threading, level gate, logs) is
-- reconcile_core.lua; spec = tests/lua/test_eggs_hud.lua.
--
-- API (main.lua): init{log}, configure(slot_data, in_s3_session),
-- note_item(name, index), is_item(name), received(), last_extra(),
-- arm_backlog(), reset_received(), note_disconnected(), tick(world), reset(),
-- status().

local core = require("reconcile_core")
local C = require("constants")

local M = core.new({
    game = "spyro3",
    tag = "[EGGHUD]",
    kind = "eggs",
    item = "Spyro 3: Dragon Egg",
    save_type = C.eit.EIT_S3Egg,
    total = C.totals.eggs, -- shuffled non-boss eggs (boss eggs are EIT_S3Boss)
    ufunction = "debug - add s3 eggs",
    property = "debug extra s3 eggs",
    option_name = "egg_shuffle",
    option_label = "egg_shuffle",
})

return M
