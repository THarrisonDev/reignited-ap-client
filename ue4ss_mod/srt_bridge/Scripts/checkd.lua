-- Author: Tim Harrison
-- Created: 2026-10-16
-- Updated: 2026-10-23

-- checkd: the save-scanner sidecar — the files it reads, the spawn, and the
-- session file that tells it which save is open. The Go daemon owns the drop
-- format; see client/checkd/.

local L = require("logger")

local M = {}

M.exe = L.bridge_dir .. "srtap_checkd.exe"
M.checks_path = L.bridge_dir .. "checks.json"
M.session_path = L.bridge_dir .. "session.txt"

--- Start the checkd save scanner, unless spawn is disabled in config.
function M.spawn()
  if L.cfg.spawn_checkd == "0" then
    L.log_debug("checkd: spawn disabled in config")
    return
  end
  local f = io.open(M.exe, "r")
  if not f then
    L.log_error("checkd not found at " .. M.exe .. " (collected checks will not be sent)")
    return
  end
  f:close()
  -- start detaches immediately; checkd self-dedupes via checkd.hb.
  local ok, err = pcall(function()
    os.execute('start "srtapd" /b "' .. M.exe .. '"')
  end)
  L.log_debug("checkd spawn: ok=" .. tostring(ok) .. " err=" .. tostring(err))
end

--- Write the session file checkd reads to find the save the player picked.
--- @param slot number Zero-based save slot index.
--- @param game number Game index (SESSION.SPYRO1/2/3).
function M.write_session_file(slot, game)
  local f = io.open(M.session_path, "w")
  if not f then
    L.log_error("could not write " .. M.session_path .. " (collected checks will not be sent)")
    return
  end
  f:write(string.format("slot=%d\ngame=%d\ntoken=%d\n", slot, game, os.time()))
  f:close()
end

--- Remove the session file: a crashed run would leave checkd pointed at a save
--- the player has not picked this boot.
function M.clear_session_file()
  os.remove(M.session_path)
end

--- Remove a check drop left by the previous save, so it cannot reach this one.
function M.clear_drop()
  os.remove(M.checks_path)
end

return M
