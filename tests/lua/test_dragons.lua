-- Author: Tim Harrison
-- Created: 2026-09-26
-- Updated: 2026-10-21

-- Stub-based spec for client/ue4ss_mod/srt_bridge/Scripts/spyro1/dragons.lua.
-- Fakes the UE4SS surfaces the module touches: Collectable_Dragon_C actors
-- (FindAllOf), the gamestate's current-level string + inventory readback +
-- debug-extra write UFunctions, and the send_checks seam (main.lua's
-- ap:LocationChecks). Covers the dragon watcher (identity candidates, named
-- checks), the signed debug_extra_dragons reconcile drive shared with the other
-- reconcile cores (support/reconcile.lua), and the dragon-only cases in
-- between.
-- Run from the client repo root: lua tests/lua/test_dragons.lua

package.path = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "support/?.lua;" .. package.path
local H = require("harness")
local R = require("reconcile")

-- Artisans holds most cases, the other two cover the watcher and re-assert.
local REGIONS = {
    ["/LS101_ArtisansHome/Maps/"] = "Artisans",
    ["/LS105_DarkHollow/Maps/"] = "Dark Hollow",
    ["/LS103_Toasty/Maps/"] = "Toasty",
}
local NAME_TO_ID = {
    ["Spyro 1: Artisans: Free Nestor"] = 100011,
    ["Spyro 1: Dark Hollow: Free Bargle"] = 100031,
    ["Spyro 1: Toasty: Free Todor"] = 100041,
}
local SOURCE = H.scripts .. "spyro1/dragons.lua"

local ftext = H.fstring

