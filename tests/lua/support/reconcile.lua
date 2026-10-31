-- Author: Tim Harrison
-- Created: 2026-10-21
-- Updated: 2026-10-23

-- Reconcile-core scenarios shared by the dragons / orbs / eggs_hud specs: the
-- fake gamestate behind the signed debug-extra drive, and the arming, baseline,
-- drift, garbage-readback, reconnect and reset cases every reconcile core must
-- pass. Each scenario takes the case number the spec reports, so the PASS lines
-- keep their per-spec numbering.

local H = require("harness")

local R = {}

--- Build a fake gamestate driving one debug-extra write path.
--- @param opts table map, write (the UFunction name), fallback (the property
---   the property-write fallback lands in).
--- @return table
function R.gamestate(opts)
    local g = {
        IsValid = function() return true end,
        map = opts.map,
        collected = 0,          -- what the readback reports (save records)
        extra_written = 0,      -- last value via the debug-extra UFunction
        ufunction_fails = false,
        readback_garbage = false,
    }
    g["current level"] = { ToString = function() return g.map end }
    g["get inventory collected count"] = function(_, _, _, out)
        out["Count"] = g.readback_garbage and "not-a-number" or g.collected
    end
    g[opts.write] = function(n)
        if g.ufunction_fails then error("ufunction gone") end
        g.extra_written = n
    end
    return g
end

--- Load a fresh module and its fake gamestate for one scenario.
--- @param ctx table Spec context: regions, module, map, write, fallback.
--- @param init table|nil Extra module init options; log defaults to H.collect.
--- @return table, table  The module and its fake gamestate.
function R.load(ctx, init)
    H.new_fixture(ctx.regions)
    H.clear_log()
    package.loaded[ctx.module] = nil
    local M = require(ctx.module)
    local g = R.gamestate({ map = ctx.map, write = ctx.write, fallback = ctx.fallback })
    init = init or {}
    init.log = init.log or H.collect
    M.init(init)
    return M, g
end

--- Arm a fresh module, deliver one item and let the baseline settle.
--- @param ctx table Spec context.
--- @return table, table  The module and its fake gamestate.
local function armed(ctx)
    local M, g = ctx.fresh()
    M.configure(ctx.sd(), true)
    M.note_item(ctx.item, 1)
    H.ticks(M, g, 3)
    return M, g
end

--- A vanilla session never arms and never writes.
--- @param ctx table Spec context.
--- @param n string Case number for the PASS lines.
function R.vanilla(ctx, n)
    local M, g = ctx.fresh()
    M.configure(ctx.vanilla_sd(), true)
    M.note_item(ctx.item, 1)
    H.ticks(M, g, 5)
    H.ok(M.status() == "disarmed", n .. ": vanilla never arms (status " .. M.status() .. ")")
    H.ok(g.extra_written == 0, n .. ": vanilla mode never writes")
end

--- A fresh session arms at configure, anchors a baseline and counts items.
--- @param ctx table Spec context.
--- @param n string Case number for the PASS lines.
function R.baseline(ctx, n)
    local M, g = ctx.fresh()
    M.configure(ctx.sd(), true)
    H.ok(M.status() == "no_baseline", n .. ": armed at slot-connect, waiting for baseline")
    H.ticks(M, g, 3) -- the readback anchors the baseline; the stable gate needs 2 ticks
    H.ok(g.extra_written == 0, n .. ": fresh seed writes 0 (received 0 - baseline 0)")
    M.note_item(ctx.item, 10)
    H.ticks(M, g, 1)
    H.ok(g.extra_written == 1, n .. ": received item drives extra -> 1")
end

--- Down-corrections write, and a broken UFunction falls back to the property.
--- @param ctx table Spec context.
--- @param n string Case number for the PASS lines.
function R.negative(ctx, n)
    local M, g = ctx.fresh()
    M.configure(ctx.sd(), true)
    H.ticks(M, g, 3) -- baseline 0
    M.note_item(ctx.item, 1)
    M.note_item(ctx.item, 2)
    H.ticks(M, g, 1)
    H.ok(g.extra_written == 2, n .. ": two " .. ctx.noun .. " -> extra 2")
    g.collected = 5 -- drift: the game has more records than we tracked
    H.ticks(M, g, 3) -- two agreeing reads re-sync the baseline
    H.ok(g.extra_written == -3, n .. ": negative extra drives the counter down (got " .. g.extra_written .. ")")
    g.ufunction_fails = true
    M.note_item(ctx.item, 3)
    H.ticks(M, g, 2)
    H.ok(g[ctx.fallback] == -2, n .. ": fallback property write lands when the UFunction errors")
end

--- Writes are idempotent and re-asserted once after a level change.
--- @param ctx table Spec context.
--- @param n string Case number for the PASS lines.
function R.reassert(ctx, n)
    local M, g = armed(ctx)
    H.ok(g.extra_written == 1, n .. ": first write")
    H.ok(H.count_logged("re-assert #", true) == 0, n .. ": no re-assert while the level holds")
    g.map = ctx.level2
    H.ticks(M, g, 4)
    local reassert = 0
    for _, l in ipairs(H.lines) do
        -- the re-assert TAG, not the "pending re-assert" invalidation line
        if l:find("extra write", 1, true) and l:find("re-assert #", 1, true) then
            reassert = reassert + 1
        end
    end
    H.ok(g.extra_written == 1, n .. ": re-assert after level change keeps the target")
    H.ok(reassert == 1, n .. ": re-assert logged once")
