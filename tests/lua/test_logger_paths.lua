-- Author: Tim Harrison
-- Created: 2026-11-09

-- Spec for the bridge-folder selection in
-- client/ue4ss_mod/srt_bridge/Scripts/logger.lua (docs/client_paths.md).
-- Run from the client repo root: lua tests/lua/test_logger_paths.lua

package.path = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "support/?.lua;" .. package.path
local H = require("harness")

local logger = require("logger")

local case, eq = H.test, H.eq

local BASE = "C:/Users/Player/AppData/Local"
local NEW = BASE .. "/srtap_bridge/"
local LEGACY = "C:/srtap_bridge/"

--- Build the exists predicate over the folder set present.
--- @param present table Folder -> true.
--- @return function
local function probe(present)
    return function(dir) return present[dir] == true end
end

case("new folder present: new is selected", function()
    eq(logger.resolve_bridge(BASE, LEGACY, probe({[NEW] = true})), NEW, "new")
end)

case("new absent, legacy present: legacy is selected", function()
    eq(logger.resolve_bridge(BASE, LEGACY, probe({[LEGACY] = true})), LEGACY, "legacy")
end)

case("neither present, base set: new is selected", function()
    eq(logger.resolve_bridge(BASE, LEGACY, probe({})), NEW, "new")
end)

case("neither present, no base: legacy is selected", function()
    eq(logger.resolve_bridge(nil, LEGACY, probe({})), LEGACY, "legacy")
end)

case("empty base counts as no base", function()
    eq(logger.resolve_bridge("", LEGACY, probe({})), LEGACY, "legacy")
end)

case("both present: new wins", function()
    eq(logger.resolve_bridge(BASE, LEGACY, probe({[NEW] = true, [LEGACY] = true})), NEW, "new")
end)

case("backslashes in base are normalized", function()
    local base = [[C:\Users\Player\AppData\Local]]
    eq(logger.resolve_bridge(base, LEGACY, probe({[NEW] = true})), NEW, "new")
end)

case("a trailing slash in base does not double up", function()
    eq(logger.resolve_bridge(BASE .. "/", LEGACY, probe({[NEW] = true})), NEW, "new")
    eq(logger.resolve_bridge([[C:\Users\Player\AppData\Local\]], LEGACY, probe({})), NEW, "new")
end)

case("the resolved bridge dir keeps its trailing slash", function()
    eq(logger.bridge_dir:sub(-1), "/", "trailing slash on " .. logger.bridge_dir)
end)

case("modules requiring logger load without a bridge path", function()
    H.ok(type(require("checks_drop")) == "table", "checks_drop loaded")
    H.ok(type(require("checkd_notice")) == "table", "checkd_notice loaded")
end)

H.finish()
