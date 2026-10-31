-- Author: Tim Harrison
-- Created: 2026-09-26
-- Updated: 2026-10-23

-- Spec for client/ue4ss_mod/srt_bridge/Scripts/checks_drop.lua: the checkd
-- drop ingest + slot filter. Run from the client repo root:
-- lua tests/lua/test_drop_filter.lua

package.path = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "support/?.lua;" .. package.path
local H = require("harness")

local DROP = require("checks_drop")

local case, eq = H.test, H.eq

-- Test rig: a temp drop file per case; id_to_name = the slot's location set;
-- sent_checks = the shared ever-sent table; a stub ap capturing sends.
local tmpdir = os.tmpname()
os.remove(tmpdir)
os.execute('mkdir -p "' .. tmpdir .. '"')

local function fresh(slot_ids, sent, gate_open)
    local sent_checks = sent or {}
    local state = {sends = {}, logs = {}}
    state.clear_sent = function() for k in pairs(sent_checks) do sent_checks[k] = nil end end
    DROP.init({
        connect_gate = function() return gate_open ~= false end,
        log = function(l) state.logs[#state.logs + 1] = l end,
        on_send = function(ids)
            state.sends[#state.sends + 1] = ids
            return true
        end,
        id_to_name = slot_ids,
        sent_checks = sent_checks,
        check_path = tmpdir .. "/checks.json",
    })
    return state, sent_checks
end

local function drop_file(text)
    local f = assert(io.open(tmpdir .. "/checks.json", "w"))
    f:write(text)
    f:close()
end

local function file_exists(path)
    local f = io.open(path, "r")
    if f then f:close() return true end
    return false
end

case("drop with all ids in the slot is sent whole", function()
    local slot = {[1001] = "Spyro 1: Artisans: Free Nestor", [1002] = "Spyro 1: Stone Hill: Egg"}
    local state = fresh(slot)
    drop_file('{"seq":1,"checks":[1001,1002],"names":["Spyro 1: Artisans: Free Nestor","Spyro 1: Stone Hill: Egg"]}')
    DROP.tick()
    eq(#state.sends, 1, "send count")
    eq(#state.sends[1], 2, "sent ids")
    eq(state.sends[1][1], 1001, "first id")
    eq(state.sends[1][2], 1002, "second id")
end)

case("ids not in this slot are filtered out of a mixed drop", function()
    local slot = {[2001] = "Spyro 2: Glimmer: 25% Gems"}
    local state = fresh(slot)
    -- 3001/3002 = gem-check ids this slot disabled (locations.json still has them)
    drop_file('{"seq":2,"checks":[3001,2001,3002],"names":[]}')
    DROP.tick()
    eq(#state.sends, 1, "send count")
    eq(#state.sends[1], 1, "sent ids")
    eq(state.sends[1][1], 2001, "kept id")
    local joined = table.concat(state.logs, "\n")
    eq(joined:find("skipped 2 not in this slot", 1, true) ~= nil, true, "skip log line")
end)

case("a drop whose ids are all disabled is consumed without sending", function()
    local slot = {[1001] = "Spyro 1: Artisans: Free Nestor"}
    local state = fresh(slot)
    drop_file('{"seq":3,"checks":[9001,9002],"names":[]}')
    DROP.tick()
    eq(#state.sends, 0, "no sends")
    eq(file_exists(tmpdir .. "/checks.json"), false, "drop consumed")
    local joined = table.concat(state.logs, "\n")
    eq(joined:find("not in this slot's locations", 1, true) ~= nil, true, "filter log line")
end)

case("already-sent ids are not sent twice", function()
    local slot = {[1001] = "x", [1002] = "y"}
    local state = fresh(slot, {[1001] = true})
    drop_file('{"seq":4,"checks":[1001,1002],"names":[]}')
    DROP.tick()
    eq(#state.sends, 1, "send count")
    eq(#state.sends[1], 1, "only the unsent id")
    eq(state.sends[1][1], 1002, "the unsent id")
end)

case("empty batch is consumed silently", function()
    local slot = {}
    local state = fresh(slot)
    drop_file('{"seq":5,"checks":[],"names":[]}')
    DROP.tick()
    eq(#state.sends, 0, "no sends")
    eq(file_exists(tmpdir .. "/checks.json"), false, "drop consumed")
end)

case("stale seq is consumed silently", function()
    local slot = {[1001] = "x"}
    local state = fresh(slot)
    drop_file('{"seq":9,"checks":[1001],"names":[]}')
    DROP.tick()
    eq(#state.sends, 1, "first send")
    drop_file('{"seq":9,"checks":[1001],"names":[]}')
    DROP.tick()
    eq(#state.sends, 1, "stale drop not sent")
    eq(file_exists(tmpdir .. "/checks.json"), false, "stale drop consumed")
end)

case("failed send leaves the drop for retry", function()
    local slot = {[1001] = "x"}
    local sent, sends = {}, {}
    local accept = false
    DROP.init({
        connect_gate = function() return true end,
        log = function() end,
        on_send = function(ids)
            if not accept then return false end
            sends[#sends + 1] = ids
            return true
        end,
        id_to_name = slot,
        sent_checks = sent,
        check_path = tmpdir .. "/checks.json",
    })
    drop_file('{"seq":6,"checks":[1001],"names":[]}')
    DROP.tick()
    eq(#sends, 0, "failing send recorded nothing")
    eq(file_exists(tmpdir .. "/checks.json"), true, "drop kept for retry")
    accept = true
    DROP.tick()
    eq(#sends, 1, "retry sent the pending id")
    eq(sends[1][1], 1001, "the retried id")
    eq(sent[1001], true, "sent_checks marked on success")
    eq(file_exists(tmpdir .. "/checks.json"), false, "drop consumed on success")
end)

case("parse errors quarantine after 3 consecutive", function()
    local slot = {[1001] = "x"}
    local state = fresh(slot)
    drop_file("not json at all")
    DROP.tick()
    DROP.tick()
    eq(file_exists(tmpdir .. "/checks.json"), true, "kept after 2 errors")
    DROP.tick()
    eq(file_exists(tmpdir .. "/checks.json"), false, "quarantined")
    eq(file_exists(tmpdir .. "/checks.json.bad"), true, "renamed to .bad")
end)

case("closed gate: nothing is read or sent", function()
    local slot = {[1001] = "x"}
    local state = fresh(slot, nil, false)
    drop_file('{"seq":7,"checks":[1001],"names":[]}')
    DROP.tick()
    eq(#state.sends, 0, "no sends")
    eq(file_exists(tmpdir .. "/checks.json"), true, "drop untouched")
end)

case("reset clears the stale-seq guard", function()
    local slot = {[1001] = "x"}
    local state = fresh(slot)
    drop_file('{"seq":10,"checks":[1001],"names":[]}')
    DROP.tick()
    eq(#state.sends, 1, "first send")
    -- main.lua's reset_session_state clears sent_checks and CHECKSDROP.reset()
    -- together, so a new session can re-send from a clean slate
    DROP.reset()
    state.clear_sent()
    drop_file('{"seq":10,"checks":[1001],"names":[]}')
    DROP.tick()
    eq(#state.sends, 2, "same seq sent again after reset")
end)

os.execute('rm -rf "' .. tmpdir .. '"')
H.finish()