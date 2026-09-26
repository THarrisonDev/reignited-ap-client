-- abilities (Spyro 2): apply received Money Bags ability items and neutralize
-- vanilla Money Bags purchases while the ability is unowned in AP, via the
-- shared inventory_grants_core.lua (levers, threading and design notes there).
-- Spyro 2 shape:
--   * EIT_Climbing 30, EIT_Headbash 31, EIT_Swimming 32; EIT_Superflame (33)
--     is FORBIDDEN here: it is the Dragon Shores 100% completion reward,
--     never a Money Bags purchase
--   * there is no Money Bags payment surface in the SDK dump (the NPC is
--     Blueprint-only): paying early flips the flag on, the reconcile writes
--     it back off, and the gems may still be spent — the WARN says why
--   * slot data: sd.games.spyro2.options.moneybags_abilities (1 or "sanity")
--
-- API (main.lua): init{log, regions}, configure(slot_data) on slot connect,
-- note_item(name, index) per received item, tick(gamestate) from the poll
-- loop, status() for the heartbeat.

local core = require("inventory_grants_core")

return core.new({
    tag = "[ABILITIES]",
    items = {
        ["Spyro 2: Swim Ability"] = 32,
        ["Spyro 2: Climb Ability"] = 30,
        ["Spyro 2: Headbash Ability"] = 31,
    },
    option = function(sd)
        local s2 = sd and type(sd.games) == "table" and sd.games.spyro2 or nil
        local val = s2 and type(s2.options) == "table" and s2.options.moneybags_abilities
        return (val == 1) or (val == "sanity")
    end,
    flag = "sanity",
    short = function(name) return name:match("^Spyro 2: ([%a]+) Ability$") end,
    disabled = "ability items disabled",
    revoked = "not received; vanilla purchase neutralized",
    revoke_stays = "(won't retry this session; the purchase stays until it lands once)",
    early = " purchased without the AP item - the purchase will be reverted until the item arrives" ..
        " (gems may be spent; the item may live in another world)",
})
