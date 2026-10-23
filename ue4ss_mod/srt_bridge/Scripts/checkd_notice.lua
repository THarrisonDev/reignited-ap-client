-- Author: Tim Harrison
-- Created: 2026-10-15

-- checkd_notice: show the one-line notices the Go checkd daemon writes for the
-- player. checkd is option-blind and, when it cannot read a save, sends nothing
-- at all — this banner is the only in-game signal of that. Reads
-- <bridge>/checkd.status.json ({"text":"..."}; "" means no notice) and hands
-- each new text to the host once. Shown by hud_banner; see docs/fanfare_text.md
-- ("Player notices").
--
-- The file is state, not a queue: the same text never re-shows, and a notice
-- that clears and returns shows again.

local logger = require("logger")

local DEFAULT_NOTICE = "C:/srtap_bridge/checkd.status.json"

local shown_text = nil -- last notice text handed to the host

local TAG = "[NOTICE]"

local _gate, _log, _on_notice, _path

local M = {}

--- Inject the host's callbacks and dependencies and re-arm the notice channel.
--- @param opts table {connect_gate, log, on_notice, notice_path}
function M.init(opts)
    _gate = opts.connect_gate
    _log = logger.leveled(TAG, opts.log)
    _on_notice = opts.on_notice
    _path = opts.notice_path or DEFAULT_NOTICE
    shown_text = nil
end

--- Poll the notice file once and hand any new notice to the host.
function M.tick()
    if not _gate() then return end
    local f = io.open(_path, "r")
    if not f then return end
    local text = f:read("a") or ""
    f:close()

    local msg = text:match('"text"%s*:%s*"([^"]*)"')
    if not msg then
        _log.warn("notice parse error (head: " .. text:sub(1, 80) .. ")")
        return
    end
    if msg == "" then
        -- cleared: a notice that comes back later shows again
        shown_text = nil
        return
    end
    if msg == shown_text then return end
    shown_text = msg
    _log.info("notice: " .. msg)
    _on_notice(msg)
end
M.tag = TAG

return M
