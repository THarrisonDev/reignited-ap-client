-- Author: Tim Harrison
-- Created: 2026-10-17
-- Updated: 2026-10-23

-- Spec for client/ue4ss_mod/srt_bridge/Scripts/game_state.lua: the per-poll
-- snapshot every module's tick reads. It pins the timing rules the watchers
-- depend on (transition on the change poll, settle ticks after it), the
-- path/region/playable derivation, and the session reset.
-- Run from the client repo root: lua tests/lua/test_game_state.lua

package.path = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "support/?.lua;" .. package.path
local H = require("harness")

local game_state = require("game_state")

local REGIONS = {
    ["/LS101_ArtisansHome/Maps/"] = "Artisans",
    ["/LS102_StoneHill/Maps/"] = "Stone Hill",
    ["/LS201_Glimmer/Maps/"] = "Glimmer",
}

--- Build a fake gamestate whose level and state the spec can move.
local function make_gs()
    local g = { IsValid = function() return true end, level = "/LS101_ArtisansHome/Maps/", state = 3 }
    g["current level"] = { ToString = function() return g.level end }
    setmetatable(g, { __index = function(_, k)
        if k == "theCurrentGameState" then return g.state end
    end })
    return g
end

local ok = H.ok

local W = game_state.new({ regions = REGIONS })

-- 1. First sighting of a level is a transition, and it starts the settle clock.
local g = make_gs()
W:update(g)
ok(W.ok and W.gs == g, "1: a gamestate was accepted")
ok(W.path == "/LS101_ArtisansHome/Maps/" and W.region == "Artisans", "1: path and region resolved")
ok(W.playable == W.path, "1: a known level is playable")
ok(W.changed and W.epoch == 1, "1: first sighting is a transition")
ok(W.ticks == 0, "1: the change poll is tick 0")

-- 2. Holding the level counts settle ticks and is not a transition.
for i = 1, 3 do W:update(g) end
ok(not W.changed and W.ticks == 3 and W.epoch == 1, "2: holding increments ticks, no new epoch")

-- 3. An unknown path is not playable, and it is a transition like any other.
W:update(make_gs())
g.level = "/LS999_Cutscene/Maps/"
W:update(g)
ok(W.changed and W.epoch == 2 and W.path == "/LS999_Cutscene/Maps/", "3: unknown level is a transition")
ok(W.region == nil and W.playable == nil, "3: unknown level resolves no region and is not playable")
ok(W.ticks == 0, "3: the settle clock restarted")

-- 4. Leaving play (load screen) is a transition to no path, and back again.
g.level = ""
W:update(g)
ok(W.changed and W.playable == nil and W.ticks == 0, "4: empty path is a transition, not playable")
g.level = "/LS101_ArtisansHome/Maps/"
W:update(g)
ok(W.changed and W.playable == W.path and W.ticks == 0, "4: returning to a level is a transition")

-- 5. The game state value rides along, including the wrapped out-param shape.
ok(W.gstate == 3, "5: gstate read from the gamestate")
g.state = { value = 0 }
W:update(g)
ok(W.gstate == 0, "5: a table-wrapped gstate is unwrapped")

-- 6. No gamestate at all is a transition to nothing, and never throws.
W:update(nil)
ok(not W.ok and W.playable == nil and W.changed, "6: a missing gamestate clears the level view")

-- 7. reset() forgets the level so the next observation is a transition again.
W:reset()
ok(W.path == nil and W.region == nil and W.playable == nil and W.ticks == 0 and W.epoch == 0
    and not W.changed, "7: reset clears the level view")
W:update(make_gs())
ok(W.changed and W.epoch == 1 and W.ticks == 0, "7: the first poll after reset is a transition")

-- 8. A gamestate that cannot answer is tolerated, not fatal.
local bare = {}
W:update(bare)
ok(W.ok and W.path == nil and W.playable == nil, "8: a gamestate with no current level reads as no level")

-- 9. prev_* fields describe the values before this poll (the host's log line).
g = make_gs()
W:reset()
W:update(g)
g.state = 0
g.level = "/LS102_StoneHill/Maps/"
W:update(g)
ok(W.prev_path == "/LS101_ArtisansHome/Maps/" and W.prev_gstate == 3,
    "9: prev_path/prev_gstate hold the previous poll's values")

H.finish()
