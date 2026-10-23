-- Author: Tim Harrison
-- Created: 2026-10-16
-- Updated: 2026-10-16

-- option: decode the world's slot-data options.
--
-- The world emits per-game toggles as ints (1 on, 0 off). The modules used to
-- hand-parse that, each accepting `1`/`true` and sometimes an older seed's name
-- string, so a change to the world's encoding could silently disarm a module.
-- Every option read now goes through flag(): it accepts the int/boolean
-- encodings, keeps the legacy name strings working where a module passes one,
-- and logs a loud, once-per-encoding WARN for anything else so drift shows up
-- in bridge.log instead of a quiet no-op. See docs/game_state_control.md.

local M = {}

local warned = {} -- "name=value" -> true: one WARN per distinct unrecognized encoding

--- Return whether a slot option is on.
---
--- The world emits 1 (on) / 0 (off); true/false and nil are accepted so specs
--- and hand-written slot data work. legacy_on keeps an older seed's name string
--- (e.g. "dragonsanity") working. Any other value is off and warns once, because
--- an unrecognized encoding means the option is not doing what the world meant.
--- @param val any Slot-data value.
--- @param name string Option name, for the warning.
--- @param log table|nil Leveled logger (only warn() is used).
--- @param legacy_on string|nil Legacy truthy string, when the option ever had one.
--- @return boolean
function M.flag(val, name, log, legacy_on)
  if val == 1 or val == true then
    return true
  end
  if val == 0 or val == false or val == nil then
    return false
  end
  if legacy_on ~= nil and val == legacy_on then
    return true
  end
  local key = tostring(name) .. "=" .. tostring(val)
  if log and not warned[key] then
    warned[key] = true
    log.warn(
      "unrecognized option encoding: "
        .. name
        .. "="
        .. tostring(val)
        .. " ("
        .. type(val)
        .. "); treating as off"
    )
  end
  return false
end

--- Return one game's slot-data table, or {} when absent.
--- @param slot_data table|nil
--- @param game string Game key ("spyro1", "spyro2", "spyro3").
--- @return table
function M.game_data(slot_data, game)
  local games = slot_data and type(slot_data.games) == "table" and slot_data.games or {}
  return type(games[game]) == "table" and games[game] or {}
end

--- Return a game's options table from slot data, or {} when absent.
--- @param slot_data table|nil
--- @param game string Game key ("spyro1", "spyro2", "spyro3").
--- @return table
function M.game_options(slot_data, game)
  local sg = M.game_data(slot_data, game)
  return type(sg.options) == "table" and sg.options or {}
end

--- Clear the warn-once memory (specs only).
function M.reset()
  warned = {}
end

return M
