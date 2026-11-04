-- Author: Tim Harrison
-- Created: 2026-09-26
-- Updated: 2026-10-23

-- Spec for client/ue4ss_mod/srt_bridge/Scripts/checks_drop.lua: the checkd
-- drop ingest + slot filter. Run from the client repo root:
-- lua tests/lua/test_drop_filter.lua

package.path = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "support/?.lua;" .. package.path
local H = require("harness")

-- The modules log through the global router, whose file path is the real bridge
-- dir: a silent stand-in keeps the spec off bridge.log (and its console).
package.preload["logger"] = function()
    local L = { cfg = {}, bridge_dir = "/nonexistent/" }
    local function noop() end
    L.log_info, L.log_warn, L.log_error, L.log_debug = noop, noop, noop, noop
    L.tagged = function(tag, sink)
        local function emit(msg)
            if sink then sink(tag .. " " .. tostring(msg)) end
        end
        return { info = emit, warn = emit, error = emit, debug = emit }
    end
    L.leveled = function(tag, opt)
        if type(opt) == "table" then return opt end
        return L.tagged(tag, type(opt) == "function" and opt or nil)
    end
    return L
end

local DROP = require("checks_drop")

local case, eq = H.test, H.eq

-- Test rig: a temp drop file per case; id_to_name = the slot's location set;
-- sent_checks = the shared ever-sent table; a stub ap capturing sends.
local tmpdir = os.tmpname()
os.remove(tmpdir)
os.execute('mkdir -p "' .. tmpdir .. '"')

--- Build a fresh module over a temp drop file: id_to_name = the slot's location
--- set; sent_checks = the shared ever-sent table; a stub ap capturing sends.
--- @param slot_ids table Location id -> name for this slot.
--- @param sent table|nil The shared sent-checks table.
--- @param gate_open boolean|nil False closes the connect gate.
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

-- Acknowledged checks: the server's checked_locations list is the authority for
-- "already sent on this seed", so the rig wires the module exactly as main.lua
-- does (the host's drop_checks sink and the shared sent_checks table) against a
-- fake library that carries that list.
local SD = { seed = "S1", slot = "P1" }
local SD2 = { seed = "S2", slot = "P1" }

local ap_state = require("state")
local AP = require("ap_client")
local send_calls = {}

--- Point the shared AP seam at a fake library carrying checked_locations.
--- @param checked table|nil The server's already-checked location ids.
local function fake_library(checked)
    send_calls = {}
    ap_state.ap = {
        checked_locations = checked or {},
        poll = function() end,
        LocationChecks = function(_, ids)
            send_calls[#send_calls + 1] = ids
            return true
        end,
    }
end

--- Build the module over the shared sent_checks table and the host's own sink.
local function fresh_host(slot_ids)
    ap_state.sent_checks = {}
    DROP.init({
        connect_gate = function() return true end,
        log = function() end,
        on_send = AP.handle.drop_checks,
        id_to_name = slot_ids,
        sent_checks = ap_state.sent_checks,
        check_path = tmpdir .. "/checks.json",
    })
    return ap_state.sent_checks
end

--- Add ids to the server's acknowledged list, as a LocationChecks reply would.
local function acknowledge(ids)
    for _, id in ipairs(ids) do
        ap_state.ap.checked_locations[#ap_state.ap.checked_locations + 1] = id
    end
end

case("a check the server already acknowledged is not sent", function()
    local slot = {[1001] = "x", [1002] = "y"}
    fake_library({1001})
    local sent = fresh_host(slot)
    AP.sync_checked(SD)
    eq(sent[1001], true, "loaded from the server's checked list")
    drop_file('{"seq":11,"checks":[1001,1002],"names":[]}')
    DROP.tick()
    eq(#send_calls, 1, "only the unacknowledged check is sent")
    eq(send_calls[1][1], 1002, "the new id")
    eq(file_exists(tmpdir .. "/checks.json"), false, "the drop is consumed")
end)

case("an acknowledgement from the server stops a drop repeating across boots", function()
    local slot = {[1001] = "x"}
    fake_library({})
    fresh_host(slot)
    AP.sync_checked(SD)
    drop_file('{"seq":12,"checks":[1001],"names":[]}')
    DROP.tick()
    eq(#send_calls, 1, "the first send")
    acknowledge({1001})
    -- a rebooted session holds nothing: the server's list is what stops it
    local sent = fresh_host(slot)
    AP.poll() -- the poll syncs the acknowledged list
    eq(sent[1001], true, "the acknowledgement reached the new session")
    drop_file('{"seq":13,"checks":[1001],"names":[]}')
    DROP.tick()
    eq(#send_calls, 1, "the acknowledged check is not sent again")
end)

case("a seed change starts from the new server list", function()
    local slot = {[1001] = "x"}
    -- the sync caches the list length, so a fresh list of a different length is
    -- what a reconnect looks like from inside ap_client
    fake_library({1001, 9999})
    local sent = fresh_host(slot)
    AP.sync_checked(SD)
    eq(sent[1001], true, "the first seed's acknowledgements")
    fake_library({}) -- the new room has acknowledged nothing yet
    AP.sync_checked(SD2)
    eq(sent[1001], nil, "the new seed's set starts empty")
    eq(next(sent), nil, "nothing carried over")
    drop_file('{"seq":14,"checks":[1001],"names":[]}')
    DROP.tick()
    eq(#send_calls, 1, "sent on the new seed")
    acknowledge({1001})
    AP.poll()
    eq(sent[1001], true, "and the new seed's own acknowledgement is honoured")
    drop_file('{"seq":15,"checks":[1001],"names":[]}')
    DROP.tick()
    eq(#send_calls, 1, "not sent twice on the new seed")
end)

ap_state.ap = nil

os.execute('rm -rf "' .. tmpdir .. '"')
H.finish()