-- Author: Tim Harrison
-- Created: 2026-09-26
-- Updated: 2026-10-23

-- logger: leveled logging and config for the bridge (split out of main.lua).
-- Every line lands in bridge.log; info/warn/error also reach the UE4SS
-- console, debug only when config debug=1. BRIDGE_DIR is defined here — the
-- single bridge path prefix in the Scripts/ tree; main.lua derives every
-- bridge file path from it.
--
-- Config: C:/srtap_bridge/config.txt (key=value lines), loaded at require
-- time. See the defaults on M.cfg below.

local M = {}

local BRIDGE_DIR = "C:/srtap_bridge/"
local LOG = BRIDGE_DIR .. "bridge.log"
local DEBUG = false

local FILE_HEAD = {info = "", warn = "WARN  ", error = "ERROR ", debug = "debug "}
local CONSOLE_HEAD = {info = "", warn = "WARN ", error = "ERROR ", debug = "(debug) "}
-- the word a tagged line carries between tag and message (debug carries none:
-- the debug file/console heads mark it)
local WORD = {info = "", warn = "WARN ", error = "ERROR ", debug = ""}

local log_fh = nil    -- append handle, kept open between lines

--- Append one stamped line to the log file, reopening the handle once if it
--- went bad (reloaded state, deleted file). Silently gives up when the file
--- cannot be opened, so the console keeps working.
local function write_line(head, line)
    local stamped = os.date("%H:%M:%S ") .. head .. line .. "\n"
    local f = log_fh
    if f then
        if pcall(function() f:write(stamped) f:flush() end) then return end
        pcall(function() f:close() end)
        log_fh = nil
    end
    -- first line, or the handle went bad (reloaded state, deleted file)
    f = io.open(LOG, "a")
    if not f then return end   -- console keeps working when the file can't
    log_fh = f
    pcall(function() f:write(stamped) f:flush() end)
end

--- Write line to the file under head, then to the UE4SS console unless it is
--- a debug line while DEBUG is off.
local function emit(level, file_head, console_head, line)
    write_line(file_head, line)
    if level == "debug" and not DEBUG then return end
    print("[SRTAP] " .. console_head .. line .. "\n")
end

--- Log at info level (file and console).
function M.log_info(l) emit("info", "", "", tostring(l)) end
--- Log at warn level (file and console).
function M.log_warn(l) emit("warn", "WARN  ", "WARN ", tostring(l)) end
--- Log at error level (file and console).
function M.log_error(l) emit("error", "ERROR ", "ERROR ", tostring(l)) end
--- Log at debug level (file always, console only when config debug=1).
function M.log_debug(l) emit("debug", "debug ", "(debug) ", tostring(l)) end

--- Return a leveled logger whose every line is prefixed with tag (plus a
--- WARN/ERROR word for those levels). sink, used by the specs, receives each
--- composed line as one string instead of the file+console router.
--- @return table
function M.tagged(tag, sink)
    --- Compose one line for level and route it to sink or the real logger.
    local function emit_at(level, msg)
        local line = tag .. " " .. WORD[level] .. tostring(msg)
        if sink then sink(line) return end
        if level == "debug" then
            emit("debug", FILE_HEAD.debug, CONSOLE_HEAD.debug, line)
        else
            emit(level, "", "", line)
        end
    end
    return {
        info = function(msg) emit_at("info", msg) end,
        warn = function(msg) emit_at("warn", msg) end,
        error = function(msg) emit_at("error", msg) end,
        debug = function(msg) emit_at("debug", msg) end,
    }
end

--- Return log_opt when it is a logger table, else wrap it: a function becomes
--- a tagged sink (the specs), and nil falls back to the real router.
--- @return table
function M.leveled(tag, log_opt)
    if type(log_opt) == "table" then return log_opt end
    return M.tagged(tag, type(log_opt) == "function" and log_opt or nil)
end

M.cfg = {
    host = "ws://127.0.0.1:38281",
    slot = "SRTPlayer",
    password = "",
    game = "Spyro Reignited Trilogy", -- fixed: a config.txt game= key is ignored
    spawn_checkd = "1",
}

--- Read config.txt into M.cfg (host, slot, password, spawn_checkd) and DEBUG.
local function load_config()
    local f = io.open(BRIDGE_DIR .. "config.txt", "r")
    if not f then return end
    for line in f:lines() do
        local key, val = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if key == "host" then M.cfg.host = val
        elseif key == "slot" then M.cfg.slot = val
        elseif key == "password" then M.cfg.password = val
        elseif key == "spawn_checkd" then M.cfg.spawn_checkd = val
        elseif key == "debug" then DEBUG = (val == "1" or val == "true") end
    end
    f:close()
end
load_config()

M.bridge_dir = BRIDGE_DIR

return M