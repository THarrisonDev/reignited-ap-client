-- Author: Tim Harrison
-- Created: 2026-10-17
-- Updated: 2026-10-17

-- world_fixture: a real game_state snapshot for the module specs. A spec keeps
-- its fake gamestate (the "game") and calls fx.tick(module, gs) where it used
-- to call module.tick(gs), so the timing rules (transition poll, settle ticks)
-- are exercised through the same code the host runs. Not a spec itself: it
-- lives under tests/lua/support/ so `make lua-tests` does not run it.

local game_state = require("game_state")

local F = {}
F.__index = F

--- Build a fixture whose snapshot resolves the given level path -> region map.
--- @param regions table|nil Path -> region name.
--- @return table
function F.new(regions)
  return setmetatable({ world = game_state.new({ regions = regions or {} }) }, F)
end

--- Refresh the snapshot from gs and tick the module with it.
--- @param mod table Module under test.
--- @param gs table|nil Fake gamestate (the "game").
function F:tick(mod, gs)
  self.world:update(gs)
  mod.tick(self.world)
end

--- Forget the level view, mirroring a session reset.
function F:reset()
  self.world:reset()
end

return F
