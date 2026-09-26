-- logger: leveled logging + config for the bridge (split out of main.lua).
-- Every line lands in bridge.log; info/warn/error also reach the UE4SS
-- console, debug only when config debug=1. UE4SS print does not append a
-- newline, so each console line carries one.
--
-- Line shapes:
--   direct  (log_info/...): file <HH:MM:SS> <head><msg>, console
--           [SRTAP] <word><msg> — heads: "" / "WARN  "/"WARN " / "ERROR " /
--           "debug "/"(debug) "
--   tagged  (logger.tagged): the level word sits between the tag and the
--           message, once, on every surface:
--           file <HH:MM:SS> [TAG] WARN msg · console [SRTAP] [TAG] WARN msg ·
--           debug file <HH:MM:SS> debug [TAG] msg · debug console
--           [SRTAP] (debug) [TAG] msg
--
-- The log file is held open in append mode between lines (flushed per
-- write); a failed write closes and reopens the handle, so a mod reload
-- re-firing old closures still appends correctly (append mode has no
-- position to go stale).
--
-- BRIDGE_DIR is defined here — the single bridge path prefix in the Scripts/
-- tree; main.lua derives every bridge file path from it.
--
-- Config: C:/srtap_bridge/config.txt (key=value lines), loaded at require
-- time (as it always was):
--   host=ws://127.0.0.1:38281
--   slot=SRTPlayer
--   password=
--   debug=0          (1 = show debug lines in the UE4SS console)

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

-- emit(level, file_head, console_head, line)
local function emit(level, file_head, console_head, line)
    write_line(file_head, line)
    if level == "debug" and not DEBUG then return end
    print("[SRTAP] " .. console_head .. line .. "\n")
end

function M.log_info(l) emit("info", "", "", tostring(l)) end
function M.log_warn(l) emit("warn", "WARN  ", "WARN ", tostring(l)) end
function M.log_error(l) emit("error", "ERROR ", "ERROR ", tostring(l)) end
function M.log_debug(l) emit("debug", "debug ", "(debug) ", tostring(l)) end

-- A leveled logger for one module: every line is prefixed with tag (plus a
-- WARN/ERROR word for those levels); info/warn/error always reach the
-- console, debug only when config debug=1. sink (the specs) replaces the
-- file+console router: it receives every composed line as one string.
--
-- Composed line = tag .. " " .. ("WARN "/"ERROR " for those levels) .. message.
function M.tagged(tag, sink)
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

-- init-time adapter: production passes a leveled logger (main.lua builds one
-- per module with tagged), the specs pass a plain collector function (it
-- receives every composed line), and a missing one falls back to the real
-- router under this tag.
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