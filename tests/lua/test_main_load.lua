-- Author: Tim Harrison
-- Created: 2026-09-26
-- Updated: 2026-10-11

-- Spec for client/ue4ss_mod/srt_bridge/Scripts/main.lua module loading.
--
-- main.lua loads its optional modules through load_module(), which swaps in
-- an inert stub when require fails; a stub missing a field main later reads
-- kills the mod ("attempt to call a nil value", "table index is nil").
-- session_gate is core: a failed load must be one FATAL line and a clean stop
-- (no LoopAsync registered), not a crash halfway through init.
--
-- Loads the real main.lua under a stubbed UE4SS environment: logger (lines
-- collected, bridge dir -> a temp prefix), lua-apclientpp (records handlers),
-- FindFirstOf (a fake gamestate that is in play on a chosen game), LoopAsync
-- (captures the poll callback). util's safe() is wrapped to record every
-- error it swallows, so a stub gap inside the poll loop still fails the spec.
-- Run from the client repo root: lua tests/lua/test_main_load.lua

local here = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./"
local SCRIPTS = here .. "../../ue4ss_mod/srt_bridge/Scripts/"
local MAIN = SCRIPTS .. "main.lua"
package.path = SCRIPTS .. "?.lua;" .. package.path

local function read_file(path)
    local f = assert(io.open(path, "r"), "cannot open " .. path)
    local text = f:read("a")
    f:close()
    return text
end

