-- Author: Tim Harrison
-- Created: 2026-10-17
-- Updated: 2026-10-17

-- game_state: the one per-poll snapshot of the running game. The poll loop
-- refreshes it once and hands the same table to every module's tick, so the
-- level path is read and resolved once instead of once per module, and every
-- module sees the same transition on the same poll.
--
-- Fields (modules read them; only the host refreshes them):
--   ok, gs        -- a gamestate was handed over, and the userdata
--   gstate        -- EFalconGameState (SESSION.MAIN_MENU / IN_PLAY), or nil
--   path, region  -- "current level" map path, and its regions.lua name
--   playable      -- path when region resolved, else nil (loading, menus, cutscenes)
--   ticks         -- polls since path last changed (0 on the change poll)
--   changed       -- this poll saw a new path: a world transition
--   epoch         -- path changes since reset (module-side cache key)
--   prev_path, prev_gstate -- values before this poll's update, for the log line

local U = require("util")

local M = {}

local World = {}
World.__index = World

--- Build a snapshot over the generated level path -> region table.
--- @param opts table|nil {regions = table}.
--- @return table
function M.new(opts)
  return setmetatable({
    regions = (opts and opts.regions) or {},
    ok = false,
    gs = nil,
    gstate = nil,
    path = nil,
    region = nil,
    playable = nil,
    ticks = 0,
    changed = false,
    epoch = 0,
    prev_path = nil,
    prev_gstate = nil,
  }, World)
end

--- Read the map path of gs, or nil when unreadable.
--- @return string|nil
local function read_path(gs)
  local level = U.safe(function()
    return gs["current level"]
  end, nil)
  if level == nil then
    return nil
  end
  return U.safe(function()
    return level:ToString()
  end, nil)
end

--- Record a path change (or the steady state) and its derived fields.
local function apply_path(self, path)
  if path == self.path then
    self.ticks = self.ticks + 1
    self.changed = false
    return
  end
  self.prev_path = self.path
  self.path = path
  self.region = path and self.regions[path] or nil
  self.playable = self.region and path or nil
  self.ticks = 0
  self.changed = true
  self.epoch = self.epoch + 1
end

--- Refresh the snapshot from gs and return self. Any path change, including to
--- nil (loading screen, menu, session close), is a transition. ok means the
--- host handed a gamestate over; the host's own U.game_state() has already
--- refused an invalid one.
--- @return table self
function World:update(gs)
  local ok = gs ~= nil
  local path = ok and read_path(gs) or nil
  local gstate = ok and U.prop(gs, "theCurrentGameState") or nil

  self.ok, self.gs = ok, gs
  self.prev_gstate = self.gstate
  self.gstate = type(gstate) == "number" and gstate or nil
  apply_path(self, path)
  return self
end

--- Forget the level view: the next observation is a transition again.
function World:reset()
  self.ok, self.gs, self.gstate = false, nil, nil
  self.path, self.region, self.playable = nil, nil, nil
  self.prev_path, self.prev_gstate = nil, nil
  self.ticks, self.changed, self.epoch = 0, false, 0
end

return M
