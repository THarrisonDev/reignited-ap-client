-- Author: Tim Harrison
-- Created: 2026-10-16
-- Updated: 2026-10-16

-- session: which save is open. Loads the region table the modules resolve
-- against, polls the game state through session_gate and opens or closes the
-- session as it directs, and resets the per-session module state on a change.
-- See docs/game_gates.md.

local U = require("util")
local L = require("logger")
local SESSION = require("session_gate")
local state = require("state")
local checkd = require("checkd")
local ap_client = require("ap_client")

local log_info, log_error, log_debug = L.log_info, L.log_error, L.log_debug
local CFG = L.cfg

local M = {}

-- ---------------------------------------------------------------------------
-- Region table
-- ---------------------------------------------------------------------------
--- Load the generated level path -> region name map. Refuses the session when
--- it is missing: without it, dragons, level locks, balloonists and egg gates
--- all resolve nothing, so a "successful" session would silently send a
--- fraction of the checks.
--- @return table
function M.load_regions()
  local ok, regions = pcall(require, "regions")
  if not ok or type(regions) ~= "table" then
    log_error(
      "FATAL region table: require('regions') failed (" .. tostring(regions) .. ") — refusing to open a session; reinstall the mod"
    )
    SESSION.block("region table missing (regions.lua) — reinstall the mod")
    return {}
  end
  local n = 0
  for _ in pairs(regions) do
    n = n + 1
  end
  log_debug("region table: loaded " .. n .. " paths from regions.lua")
  return regions
end

-- ---------------------------------------------------------------------------
-- Game-thread reads
-- ---------------------------------------------------------------------------
-- Int out-params only: the static function library's CDO is unreachable from
-- Lua, and string out-params crash.
--- Return the active save's slot and game indexes, or nil when unreadable.
--- @param gs userdata FalconGameState.
--- @return number|nil, number|nil
local function read_active_slot(gs)
  local so, go = {}, {}
  if not pcall(function()
    gs["get slot index"](so)
  end) then
    return nil
  end
  if not pcall(function()
    gs["get game index"](go)
  end) then
    return nil
  end
  return U.prop(so, "slot index"), U.prop(go, "the game index")
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------
--- Reset every module's session state: a sender holds configured slot state, so
--- it goes back to unconfigured; every other shape drops its session state.
local function reset_modules()
  for _, entry in ipairs(state.mods) do
    if entry.shape == "sender" then
      state.call(entry, "configure", {})
    else
      state.call(entry, "reset")
    end
  end
end

--- Clear all per-session host and module state.
local function reset_state()
  state.clear_session()
  reset_modules()
end

--- Open a session for the picked save: reset state, write session.txt, spawn
--- checkd and connect AP.
--- @param slot number Zero-based save slot index.
--- @param game number Game index (SESSION.SPYRO1/2/3).
function M.open(slot, game)
  reset_state()
  state.session_game = game
  -- A drop checkd wrote for the previous save must not reach this one.
  checkd.clear_drop()
  checkd.write_session_file(slot, game)
  log_info(
    string.format(
      "Save slot %d picked (%s): connecting to %s as %s",
      slot + 1,
      SESSION.game_name(game),
      CFG.host,
      CFG.slot
    )
  )
  checkd.spawn()
  ap_client.connect()
end

--- Close the session: tear down AP, reset state and log the return to menu.
function M.close()
  checkd.clear_session_file()
  ap_client.close()
  collectgarbage()
  reset_state()
  log_info("Back at the main menu: disconnected. Pick a save to reconnect.")
end

local blocked_notice_shown = false -- the refused-session banner has been shown

--- Poll the world snapshot through the session gate and open/close as directed.
--- @param world table game_state snapshot from watch.lua.
function M.tick(world)
  if not world.ok then
    return
  end
  local action, slot, opened = SESSION.tick(world.gstate, function()
    return read_active_slot(world.gs)
  end)
  if SESSION.is_blocked() then
    -- The gate refuses to open, so nothing would ever be sent. Say so once, in
    -- play, where the fanfare banner exists.
    if not blocked_notice_shown and world.gstate == SESSION.IN_PLAY then
      blocked_notice_shown = true
      state.each("note_system", "Mod files missing - reinstall the client")
    end
    return
  end
  if action == "open" then
    log_debug(string.format("[SESSION] open: slot index=%d game index=%d", slot, opened))
    M.open(slot, opened)
  elseif action == "close" then
    M.close()
  end
end

return M
