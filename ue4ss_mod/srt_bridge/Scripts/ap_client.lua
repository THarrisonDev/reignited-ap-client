-- Author: Tim Harrison
-- Created: 2026-10-16
-- Updated: 2026-10-16

-- ap_client: the bridge's single AP connection — the client, its handlers, the
-- verbs modules use to reach the server, and the send/receive log lines. It
-- reads and writes state.ap / state.connected; session.lua opens and closes it
-- and watch.lua polls it.

local U = require("util")
local L = require("logger")
local SESSION = require("session_gate")
local state = require("state")

local log_info, log_error, log_debug = L.log_info, L.log_error, L.log_debug
local CFG = L.cfg
local safe = U.safe

-- A missing library is main's FATAL to report, not this module's.
local OK, AP = pcall(require, "lua-apclientpp")

local M = {}

M.available = OK
M.load_error = OK and nil or tostring(AP)

local client_version = { 0, 6, 7 }
local items_handling = 7

-- ---------------------------------------------------------------------------
-- Verbs
-- ---------------------------------------------------------------------------
-- The contract every verb here keeps, and the only way modules reach the
-- server (HOST.ap — see the handle at the end of this file):
--
--   * one return value, never a pcall tuple;
--   * a send returns a strict boolean — "the library queued it";
--   * a verb never throws, and a failed send is logged here, so no caller has
--     to unwrap an error to report one.
--
-- The connection lifecycle (connect/close/poll) is deliberately not on the
-- handle: only session.lua and watch.lua may drive it.

--- Run one AP send, returning whether the library queued it. The binding returns
--- a strict boolean (ue4ss_mod/api/lua-apclientpp.lua); only an explicit false is
--- a refusal, so a binding that returns nothing is not read as a failure.
--- @param what string Label for the failure line.
--- @param fn function The library call.
--- @return boolean
local function send(what, fn)
  if not state.ap then
    return false
  end
  local ok, queued = pcall(fn)
  if not ok then
    log_debug(what .. " failed: " .. tostring(queued))
    return false
  end
  if queued == false then
    log_debug(what .. " not queued (invalid state)")
    return false
  end
  return true
end

-- Assigned with the log lines below; drop_checks logs a line per sent id.
local render_sent

--- Return whether the AP socket is up.
function M.connected()
  return state.connected
end

--- Return whether this save may send checks.
function M.can_check()
  return state.connected and state.ap ~= nil and not state.checks_blocked
end

--- Send location checks, returning whether they were queued.
--- @return boolean
function M.checks(ids)
  return send("LocationChecks", function()
    state.ap:LocationChecks(ids)
  end)
end

--- Send a check drop's checks, then log the "Sent:" lines. Returns whether they
--- were queued.
--- @return boolean
function M.drop_checks(ids)
  if not M.checks(ids) then
    return false
  end
  for _, id in ipairs(ids) do
    log_info(render_sent(id))
  end
  return true
end

--- Bounce data to slots and/or tags, mirroring APClient:Bounce(data, games,
--- slots, tags). Returns whether the server took it.
--- @return boolean
function M.bounce(data, tags, slots)
  return send("Bounce", function()
    return state.ap:Bounce(data, nil, slots, tags)
  end)
end

--- Report goal completion, returning whether the server took it.
--- @return boolean
function M.goal()
  return send("StatusUpdate(GOAL)", function()
    return state.ap:StatusUpdate(AP.ClientStatus.GOAL)
  end)
end

--- Resolve an AP item id to a name through the loaded data package.
function M.item_name(item_id)
  if not state.ap then
    return nil
  end
  return safe(function()
    return state.ap:get_item_name(item_id, CFG.game)
  end, nil)
end

--- Return the server's clock as seconds.
function M.server_time()
  return safe(function()
    return state.ap:get_server_time()
  end, 0)
end

--- Return this slot's name.
function M.slot_name()
  return safe(function()
    return state.ap:get_slot()
  end, "?")
end

--- Return this slot's player number.
function M.player_number()
  return safe(function()
    return state.ap:get_player_number()
  end, nil)
end

--- Return whether the AP data package has loaded.
function M.data_package_valid()
  return safe(function()
    return state.ap:is_data_package_valid()
  end, false)
end

-- ---------------------------------------------------------------------------
-- Log lines
-- ---------------------------------------------------------------------------
-- NetworkItem on ReceivedItems: player is the slot whose world held the item,
-- location is where in that world (<= 0 for server grants and starting items).
--- Return where a received item was found, or nil when the server sent it.
local function origin(info)
  if type(info.location) ~= "number" or info.location <= 0 then return nil end
  local game = safe(function()
    return state.ap:get_player_game(info.player)
  end, nil)
  return safe(function()
    return state.ap:get_location_name(info.location, game)
  end, nil)
end

--- Return the alias of the player a received item came from.
local function sender(info)
  if info.player == 0 then return "the server" end
  return safe(function()
    return state.ap:get_player_alias(info.player)
  end, "player " .. tostring(info.player))
end