-- fake dragon actors (FindAllOf's current list)
local dragon_actors = {}
H.find_actors("Collectable_Dragon_C", function() return dragon_actors end)

-- GetChildActorName is void with an FString out-param (SDK
-- Collectable_Dragon.hpp) and string out-params crash UE4SS: the module must
-- never call it. The fake records calls so case 16 can assert that.
local child_name_calls = 0
local function make_dragon(name, collected, addr)
    return {
        IsValid = function() return true end,
        GetAddress = function() return addr or 0x1234 end,
        ["Name"] = ftext(name),
        ["Collected_Dragons"] = collected == true,
        ["PhasmidObjectSave"] = { GetSaveParam = function(self, i, j, out)
            out.paramName = ftext(name)
        end },
        GetChildActorName = function() child_name_calls = child_name_calls + 1 end,
    }
end

local ctx = {
    module = "spyro1.dragons",
    regions = REGIONS,
    write = "debug - add dragons",
    item = "Spyro 1: Dragon",
    noun = "dragons",
    fallback = "debug_extra_dragons",
    map = "/LS101_ArtisansHome/Maps/",
    level2 = "/LS103_Toasty/Maps/",
    load_screen = "/LS102_SomeUnknown/Maps/",
    load_screen_msg = "no write on an unknown/load-screen level",
    garbage_msg = "garbage readback writes nothing and does not corrupt state",
    sd = function() return { games = { spyro1 = { options = { dragon_shuffle = 1 } } } } end,
    vanilla_sd = function() return { games = { spyro1 = { options = { dragon_shuffle = 0 } } } } end,
}

--- Load a fresh module, gamestate and send seam for one scenario.
--- @return table, table, table  The module, its fake gamestate and the send env.
function ctx.fresh()
    local sent_checks = {}
    local send_ok, send_err, send_calls = true, nil, 0
    local M, g = R.load(ctx, {
        regions = REGIONS,
        loc_id = function(n) return NAME_TO_ID[n] end,
        log_sent = function(id) H.collect("Sent: " .. id) end,
        sent_checks = sent_checks,
        send_checks = function()
            send_calls = send_calls + 1
            if send_ok then return true, nil end
            return false, send_err or "boom"
        end,
    })
    dragon_actors = {}
    return M, g, {
        sent_checks = sent_checks,
        set_send = function(ok, err) send_ok, send_err = ok, err end,
        sends = function() return send_calls end,
    }
end

R.vanilla(ctx, "1")
R.baseline(ctx, "2")
R.negative(ctx, "3")
R.reassert(ctx, "4")
R.stable_gate(ctx, "5")

local M, g, env
local source = H.read_file(SOURCE)

-- 6. local rescue: watcher sees uncollected->collected and bumps save_collected
M, g = ctx.fresh()
M.configure(ctx.sd(), true)
M.note_item(ctx.item, 1)
H.ticks(M, g, 3) -- extra=1 written
local rescued = make_dragon("Nestor", false)
dragon_actors = { rescued }
H.ticks(M, g, 2) -- first sight: state cached as false (no rescue note)
rescued["Collected_Dragons"] = true
H.ticks(M, g, 1)
H.ok(M.status():find("save=1", 1, true) ~= nil, "6: local rescue bumps save_collected")
H.ok(g.extra_written == 0, "6: computed self-corrects (received 1 - save 1 = 0)")

-- 7. named check: failed send leaves sent_checks unmarked; catch-up sends later
M, g, env = ctx.fresh()
M.configure(ctx.sd(), true)
local d1 = make_dragon("Nestor", false)
dragon_actors = { d1 }
env.set_send(false, "socket gone")
H.ticks(M, g, 3) -- actor cached as false
d1["Collected_Dragons"] = true
H.ticks(M, g, 1)
H.ok(env.sends() >= 1, "7: send attempted")
H.ok(next(env.sent_checks) == nil, "7: failed send does not mark sent_checks")
env.set_send(true)
local d1b = make_dragon("Nestor", true, 0x9999) -- fresh instance (address recycling)
dragon_actors = { d1b }
H.ticks(M, g, 2)
H.ok(env.sent_checks[100011] == true, "7: catch-up send after a failed attempt marks sent_checks")

-- 8. duplicate actor re-fire sends nothing
H.ticks(M, g, 2)
H.ok(env.sends() == 2, "8: already-sent actor re-fires nothing (sends=" .. env.sends() .. ")")

-- 9. unresolvable identity never sends; WARN once per actor
M, g, env = ctx.fresh()
M.configure(ctx.sd(), true)
local d9 = make_dragon("UnknownDragon", false, 0x4242)
d9["PhasmidObjectSave"] = { GetSaveParam = function() end }
dragon_actors = { d9 }
H.ticks(M, g, 3)
d9["Collected_Dragons"] = true
H.ticks(M, g, 1)
H.ok(H.count_logged("WARN unresolved dragon identity", true) == 1,
    "9: unresolved identity warns once (got " .. H.count_logged("WARN unresolved dragon identity", true) .. ")")
H.ok(next(env.sent_checks) == nil, "9: nothing sent for an unresolvable identity")

-- 10. "Fairy" and generic actor names are rejected as identity candidates
M, g, env = ctx.fresh()
M.configure(ctx.sd(), true)
local d10 = make_dragon("Fairy", false, 0x5151)
dragon_actors = { d10 }
H.ticks(M, g, 3)
d10["Collected_Dragons"] = true
H.ticks(M, g, 1)
H.ok(next(env.sent_checks) == nil, "10: Fairy candidate never sends")

-- 11. identity decoding retained: the UTF-16LE decode path survives the move
H.ok(source:find("UTF%-16LE") ~= nil, "11: UTF-16 decode retained in identity path")
H.ok(source:find("Collectable_Dragon_C_%d+$", 1, true) ~= nil, "11: generic-name rejection present")
H.ok(source:find('s == "Fairy"') ~= nil, "11: Fairy rejection present")

R.drift(ctx, "12", "13")
R.reconnect(ctx, "14")

-- 15. reset() clears engine state + caches but not the shared sent_checks
ctx.before_reset = function(_, _, e) e.sent_checks[100011] = true end
R.reset(ctx, "15")
ctx.before_reset = nil
M, g = ctx.fresh()
M.configure(ctx.vanilla_sd(), true)
M.note_item(ctx.item, 1)
H.ticks(M, g, 2)
H.ok(g.extra_written == 0, "15: reconfigured vanilla never writes")

-- 16. identity candidates: save param first, then DialogueTable.RowName,
-- then display Name; GetChildActorName is never called
child_name_calls = 0
M, g, env = ctx.fresh()
M.configure(ctx.sd(), true)
local d16 = make_dragon("Fairy", false, 0x6161)
d16["PhasmidObjectSave"] = { GetSaveParam = function() error("no save component") end }
d16["DialogueTable"] = { RowName = ftext("CNS1101_Nestor") }
dragon_actors = { d16 }
H.ticks(M, g, 3)
d16["Collected_Dragons"] = true
H.ticks(M, g, 1)
H.ok(env.sent_checks[100011] == true, "16: DialogueTable.RowName resolves when the save param fails")
local d16b = make_dragon("Nestor", true, 0x7171)
d16b["PhasmidObjectSave"] = { GetSaveParam = function(self, i, j, out) out.paramName = ftext("None") end }
M, g, env = ctx.fresh()
M.configure(ctx.sd(), true)
dragon_actors = { d16b }
H.ticks(M, g, 3)
H.ok(env.sent_checks[100011] == true, "16: display Name is the last-resort candidate")
H.ok(child_name_calls == 0, "16: GetChildActorName is never called (got " .. child_name_calls .. ")")
H.ok(source:find("GetChildActorName%(") == nil, "16: no GetChildActorName call in the module source")

H.finish()
