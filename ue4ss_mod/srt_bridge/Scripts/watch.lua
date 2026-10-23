-- Author: Tim Harrison
-- Created: 2026-10-16
-- Updated: 2026-10-17

-- watch: the poll loop (250 ms, async thread). Refreshes the one game_state
-- snapshot, drives the session gate, the AP poll, the check-drop and notice
-- ingestion, the per-game watcher ticks, and the heartbeat. Reads state.world,
-- state.mods and state.watch. See docs/mod_architecture.md §3 and §5.

local U = require("util")
local L = require("logger")
local session = require("session")
local ap_client = require("ap_client")
local state = require("state")

local debug_log = L.log_debug

local M = {}

local TICK_MS = 250
local HB_TICKS = 480 -- heartbeat cadence in polls

local polls = 0

--- Log the transition lines for the snapshot, when this poll changed something.
--- @param world table game_state snapshot.
local function log_transitions(world)
  if world.gstate ~= world.prev_gstate then
    debug_log(
      string.format("[WORLD] game state %s -> %s", tostring(world.prev_gstate), tostring(world.gstate))
    )
  end
  if world.changed then
    debug_log(string.format("[WORLD] level %s -> %s", tostring(world.prev_path), tostring(world.region or "none")))
  end
end

--- Log one heartbeat line per module that answers status().
local function heartbeat()
  for _, hb in ipairs(state.statuses()) do
    debug_log(hb.tag .. " hb: " .. tostring(hb.line))
  end
end

--- Run the session gate and poll the AP connection for one snapshot.
local function poll_connection(world)
  U.safe(function()
    return session.tick(world)
  end)
  if not state.ap then return end
  local ok, err = ap_client.poll()
  -- Backlog replay fallback for DLL builds without the changed handler; must
  -- also run when poll() errored (one-shot inside).
  state.call(state.mod("data_pkg"), "tick", ap_client.data_package_valid())
  if not ok then
    debug_log("poll() errored: " .. tostring(err))
    -- LoopAsync stops on a true return, so one errored poll must not kill the
    -- session gate and watchers for the rest of the session.
  end
end

--- Ingest the check drops and notices, then tick this session's watchers.
local function poll_modules(world)
  -- Notices run with no session open: a scanner failure is worth showing
  -- before the player has picked a save.
  if state.connected then
    state.call(state.mod("checks_drop"), "tick")
    state.call(state.mod("checkd_notice"), "tick")
  end
  -- Game watchers: only while connected and in play on this session's save; the
  -- one snapshot feeds every tick, and a tick that does nothing is the normal
  -- case (writes are re-asserted, not retried).
  local w = state.connected and state.session_game and state.watch[state.session_game]
  if not w then return end
  for _, entry in ipairs(w.ticks) do
    state.call(entry, "tick", world)
  end
end

--- One poll: the world snapshot, the session gate, the connection, the watchers.
local function poll()
  local world = state.world:update(U.game_state())
  log_transitions(world)
  poll_connection(world)
  poll_modules(world)
  polls = polls + 1
  if polls % 240 == 0 then
    debug_log("poll tick " .. polls)
  end
  -- One heartbeat for every module, once the slot is connected. Before that the
  -- gate logs its own transitions and the modules are unconfigured.
  if state.connected and polls % HB_TICKS == 0 then
    heartbeat()
  end
  return false
end

--- Start the poll loop.
function M.start()
  LoopAsync(TICK_MS, poll)
end

return M
