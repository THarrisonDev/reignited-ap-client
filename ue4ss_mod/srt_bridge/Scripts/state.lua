-- Author: Tim Harrison
-- Created: 2026-10-16
-- Updated: 2026-10-17

-- state: the bridge's shared runtime state, plus the module calls that act on
-- it. checkd, ap_client, session and watch all read and write this one table;
-- no other file holds mutable bridge state.
--
-- The tables handed to modules at boot (id_to_name, sent_checks) are cleared in
-- place, never reassigned: each module keeps the reference it was given. world
-- is the one per-poll game snapshot (game_state.lua); clear_session resets it.

local L = require("logger")

local M = {
  ap = nil, -- The lua-apclientpp client (async thread only).
  connected = false, -- The slot_connected..socket_disconnected window.
  session_game = nil, -- Game index of the open session (SESSION.SPYRO1/2/3).
  checks_blocked = false, -- This session's game isn't in the seed: never send its checks.
  name_to_id = {}, -- "Spyro 1: Region: Free Nestor" -> id.
  id_to_name = {}, -- id -> fully-qualified name.
  sent_checks = {}, -- id -> true (ever sent this session; shared with checks_drop).
  scouted = {}, -- location id -> {item, to} from the connect-time LocationScouts.
  processed_indices = {}, -- AP item index -> true (the fan-out is exact-once).
  mods = {}, -- Loaded inventory entries, in inventory order.
  by_name = {}, -- require name -> loaded entry.
  watch = {}, -- session game -> { ticks = {entries} }.
  world = nil, -- This poll's game_state snapshot (main.lua builds it).
  reconciled = {}, -- Entries whose collectible counter the host reconciles.
  reported = {}, -- module.method -> true: its throw was already logged.
}

-- A call into a module is never allowed to take the bridge down: a throw is
-- reported once per module+method, then only at debug, so a broken module
-- cannot spam bridge.log either.

--- Call one of a module's optional methods, returning nil when absent or thrown.
--- @param entry table|nil Inventory entry.
--- @return any
function M.call(entry, method, ...)
  if not entry then
    return nil
  end
  local f = entry.mod[method]
  if type(f) ~= "function" then
    return nil
  end
  local ok, res = pcall(f, ...)
  if ok then
    return res
  end
  local key = entry.name .. "." .. method
  if M.reported[key] then
    L.log_debug(key .. ": " .. tostring(res))
  else
    M.reported[key] = true
    L.log_error(key .. ": " .. tostring(res))
  end
  return nil
end

--- Call an optional method on every loaded module.
function M.each(method, ...)
  for _, entry in ipairs(M.mods) do
    M.call(entry, method, ...)
  end
end

--- Call status() on every module that has one; each line is the module's
--- heartbeat (watch.lua composes it with the module's tag).
--- @return table[] {tag, line} in inventory order.
function M.statuses()
  local out = {}
  for _, entry in ipairs(M.mods) do
    if type(entry.mod.status) == "function" then
      out[#out + 1] = { tag = entry.tag, line = M.call(entry, "status") }
    end
  end
  return out
end

--- Return the loaded entry for a module, or nil when it is not loaded.
--- @param name string require name.
--- @return table|nil
function M.mod(name)
  return M.by_name[name]
end

--- Hand one received item to every module that takes items, once per AP index.
function M.fan_out(name, index)
  if index ~= nil then
    if M.processed_indices[index] then
      return
    end
    M.processed_indices[index] = true
  end
  M.each("note_item", name, index)
end

--- Return whether the open session's game is in an entry's watcher list.
--- @return boolean
function M.watches(entry)
  for _, game in ipairs(entry.games or {}) do
    if game == M.session_game then
      return true
    end
  end
  return false
end

--- Derive the per-game watcher lists and the reconcile set from the loaded
--- inventory. Called once, after the inventory loads.
function M.derive()
  M.watch, M.reconciled = {}, {}
  for _, entry in ipairs(M.mods) do
    for _, game in ipairs(entry.games or {}) do
      local w = M.watch[game]
      if not w then
        w = { ticks = {} }
        M.watch[game] = w
      end
      w.ticks[#w.ticks + 1] = entry
    end
    if type(entry.mod.is_item) == "function" then
      M.reconciled[#M.reconciled + 1] = entry
    end
  end
end

--- Clear the state a session owns, in place (session change, menu return).
function M.clear_session()
  for k in pairs(M.name_to_id) do
    M.name_to_id[k] = nil
  end
  for k in pairs(M.id_to_name) do
    M.id_to_name[k] = nil
  end
  for k in pairs(M.sent_checks) do
    M.sent_checks[k] = nil
  end
  for k in pairs(M.scouted) do
    M.scouted[k] = nil
  end
  M.processed_indices = {}
  M.session_game, M.checks_blocked = nil, false
  if M.world then
    M.world:reset()
  end
end

--- Forget everything: a fresh boot (main.lua runs once per game boot, and the
--- specs load it repeatedly in one process).
function M.reset()
  M.clear_session()
  M.ap, M.connected = nil, false
  M.mods, M.by_name, M.watch, M.reconciled, M.reported = {}, {}, {}, {}, {}
  M.world = nil
end

return M
