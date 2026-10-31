-- Author: Tim Harrison
-- Created: 2026-10-16
-- Updated: 2026-10-23

-- Spec for client/ue4ss_mod/srt_bridge/Scripts/option.lua. The world emits
-- per-game toggles as ints; the modules used to hand-parse them, so an encoding
-- change could silently disarm a module. option.flag is the single decoder:
-- int/boolean on-off, an optional legacy name string, and a loud once-per-
-- encoding WARN for anything unrecognized.
-- Run from the client repo root: lua tests/lua/test_option.lua

package.path = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "support/?.lua;" .. package.path
local H = require("harness")

package.loaded["option"] = nil
local O = require("option")

local warns = {}
local function sink() return {warn = function(m) warns[#warns + 1] = m end} end

local ok = H.ok

-- 1. the int encodings the world emits
ok(O.flag(1, "opt") == true, "1: 1 is on")
ok(O.flag(0, "opt") == false, "1: 0 is off")

-- 2. booleans and nil (specs and hand-written slot data)
ok(O.flag(true, "opt") == true, "2: true is on")
ok(O.flag(false, "opt") == false, "2: false is off")
ok(O.flag(nil, "opt") == false, "2: nil is off")

-- 3. a legacy name string keeps working when the caller declares it
ok(O.flag("dragonsanity", "dragon_shuffle", nil, "dragonsanity") == true,
    "3: declared legacy string is on")
ok(O.flag("dragonsanity", "dragon_shuffle", nil) == false,
    "3: an undeclared string is off (no silent acceptance)")

-- 4. an unrecognized value is off and warns loudly, once per distinct encoding
warns = {}
O.reset()
local log = sink()
ok(O.flag("on", "dragon_shuffle", log) == false, "4: unrecognized string is off")
ok(#warns == 1, "4: unrecognized encoding warns (got " .. #warns .. ")")
ok(warns[1]:find("unrecognized option encoding: dragon_shuffle=on", 1, true) ~= nil,
    "4: warning names the option and value")
O.flag("on", "dragon_shuffle", log)
ok(#warns == 1, "4: the same encoding does not warn twice (got " .. #warns .. ")")
O.flag(2, "dragon_shuffle", log)
ok(#warns == 2, "4: a different encoding warns again (got " .. #warns .. ")")

-- 5. reset() clears the warn-once memory for a fresh spec run
warns = {}
O.reset()
O.flag("on", "dragon_shuffle", log)
ok(#warns == 1, "5: reset re-arms the warning")

-- 6. no logger: still decodes, never crashes
ok(O.flag("on", "dragon_shuffle") == false, "6: decodes without a logger")

H.finish()
