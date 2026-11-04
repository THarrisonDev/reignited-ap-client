-- Author: Tim Harrison
-- Created: 2026-11-03
-- Updated: 2026-11-03

-- Spec for client/ue4ss_mod/srt_bridge/Scripts/srtap_state.lua: the one state
-- file per seed+slot that every module with something to remember shares.
-- Run from the client repo root: lua tests/lua/test_srtap_state.lua

package.path = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "support/?.lua;" .. package.path
local H = require("harness")

local S = require("srtap_state")

local case, eq = H.test, H.eq

-- Never the real bridge dir: a temp prefix the spec removes afterwards.
local DIR = os.tmpname()
os.remove(DIR)
DIR = DIR .. "-"
local SD = { seed = "S1", slot = "P1" }
local SD2 = { seed = "S2", slot = "P2" }
local FILE = DIR .. "srtap_S1_P1.txt"

--- Drop the cached module state, as a fresh process would.
local function fresh_process()
    package.loaded["srtap_state"] = nil
    S = require("srtap_state")
end

--- Write a state file by hand.
local function write_file(path, text)
    local f = assert(io.open(path, "w"))
    f:write(text)
    f:close()
end

os.remove(FILE)
os.remove(FILE .. ".tmp")

case("a missing file is an empty table, not an error", function()
    fresh_process()
    S.open(SD, DIR)
    eq(S.get("lives_granted", 0), 0, "a default comes back")
    eq(S.get("seen_upto", nil), nil, "an absent key is nil")
    eq(H.read_file(FILE), "", "and nothing was created")
end)

case("set and flush round-trip through the file", function()
    fresh_process()
    S.open(SD, DIR)
    S.set("seen_upto", 40)
    S.set("lives_granted", 3)
    eq(H.read_file(FILE), "", "set writes nothing")
    S.flush()
    eq(H.read_file(FILE), "lives_granted=3\nseen_upto=40\n", "the file holds both keys")
    -- a later process reloads them, numbers staying numbers
    fresh_process()
    S.open(SD, DIR)
    eq(S.get("seen_upto", nil), 40, "the watermark")
    eq(S.get("lives_granted", nil), 3, "the ledger")
    eq(type(S.get("seen_upto")), "number", "numbers stay numbers")
end)

case("two modules share one file without clobbering each other", function()
    fresh_process()
    S.open(SD, DIR)
    S.set("lives_granted", 7) -- the fillers module's key
    S.flush()
    S.set("seen_upto", 12) -- the hud_banner module's key
    S.flush()
    eq(H.read_file(FILE), "lives_granted=7\nseen_upto=12\n", "both keys survive")
end)

case("a key this build never set is preserved", function()
    write_file(FILE, "seen_upto=5\nfuture_thing=hello\n")
    fresh_process()
    S.open(SD, DIR)
    eq(S.get("future_thing", nil), "hello", "the unknown key loads as a string")
    S.set("lives_granted", 1)
    S.flush()
    eq(H.read_file(FILE), "future_thing=hello\nlives_granted=1\nseen_upto=5\n", "and is written back")
end)

case("malformed lines are ignored", function()
    write_file(FILE, "garbage\n=vale\n\nseen_upto=9\n   \nno number here\n")
    fresh_process()
    S.open(SD, DIR)
    eq(S.get("seen_upto", nil), 9, "the good line parsed")
    eq(S.get("garbage", nil), nil, "the junk line is not a key")
    S.set("lives_granted", 2)
    S.flush()
    eq(H.read_file(FILE), "lives_granted=2\nseen_upto=9\n", "only real keys are rewritten")
end)

case("a different seed+slot reloads and drops the in-memory values", function()
    fresh_process()
    S.open(SD, DIR)
    S.set("seen_upto", 30)
    S.flush()
    S.open(SD2, DIR) -- another slot's file, empty
    eq(S.get("seen_upto", nil), nil, "the other slot starts clean")
    eq(H.read_file(DIR .. "srtap_S2_P2.txt"), "", "and its file was not created")
    S.open(SD, DIR)
    eq(S.get("seen_upto", nil), 30, "back on the first slot, its own value returns")
end)

case("no directory is a silent no-op", function()
    fresh_process()
    S.open(SD, nil)
    S.set("seen_upto", 4)
    S.flush() -- must not throw and must not look for a file
    eq(S.get("seen_upto", nil), 4, "the value is still readable in memory")
end)

case("a clean flush writes nothing", function()
    fresh_process()
    S.open(SD, DIR)
    local before = H.read_file(FILE)
    S.set("seen_upto", S.get("seen_upto", 0)) -- the same value: not dirty
    S.flush()
    eq(H.read_file(FILE), before, "the file is untouched")
    eq(H.read_file(FILE .. ".tmp"), "", "no temp file is left behind")
end)

os.remove(FILE)
os.remove(FILE .. ".tmp")
os.execute('rm -rf "' .. DIR .. '*"')
H.finish()