--- Build the log line describing where a received item came from.
--- @param info table NetworkItem.
--- @param iname string Resolved item name.
--- @return string
local function received_line(info, iname)
  local line = "Received: " .. iname
  local where = origin(info)
  local me = safe(function()
    return state.ap:get_player_number()
  end, nil)
  if info.player == me then
    if where == nil then return line end
    return line .. " (found at " .. where .. ")"
  end
  local at = where and (" at " .. where) or ""
  return line .. " from " .. sender(info) .. at
end

--- Build the log/banner line for a sent location check.
--- @return string
render_sent = function(id)
  local line = "Sent: " .. (state.id_to_name[id] or ("location " .. id))
  local s = state.scouted[id]
  if not s then
    return line
  end
  if s.to then
    state.each("note_sent", "To " .. s.to .. ": " .. s.item)
    return line .. " -> " .. s.item .. " for " .. s.to
  end
  return line .. " -> your " .. s.item
end

--- Log one sent location check.
function M.sent_line(id)
  log_info(render_sent(id))
end

-- ---------------------------------------------------------------------------
-- Handlers
-- ---------------------------------------------------------------------------
--- Handle room info by connecting the slot.
local function on_room_info()
  log_debug("== room info ==")
  local ok, err = pcall(function()
    state.ap:ConnectSlot(CFG.slot, CFG.password, items_handling, { "Lua-APClientPP", "DeathLink" }, client_version)
  end)
  log_debug("ConnectSlot: ok=" .. tostring(ok) .. " err=" .. tostring(err))
  if not ok then
    log_error("could not connect slot " .. CFG.slot .. ": " .. tostring(err))
  end
end

