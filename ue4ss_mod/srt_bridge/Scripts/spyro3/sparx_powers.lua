-- Author: Tim Harrison
-- Created: 2026-09-26
-- Updated: 2026-10-23

-- sparx_powers (Spyro 3): apply received Sparx power items and neutralize the
-- vanilla Sparx realm completion reward while the power is unowned in AP, via
-- the shared inventory_grants_core.lua (levers and threading there).
-- EIT_SparxPower_GemFinder (46) is deliberately absent: the gem radar ships
-- default-on and is not randomized.

local core = require("inventory_grants_core")
local C = require("constants")
local O = require("option")

local SHORT = {
    ["Spyro 3: Sparx Gem Collect Range"] = "GemCollectRange",
    ["Spyro 3: Sparx Extra Hit Point"] = "ExtraHP",
    ["Spyro 3: Sparx Chest Breaking"] = "ChestBreaking",
}

return core.new({
    tag = "[SPARX]",
    items = {
        ["Spyro 3: Sparx Gem Collect Range"] = C.eit.EIT_SparxPower_GemCollectRange,
        ["Spyro 3: Sparx Extra Hit Point"] = C.eit.EIT_SparxPower_ExtraHP,
        ["Spyro 3: Sparx Chest Breaking"] = C.eit.EIT_SparxPower_ChestBreaking,
    },
    option = function(sd, log)
        local s3 = sd and type(sd.games) == "table" and sd.games.spyro3 or nil
        local val = s3 and type(s3.options) == "table" and s3.options.sparx_powers
        return O.flag(val, "sparx_powers", log)
    end,
    flag = "powers",
    short = function(name) return SHORT[name] end,
    disabled = "Sparx power items disabled",
    revoked = "not received; vanilla realm reward neutralized",
    revoke_stays = "(won't retry this session; the realm reward stays until it lands once)",
    early = " granted by completing the Sparx realm without the AP item - the power will be" ..
        " removed until the item arrives (the item may live in another world)",
})
