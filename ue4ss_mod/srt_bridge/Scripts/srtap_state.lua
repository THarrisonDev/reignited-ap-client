-- Author: Tim Harrison
-- Created: 2026-11-03
-- Updated: 2026-11-03

-- srtap_state: the bridge's one persisted state file per seed+slot, shared by
-- every module that has something worth keeping across sessions.
--
-- <dir>srtap_<seed>_<slot>.txt holds one key=value per line. Values are numbers
-- where tonumber() succeeds, strings otherwise; a malformed line is ignored, and
-- a key this module never set is preserved on flush so a newer build's keys
-- survive a downgrade. Missing file = empty table, never an error.
--
-- Writes are explicit: open() and set() never touch the disk; only flush() does,
-- rewriting the whole (tiny) file through a temp file and a rename, so a crash
-- mid-write cannot truncate it. Callers flush at their own durability points —
-- never per item, per check or on a timer.

local logger = require("logger")

local TAG = "[STATE]"

local M = {}

local log = logger.tagged(TAG)

local path = nil -- this seed+slot's file, or nil when no dir was given
local values = {} -- the loaded key -> value table
local dirty = false -- values are ahead of the file
local warned = false -- the cannot-write WARN was already logged this streak
local loaded_path = nil -- the file the values were loaded from

--- Return the file name for a seed+slot, safe to use in a path.
--- @param sd table|nil Slot data carrying seed and slot.
--- @return string
local function slot_name(sd)
  local id = tostring(sd and sd.seed or "noseed") .. "_" .. tostring(sd and sd.slot or "noslot")
  return (id:gsub("[^%w_%-]", "_"))
end

--- Read one line into values, ignoring anything without a key.
--- @param line string One line of the file.
local function parse_line(line)
  local key, value = line:match("^%s*([%w_%.%-]+)%s*=%s*(.-)%s*$")
  if not key or value == "" then
    return
  end
  values[key] = tonumber(value) or value
end

--- Load the file at path into values, leaving values empty when it is absent.
--- @param file string The state file path.
local function load(file)
  values = {}
  local f = io.open(file, "r")
  if not f then
    return
  end
  local n = 0
  for line in f:lines() do
    parse_line(line)
    n = n + 1
  end
  f:close()
  log.debug("loaded " .. n .. " line(s) from " .. file)
end

--- Serialise values into a sorted key=value block (stable diffs, readable file).
--- @return string
local function serialise()
  local keys = {}
  for key in pairs(values) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  local out = {}
  for _, key in ipairs(keys) do
    out[#out + 1] = key .. "=" .. tostring(values[key])
  end
  return table.concat(out, "\n") .. "\n"
end

--- Write text to file, returning whether it landed.
--- @param file string Destination path.
--- @param text string Contents.
--- @return boolean
local function write(file, text)
  local f = io.open(file, "w")
  if not f then
    return false
  end
  local ok = pcall(function()
    f:write(text)
    f:flush()
  end)
  f:close()
  return ok
end

--- Rewrite the whole file through a temp file and a rename; fall back to a
--- direct write when the swap cannot be made.
--- @param file string The state file path.
--- @param text string Contents.
--- @return boolean
local function rewrite(file, text)
  local tmp = file .. ".tmp"
  if write(tmp, text) then
    pcall(function()
      os.remove(file)
    end)
    local ok = pcall(function()
      os.rename(tmp, file)
    end)
    if ok then
      return true
    end
  end
  pcall(function()
    os.remove(tmp)
  end)
  return write(file, text)
end

--- Resolve and load this seed+slot's state file. A different path reloads and
--- drops whatever was in memory.
--- @param sd table|nil Slot data carrying seed and slot.
--- @param dir string|nil The host's state directory; nil disables persistence.
function M.open(sd, dir)
  local next_path = dir and (dir .. "srtap_" .. slot_name(sd) .. ".txt") or nil
  if next_path == loaded_path and next_path ~= nil then
    return
  end
  path, loaded_path = next_path, next_path
  dirty, warned = false, false
  if not next_path then
    values = {}
    return
  end
  load(next_path)
end

--- Return the value for key, or default when it is absent.
--- @param key string
--- @param default any Returned when the key has no value.
--- @return any
function M.get(key, default)
  local value = values[key]
  if value == nil then
    return default
  end
  return value
end

--- Set key in memory, marking the file dirty. Nothing is written here.
--- @param key string
--- @param value string|number
function M.set(key, value)
  if values[key] == value then
    return
  end
  values[key] = value
  dirty = true
end

--- Write the file when something changed; a no-op when clean or when no dir was
--- given. A failure warns once and keeps the values dirty for the next flush.
function M.flush()
  if not dirty or not path then
    return
  end
  if rewrite(path, serialise()) then
    dirty, warned = false, false
    return
  end
  if not warned then
    warned = true
    log.warn("cannot write " .. path .. " (this session's progress is not saved)")
  end
end

M.tag = TAG

return M
