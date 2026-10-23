-- luacheck config for the UE4SS mod (Scripts/ and the tests/lua specs).
--
-- Dead code and mistakes only: style is not policed here, and long lines are
-- reviewed rather than linted (E501 is a world-side rule). Run via
-- `make luacheck` (client/Makefile) or CI.

std = "lua54"
max_line_length = false
-- Every function at or below 10, matching ruff's C901 and Go's cyclop.
max_cyclomatic_complexity = 10

-- UE4SS injects this API as globals; luacheck cannot see it.
globals = {
  "CreateInvalidObject",
  "ExecuteInGameThread",
  "ExecuteWithDelay",
  "FindAllOf",
  "FindFirstOf",
  "LoopAsync",
  "NotifyOnNewObject",
  "RegisterConsoleCommandHandler",
  "RegisterCustomEvent",
  "RegisterHook",
  "RegisterKeyBind",
  "StaticFindObject",
  "UnregisterCustomEvent",
}