--- Handle slot connect: reset stale per-seed state, load location names, scout
--- every location and configure every module with the slot data.
--- @param sd table Slot data.
local function on_slot_connected(sd)
  log_info("Connected to " .. CFG.host .. " as " .. CFG.slot)
  -- A reconnect to a different seed makes the session check state stale.
  for k in pairs(state.sent_checks) do
    state.sent_checks[k] = nil
  end
  -- A new seed re-uses item indexes for different items, so the per-index
  -- once-guard must reset with the check state.
  state.processed_indices = {}
  -- The recount must be exact once: a mid-session reconnect re-delivers the
  -- whole backlog, and without the reset every item counts twice and the signed
  -- drive over-writes the counter.
  state.each("reset_received")
  local n2i = sd.locationNameToId or {}
  local n = 0
  for k, v in pairs(n2i) do
    state.name_to_id[k] = v
    state.id_to_name[v] = k
    n = n + 1
  end
  log_debug("locationNameToId loaded: " .. n .. " entries")
  -- Scout every location once so "Sent:" lines can name the item and receiver.
  state.scouted = {}
  local scout_ids = {}
  for id in pairs(state.id_to_name) do
    scout_ids[#scout_ids + 1] = id
  end
  if #scout_ids > 0 then
    local ok, err = pcall(function()
      state.ap:LocationScouts(scout_ids, 0)
    end)
    log_debug("LocationScouts(" .. #scout_ids .. "): ok=" .. tostring(ok) .. " err=" .. tostring(err))
  end
  local blocked = not SESSION.is_included(sd, state.session_game)
  if blocked and not state.checks_blocked then
    log_info(
      "This slot doesn't include "
        .. SESSION.game_name(state.session_game)
        .. " - checks from this save won't be sent"
    )
  end
  state.checks_blocked = blocked
  for _, entry in ipairs(state.mods) do
    state.call(entry, "configure", sd, state.watches(entry))
  end
  state.connected = true
end

-- NetworkItem on LocationInfo: player is the receiver of the item.
--- Cache the connect-time LocationScouts reply, naming each check's item and
--- receiver.
local function on_location_info(items)
  local me = safe(function()
    return state.ap:get_player_number()
  end, nil)
  local n = 0
  for _, info in ipairs(items or {}) do
    local game = safe(function()
      return state.ap:get_player_game(info.player)
    end, nil)
    state.scouted[info.location] = {
      item = safe(function()
        return state.ap:get_item_name(info.item, game)
      end, "?"),
      to = info.player ~= me and safe(function()
        return state.ap:get_player_alias(info.player)
      end, "player " .. tostring(info.player)) or nil,
    }
    n = n + 1
  end
  log_debug("location scouts: cached " .. n .. " locations")
end

--- Log a ReceivedItems batch, feed the data-package backlog, re-arm the
--- reconciles and hand the batch to goal watch.
local function on_items_received(received)
  local names = {}
  local counts = {} -- reconcile entry -> matching items in this batch
  for _, info in ipairs(received or {}) do
    local iname = safe(function()
      return state.ap:get_item_name(info.item, CFG.game)
    end, "?")
    names[#names + 1] = iname
    log_info(received_line(info, iname))
    state.each("note", iname, info.index, info.item)
    for _, entry in ipairs(state.reconciled) do
      if state.call(entry, "is_item", iname) then
        counts[entry] = (counts[entry] or 0) + 1
      end
    end
  end
  log_debug("items received: " .. #names .. " (" .. table.concat(names, ", ") .. ")")
  -- Reconnect: the cumulative backlog recount re-arms the reconciles.
  state.each("arm_backlog")
  for _, entry in ipairs(state.reconciled) do
    if (counts[entry] or 0) > 0 then
      log_debug(
        string.format(
          "[RECONCILE] %s items this batch: %d (running received=%s, last_extra=%s)",
          entry.tag,
          counts[entry],
          tostring(state.call(entry, "received")),
          tostring(state.call(entry, "last_extra"))
        )
      )
    end
  end
  state.each("note_batch", received)
end

-- The library retries a dead server every few seconds, so only a drop from a
-- live session is worth showing the player.
--- Log a socket error at debug level.
local function on_socket_error(msg)
  log_debug("socket error: " .. tostring(msg))
end

--- Handle a socket drop, showing the player only a drop from a live session.
local function on_socket_disconnected()
  if state.connected then
    state.connected = false
    state.each("note_disconnected")
    log_error("Disconnected from " .. CFG.host .. " (reconnecting)")
  else
    log_debug("socket disconnected")
  end
end

--- Log a socket connect at debug level.
local function on_socket_connected()
  log_debug("socket connected")
end

--- Log the server's reason for refusing this slot.
local function on_slot_refused(reasons)
  local why = type(reasons) == "table" and table.concat(reasons, ", ") or tostring(reasons)
  log_error("Server refused slot " .. CFG.slot .. ": " .. why)
end

--- Log the number of acknowledged location checks.
local function on_location_checked(locs)
  log_debug("location checked ack: " .. #locs)
end

--- Log a server print message at debug level.
local function on_print(msg)
  log_debug("server print: " .. tostring(msg))
end

-- ---------------------------------------------------------------------------
-- Connection
-- ---------------------------------------------------------------------------
--- Construct the AP client and wire every handler. The client auto-connects.
function M.connect()
  local ok, inst = pcall(function()
    return AP("", CFG.game, CFG.host)
  end)
  if not ok then
    log_error("FATAL ctor: " .. tostring(inst))
    return
  end
  state.ap = inst
  log_debug("AP client constructed (async thread) -> " .. CFG.host)

  state.ap:set_socket_connected_handler(on_socket_connected)
  state.ap:set_socket_error_handler(on_socket_error)
  state.ap:set_socket_disconnected_handler(on_socket_disconnected)
  state.ap:set_room_info_handler(on_room_info)
  state.ap:set_slot_connected_handler(on_slot_connected)
  state.ap:set_slot_refused_handler(on_slot_refused)
  state.ap:set_location_checked_handler(on_location_checked)
  state.ap:set_location_info_handler(on_location_info)
  state.ap:set_items_received_handler(on_items_received)
  state.ap:set_print_handler(on_print)

  -- The shipped DLL may lack set_bounced_handler. Without it, incoming
  -- DeathLinks never arrive but our own deaths still bounce.
  if type(state.ap.set_bounced_handler) == "function" then
    state.ap:set_bounced_handler(function(cmd)
      safe(function()
        state.each("on_bounced", cmd)
      end)
    end)
    log_debug("bounced handler wired")
  else
    log_debug("bounced handler unavailable (DLL build); incoming DeathLinks inactive")
  end

  -- The backlog replay runs once the data package is valid. Prefer the
  -- library's changed handler; the shipped DLL may lack it, in which case the
  -- poll loop's tick is the fallback (at most one poll late).
  if type(state.ap.set_data_package_changed_handler) == "function" then
    state.ap:set_data_package_changed_handler(function()
      safe(function()
        state.call(state.mod("data_pkg"), "tick", M.data_package_valid())
      end)
    end)
    log_debug("data package changed handler wired")
  else
    log_debug("data package changed handler unavailable (DLL build); poll fallback active")
  end

  log_debug("handlers wired; library auto-connects on ctor")
end

--- Poll the connection, returning pcall's ok plus its error.
function M.poll()
  return pcall(function()
    state.ap:poll()
  end)
end

--- Tear the connection down (menu return, session change).
function M.close()
  if state.ap then
    pcall(function()
      state.ap:reset()
    end)
  end
  state.ap, state.connected = nil, false
end

-- ---------------------------------------------------------------------------
-- Module-facing handle
-- ---------------------------------------------------------------------------
--- The AP surface modules are given as HOST.ap: the verbs and the sent-check
--- line renderer, and nothing that can open, close or poll the connection. This
--- is the seam — keep its member set to exactly this (spec:
--- tests/lua/test_module_contract.lua).
M.handle = {
  connected = M.connected,
  can_check = M.can_check,
  checks = M.checks,
  drop_checks = M.drop_checks,
  bounce = M.bounce,
  goal = M.goal,
  item_name = M.item_name,
  server_time = M.server_time,
  slot_name = M.slot_name,
  player_number = M.player_number,
  sent_line = M.sent_line,
}

return M
