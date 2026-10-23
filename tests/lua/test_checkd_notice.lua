-- Author: Tim Harrison
-- Created: 2026-10-15
-- Updated: 2026-10-21

-- Spec for client/ue4ss_mod/srt_bridge/Scripts/checkd_notice.lua: the checkd
-- player-notice channel. Run from the client repo root:
-- lua tests/lua/test_checkd_notice.lua

package.path = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "support/?.lua;" .. package.path
local H = require("harness")

local NOTICE = require("checkd_notice")

local case, eq = H.test, H.eq

local tmpdir = os.tmpname()
os.remove(tmpdir)
os.execute('mkdir -p "' .. tmpdir .. '"')
local path = tmpdir .. "/checkd.status.json"

local function fresh(gate_open)
    local state = {notices = {}, logs = {}}
    NOTICE.init({
        connect_gate = function() return gate_open ~= false end,
        log = function(l) state.logs[#state.logs + 1] = l end,
        on_notice = function(t) state.notices[#state.notices + 1] = t end,
        notice_path = path,
    })
    return state
end

local function write_notice(text)
    local f = assert(io.open(path, "w"))
    f:write(text)
    f:close()
end

case("no file: nothing shown, no error", function()
    local state = fresh()
    os.remove(path)
    NOTICE.tick()
    eq(#state.notices, 0, "no notices")
end)

case("a notice is shown once", function()
    local state = fresh()
    write_notice('{"text":"Save Scanning Failed!"}')
    NOTICE.tick()
    eq(#state.notices, 1, "one notice")
    eq(state.notices[1], "Save Scanning Failed!", "the notice text")
    NOTICE.tick()
    eq(#state.notices, 1, "the same text is not re-shown")
end)

case("a cleared notice, then the same text, shows again", function()
    local state = fresh()
    write_notice('{"text":"Save Scanning Failed!"}')
    NOTICE.tick()
    write_notice('{"text":""}')
    NOTICE.tick()
    eq(#state.notices, 1, "clearing shows nothing")
    write_notice('{"text":"Save Scanning Failed!"}')
    NOTICE.tick()
    eq(#state.notices, 2, "the notice returns after a clear")
end)

case("a different text shows", function()
    local state = fresh()
    write_notice('{"text":"First"}')
    NOTICE.tick()
    write_notice('{"text":"Second"}')
    NOTICE.tick()
    eq(#state.notices, 2, "both shown")
    eq(state.notices[2], "Second", "the second text")
end)

case("a malformed notice warns and shows nothing", function()
    local state = fresh()
    write_notice("not json at all")
    NOTICE.tick()
    eq(#state.notices, 0, "nothing shown")
    local joined = table.concat(state.logs, "\n")
    if not joined:find("parse error", 1, true) then
        error("expected a parse-error warn, got: " .. joined)
    end
end)

case("closed gate: the file is never read", function()
    local state = fresh(false)
    write_notice('{"text":"Save Scanning Failed!"}')
    NOTICE.tick()
    eq(#state.notices, 0, "nothing shown while disconnected")
end)

H.finish()