-- every optional module main loads through load_module (so a new module is
-- covered without touching this spec), plus regions (its own FATAL path)
local OPTIONAL = {"regions"}
-- %s* tolerates a reformatted call that puts the name on its own line
for name in read_file(MAIN):gmatch('load_module%(%s*"([%w_%.]+)"') do
    OPTIONAL[#OPTIONAL + 1] = name
end

local TMP = os.tmpname()
os.remove(TMP)
local BRIDGE = TMP .. "_"

local lines, swallowed, loop_fn, ap_obj

local function fake_logger()
    local L = {cfg = {host = "ws://test", slot = "Tester", password = "",
                      game = "Spyro Reignited Trilogy", spawn_checkd = "0"},
               bridge_dir = BRIDGE}
    local function at(head) return function(l) lines[#lines + 1] = head .. tostring(l) end end
    L.log_info, L.log_warn, L.log_error, L.log_debug = at(""), at("WARN "), at("ERROR "), at("debug ")
    function L.tagged(tag, sink)
        local function emit(word, msg)
            local line = tag .. " " .. word .. tostring(msg)
            if sink then sink(line) else lines[#lines + 1] = line end
        end
        return {info = function(m) emit("", m) end, warn = function(m) emit("WARN ", m) end,
                error = function(m) emit("ERROR ", m) end, debug = function(m) emit("", m) end}
    end
    function L.leveled(tag, opt)
        if type(opt) == "table" then return opt end
        return L.tagged(tag, type(opt) == "function" and opt or nil)
    end
    return L
end

local function fake_util()
    local U = dofile(SCRIPTS .. "util.lua")
    U.safe = function(fn, default)
        local ok, res = pcall(fn)
        if ok then return res end
        swallowed[#swallowed + 1] = tostring(res)
        return default
    end
    return U
end

-- lua-apclientpp: AP(uuid, game, host) -> client; handlers are recorded so
-- the spec can fire slot_connected / items_received / disconnect itself
local function fake_ap()
    local AP = {ClientStatus = {GOAL = 30}}
    setmetatable(AP, {__call = function()
        local c = {handlers = {}, calls = {}}
        setmetatable(c, {__index = function(_, k)
            local h = k:match("^set_(.+)_handler$")
            if h then return function(self, fn) self.handlers[h] = fn end end
            return function(self, ...) self.calls[#self.calls + 1] = k end
        end})
        c.get_item_name = function(_, id) return id == 1 and "Spyro 1: Dragon" or "Extra Life" end
        c.get_player_number = function() return 1 end
        c.get_player_game = function() return "Spyro Reignited Trilogy" end
        c.get_location_name = function() return "somewhere" end
        c.get_player_alias = function() return "Friend" end
        c.get_server_time = function() return 0 end
        c.get_slot = function() return "Tester" end
        c.is_data_package_valid = function() return true end
        ap_obj = c
        return c
    end})
    return AP
end

local gs_state, gs_game = 0, 0
local GS = {
    IsValid = function() return true end,
    ["get slot index"] = function(out) out["slot index"] = 0 end,
    ["get game index"] = function(out) out["the game index"] = gs_game end,
}
setmetatable(GS, {__index = function(_, k)
    if k == "theCurrentGameState" then return gs_state end
    return nil
end})

local function load_main(failing)
    lines, swallowed, loop_fn, ap_obj = {}, {}, nil, nil
    gs_state, gs_game = 0, 0
    for _, name in ipairs({"logger", "util", "lua-apclientpp", "session_gate"}) do
        package.loaded[name] = nil
    end
    for _, name in ipairs(OPTIONAL) do package.loaded[name] = nil end
    package.preload["logger"] = fake_logger
    package.preload["util"] = fake_util
    package.preload["lua-apclientpp"] = fake_ap
    for name, v in pairs(package.preload) do
        if name ~= "logger" and name ~= "util" and name ~= "lua-apclientpp" then
            package.preload[name] = nil
        end
    end
    for _, name in ipairs(failing) do
        package.preload[name] = function() error("stubbed load failure: " .. name) end
    end
    FindFirstOf = function(cls) if cls == "FalconGameState_C" then return GS end end
    FindAllOf = function() return nil end
    LoopAsync = function(_, fn) loop_fn = fn end
    return pcall(dofile, MAIN)
end

local function count(pat)
    local n = 0
    for _, l in ipairs(lines) do if l:find(pat, 1, true) then n = n + 1 end end
    return n
end

local passed, total = 0, 0
local function case(name, fn)
    total = total + 1
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        print("PASS " .. name)
    else
        print("FAIL " .. name .. ": " .. tostring(err))
    end
end
local function check(cond, msg) if not cond then error(msg, 2) end end

case("session_gate load failure: one FATAL line, clean stop, no poll loop", function()
    local ok, err = load_main({"session_gate"})
    check(ok, "main.lua raised: " .. tostring(err))
    check(count("ERROR FATAL: session gate: require('session_gate') failed (") == 1,
        "expected one FATAL session gate line; got:\n" .. table.concat(lines, "\n"))
    check(count("ERROR ") == 1, "expected no other ERROR lines; got:\n" .. table.concat(lines, "\n"))
    check(loop_fn == nil, "LoopAsync was registered without a session gate")
end)

-- drives one full session on `game` with every optional module stubbed out:
-- open -> slot_connected -> items -> 480 polls (heartbeats) -> disconnect ->
-- main menu (close)
local function drive_session(game)
    local ok, err = load_main(OPTIONAL)
    check(ok, "main.lua raised: " .. tostring(err))
    check(type(loop_fn) == "function", "LoopAsync not registered")
    gs_game, gs_state = game, 3
    for _ = 1, 3 do check(loop_fn() == false, "poll loop returned true") end
    check(ap_obj ~= nil, "session never opened (no AP client)")
    local h = ap_obj.handlers
    h.room_info()
    h.slot_connected({locationNameToId = {["Spyro 1: Artisans: Free Nestor"] = 100011},
                      included_games = {"spyro1", "spyro2", "spyro3"},
                      games = {spyro1 = {options = {dragon_shuffle = "dragonsanity"}}}})
    h.location_info({{location = 100011, item = 2, player = 1}})
    h.items_received({{item = 1, index = 0, player = 1, location = 100011},
                      {item = 2, index = 1, player = 0, location = -1}})
    for _ = 1, 480 do loop_fn() end
    h.socket_disconnected()
    h.slot_connected({locationNameToId = {}})
    gs_state = 0
    loop_fn()
    check(count("Back at the main menu") == 1, "session did not close")
    check(#swallowed == 0, "errors swallowed by safe():\n" .. table.concat(swallowed, "\n"))
end

case("every optional module stubbed: Spyro 1 session runs end to end", function()
    drive_session(0)
    check(count("ERROR dragons: require('spyro1.dragons') failed (") == 1, "dragons stub not in use")
    check(count("[DRAGONS] hb: unavailable") == 1, "Spyro 1 heartbeat did not read the stub status")
end)
case("every optional module stubbed: Spyro 2 session runs end to end", function()
    drive_session(1)
    check(count("[LOCKS2] hb: unavailable") == 1, "Spyro 2 heartbeat did not read the stub status")
end)
case("every optional module stubbed: Spyro 3 session runs end to end", function()
    drive_session(2)
    check(count("[SPARX] hb: unavailable") == 1, "Spyro 3 heartbeat did not read the stub status")
end)

case("checks_drop still resolves ids after open_session resets id_to_name (regression)", function()
    local failing = {}
    for _, name in ipairs(OPTIONAL) do
        if name ~= "checks_drop" then failing[#failing + 1] = name end
    end
    local ok, err = load_main(failing)
    check(ok, "main.lua raised: " .. tostring(err))
    check(type(loop_fn) == "function", "LoopAsync not registered")
    gs_game, gs_state = 0, 3
    for _ = 1, 3 do loop_fn() end
    check(ap_obj ~= nil, "session never opened (no AP client)")
    local h = ap_obj.handlers
    h.room_info()
    h.slot_connected({locationNameToId = {["Spyro 1: Artisans: Free Nestor"] = 100011},
                      included_games = {"spyro1", "spyro2", "spyro3"},
                      games = {spyro1 = {options = {dragon_shuffle = "dragonsanity"}}}})
    local drop = assert(io.open(BRIDGE .. "checks.json", "w"))
    drop:write('{"seq":1,"checks":[100011],"names":["Spyro 1: Artisans: Free Nestor"]}')
    drop:close()
    loop_fn()
    local sent = false
    for _, c in ipairs(ap_obj.calls) do if c == "LocationChecks" then sent = true end end
    check(sent, "checks_drop never called LocationChecks for a real location id " ..
        "(id_to_name was reassigned out from under it in reset_session_state)")
end)

os.remove(BRIDGE .. "session.txt")
os.remove(BRIDGE .. "checks.json")
print(string.format("%d/%d passed", passed, total))
os.exit(passed == total and 0 or 1)
