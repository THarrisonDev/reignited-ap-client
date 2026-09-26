-- sparx_powers (Spyro 3): apply received Sparx power items and neutralize the
-- vanilla Sparx realm completion reward while the power is unowned in AP, via
-- the shared inventory_grants_core.lua (levers, threading and design notes
-- there). Spyro 3 shape:
--   * EIT_SparxPower_GemCollectRange 45 (Crawdad Farm), EIT_SparxPower_ExtraHP
--     47 (Starfish Reef), EIT_SparxPower_ChestBreaking 48 (Bugbot Factory);
--     EIT_SparxPower_GemFinder (46) is FORBIDDEN here: the gem radar ships
--     default-on and is not randomized
--   * slot data: sd.games.spyro3.options.sparx_powers (0/1)
--
-- API (main.lua): init{log, regions}, configure(slot_data) on slot connect,
-- note_item(name, index) per received item, tick(gamestate) from the poll
-- loop, status() for the heartbeat.

local core = require("inventory_grants_core")

local SHORT = {
    ["Spyro 3: Sparx Gem Collect Range"] = "GemCollectRange",
    ["Spyro 3: Sparx Extra Hit Point"] = "ExtraHP",
    ["Spyro 3: Sparx Chest Breaking"] = "ChestBreaking",
}

return core.new({
    tag = "[SPARX]",
    items = {
        ["Spyro 3: Sparx Gem Collect Range"] = 45,
        ["Spyro 3: Sparx Extra Hit Point"] = 47,
        ["Spyro 3: Sparx Chest Breaking"] = 48,
    },
    option = function(sd)
        local s3 = sd and type(sd.games) == "table" and sd.games.spyro3 or nil
        local val = s3 and type(s3.options) == "table" and s3.options.sparx_powers
        return val == 1 or val == true
    end,
    flag = "powers",
    short = function(name) return SHORT[name] end,
    disabled = "Sparx power items disabled",
    revoked = "not received; vanilla realm reward neutralized",
    revoke_stays = "(won't retry this session; the realm reward stays until it lands once)",
    early = " granted by completing the Sparx realm without the AP item - the power will be" ..
        " removed until the item arrives (the item may live in another world)",
})