end

--- The stable-level gate writes nothing on the first tick or off-level.
--- @param ctx table Spec context.
--- @param n string Case number for the PASS lines.
function R.stable_gate(ctx, n)
    local M, g = ctx.fresh()
    M.configure(ctx.sd(), true)
    M.note_item(ctx.item, 1)
    H.ticks(M, g, 1) -- first tick: level_stabilizing
    H.ok(g.extra_written == 0, n .. ": no write during the first tick in a level")
    g.map = ctx.load_screen
    H.ticks(M, g, 2)
    H.ok(g.extra_written == 0, n .. ": " .. ctx.load_screen_msg)
end

--- A readback outside the domain never anchors a baseline.
--- @param ctx table Spec context.
--- @param n string Case number for the PASS lines.
function R.domain_guard(ctx, n)
    local M, g = ctx.fresh()
    M.configure(ctx.sd(), true)
    g.collected = ctx.out_of_domain -- out of domain (garbage readback)
    H.ticks(M, g, 4)
    H.ok(M.status() == "no_baseline", n .. ": out-of-domain readback never anchors")
    H.ok(g.extra_written == 0, n .. ": out-of-domain readback writes nothing")
end

--- One disagreeing read is ignored, two agreeing reads re-sync; garbage writes
--- nothing. Runs as two consecutive cases on one module instance.
--- @param ctx table Spec context.
--- @param n string Case number for the drift PASS lines.
--- @param n_garbage string Case number for the garbage PASS line.
function R.drift(ctx, n, n_garbage)
    local M, g = armed(ctx)
    H.ok(g.extra_written == 1, n .. ": baseline state before drift")
    g.collected = 4
    H.ticks(M, g, 1) -- first disagreeing read
    H.ok(g.extra_written == 1, n .. ": single disagreeing read ignored")
    H.ticks(M, g, 2) -- confirmation read, then the drive follows
    H.ok(g.extra_written == -3, n .. ": confirmed drift re-syncs and drives the counter down")
    g.readback_garbage = true
    H.ticks(M, g, 2)
    H.ok(g.extra_written == -3, n_garbage .. ": " .. ctx.garbage_msg)
end

--- reset_received zeros the count and the module re-arms on the next batch.
--- @param ctx table Spec context.
--- @param n string Case number for the PASS lines.
function R.reconnect(ctx, n)
    local M = ctx.fresh()
    M.configure(ctx.sd(), true)
    M.note_item(ctx.item, 1)
    M.note_item(ctx.item, 2)
    H.ok(M.received() == 2, n .. ": two " .. ctx.noun .. " counted")
    M.reset_received()
    H.ok(M.received() == 0, n .. ": reset_received zeros the count")
    M.note_item(ctx.item, 1) -- the backlog re-delivers the same index
    H.ok(M.received() == 1, n .. ": recount is exact-once (same index not double counted)")
    M.note_item(ctx.item, 3)
    H.ok(M.received() == 2, n .. ": new index counts once")
    M.note_disconnected()
    H.ok(M.status() == "disarmed", n .. ": note_disconnected disarms")
    M.arm_backlog()
    H.ok(M.status() ~= "disarmed", n .. ": arm_backlog re-arms after a batch")
end

--- reset() clears the engine state and a reconfigure re-anchors from scratch.
--- @param ctx table Spec context; before_reset(M, g, env) runs just before reset.
--- @param n string Case number for the PASS lines.
function R.reset(ctx, n)
    local M, g, env = ctx.fresh()
    M.configure(ctx.sd(), true)
    M.note_item(ctx.item, 1)
    H.ticks(M, g, 3)
    if ctx.before_reset then ctx.before_reset(M, g, env) end
    M.reset()
    H.reset_world()
    H.ok(M.received() == 0 and M.status() == "disarmed", n .. ": reset clears engine state (disarmed)")
    M.configure(ctx.sd(), true)
    M.note_item(ctx.item, 5)
    H.ticks(M, g, 3)
    H.ok(g.extra_written == 1, n .. ": reset + reconfigure re-anchors from scratch")
end

--- Run the cases every reconcile core shares, numbered 1..11.
--- @param ctx table Spec context.
function R.standard(ctx)
    R.vanilla(ctx, "1")
    R.baseline(ctx, "2")
    R.negative(ctx, "3")
    R.reassert(ctx, "4")
    R.stable_gate(ctx, "5")
    R.domain_guard(ctx, "6")
    R.drift(ctx, "7", "8")
    R.reconnect(ctx, "9")
    R.reset(ctx, "10")
    R.non_session(ctx, "11")
end

--- A non-session configure never arms.
--- @param ctx table Spec context.
--- @param n string Case number for the PASS lines.
function R.non_session(ctx, n)
    local M, g = ctx.fresh()
    M.configure(ctx.sd(), false)
    M.note_item(ctx.item, 1)
    H.ticks(M, g, 5)
    H.ok(M.status() == "disarmed", n .. ": no arm outside a " .. ctx.game_name .. " session")
end

return R
