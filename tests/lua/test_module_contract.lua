-- Author: Tim Harrison
-- Created: 2026-10-16
-- Updated: 2026-10-23

-- Spec for the host <-> module contract.
--
-- modules.lua is the one host-side description of every module; the host drives
-- each one by its shape and labels its heartbeat with the module's own tag. A
-- module renamed or moved without its inventory entry, a missing M.tag, or a
-- shape that stopped exposing a method the host calls would otherwise show up
-- only in play, as a silent no-op or a crash.
--
-- Run from the client repo root: lua tests/lua/test_module_contract.lua

local here = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./"
local SCRIPTS = here .. "../../ue4ss_mod/srt_bridge/Scripts/"
package.path = SCRIPTS .. "?.lua;" .. package.path

local function noop() end

-- The modules only need a logger at require time, and it must not touch the
-- real bridge log.
package.preload["logger"] = function()
    local L = { cfg = {}, bridge_dir = "/nonexistent/" }
    L.log_info, L.log_warn, L.log_error, L.log_debug = noop, noop, noop, noop
    L.tagged = function() return { info = noop, warn = noop, error = noop, debug = noop } end
    L.leveled = function() return L.tagged() end
    return L
end

local SESSION = require("session_gate")
local INVENTORY = require("modules")

-- Every mod script must be accounted for: an inventory entry, an L1 host part,
-- an L1 library, an L0 table or an L4 core. A file nobody loads is dead weight,
-- and one added here without an inventory entry would never run.
local ACCOUNTED = {
    -- L0 generated data
    ["regions.lua"] = true,
    ["constants.lua"] = true,
    -- L1 host parts
    ["main.lua"] = true,
    ["modules.lua"] = true,
    ["state.lua"] = true,
    ["checkd.lua"] = true,
    ["ap_client.lua"] = true,
    ["session.lua"] = true,
    ["watch.lua"] = true,
    -- L1 libraries
    ["logger.lua"] = true,
    ["util.lua"] = true,
    ["option.lua"] = true,
    ["session_gate.lua"] = true,
    ["game_state.lua"] = true,
    -- L4 cores
    ["level_locks_core.lua"] = true,
    ["reconcile_core.lua"] = true,
    ["inventory_grants_core.lua"] = true,
}
for _, entry in ipairs(INVENTORY) do
    ACCOUNTED[entry.name:gsub("%.", "/") .. ".lua"] = true
end

-- What the host calls on each shape.
local SHAPES = {
    plumbing = { "init", "tick" },
    watcher = { "init", "configure", "tick", "status" },
    reconcile = {
        "init", "configure", "note_item", "tick", "status",
        "is_item", "received", "last_extra", "arm_backlog",
        "reset_received", "note_disconnected", "reset",
    },
    display = { "init", "note_item", "note_sent", "note_system", "note_disconnected", "tick", "status", "reset" },
    sender = { "init", "configure", "status" },
}

local GAMES = { [SESSION.SPYRO1] = true, [SESSION.SPYRO2] = true, [SESSION.SPYRO3] = true }

-- The host capabilities a module's opts builder may read, and the members of the
-- AP seam (ap_client.handle). A builder reading anything else fails below, so a
-- new capability has to be added here deliberately.
local HOST_FIELDS = {
    regions = true, bridge_dir = true, checks_path = true, id_to_name = true,
    sent_checks = true, loc_id = true, notice = true, process_item = true, ap = true,
}
local AP_FIELDS = {
    connected = true, can_check = true, checks = true, drop_checks = true,
    bounce = true, goal = true, item_name = true, server_time = true,
    slot_name = true, player_number = true, sent_line = true,
}

--- Build a host table whose every read of an undocumented field throws.
local function strict_host()
    local function guard(known, label)
        return setmetatable({}, {
            __index = function(_, key)
                if not known[key] then
                    error(label .. "." .. tostring(key) .. " is not a documented host capability", 2)
                end
                return function() return true end
            end,
        })
    end
    local host = guard(HOST_FIELDS, "host")
    host.id_to_name, host.sent_checks = {}, {}
    host.regions = {}
    host.ap = guard(AP_FIELDS, "host.ap")
    return host
end

local failures, checked = 0, 0
local tags = {}

--- Record one failed check.
local function fail(entry_name, msg)
    failures = failures + 1
    print(string.format("FAIL %s: %s", entry_name, msg))
end

local function module_path(name)
    return SCRIPTS .. name:gsub("%.", "/") .. ".lua"
end

--- Load a module through the real require, or nil when it does not load.
local function load_module(name)
    package.loaded[name] = nil
    local ok, mod = pcall(require, name)
    return ok and mod or nil, mod
end

for _, entry in ipairs(INVENTORY) do
    checked = checked + 1
    local name = tostring(entry.name)

    local f = io.open(module_path(name), "r")
    if not f then
        fail(name, "no file at Scripts/" .. name:gsub("%.", "/") .. ".lua")
    else
        f:close()
    end

    if type(entry.name) ~= "string" or entry.name == "" then
        fail(name, "name must be a non-empty string")
    end

    local methods = SHAPES[entry.shape]
    if not methods then
        fail(name, "unknown shape " .. tostring(entry.shape))
    end

    local seen = {}
    for _, game in ipairs(entry.games or {}) do
        if not GAMES[game] then
            fail(name, "unknown session game " .. tostring(game))
        elseif seen[game] then
            fail(name, "duplicate session game " .. tostring(game))
        end
        seen[game] = true
    end

    if type(entry.opts) ~= "function" then
        fail(name, "opts must be a function of the host")
    else
        local ok, res = pcall(entry.opts, strict_host())
        if not ok or type(res) ~= "table" then
            fail(name, "opts(host) must return a table (" .. tostring(res) .. ")")
        end
    end

    local mod, err = load_module(name)
    if not mod then
        fail(name, "does not load: " .. tostring(err))
    else
        if type(mod.tag) ~= "string" or not mod.tag:match("^%[[A-Z0-9]+%]$") then
            fail(name, "M.tag must be a bracketed log tag, got " .. tostring(mod.tag))
        elseif tags[mod.tag] then
            fail(name, "tag " .. mod.tag .. " is already used by " .. tags[mod.tag])
        else
            tags[mod.tag] = name
        end
        for _, method in ipairs(methods or {}) do
            if type(mod[method]) ~= "function" then
                fail(name, "shape " .. entry.shape .. " must expose " .. method .. "()")
            end
        end
        -- The session reset sends a sender back to unconfigured, so it must not
        -- also carry a reset() (which would win).
        if entry.shape == "sender" and type(mod.reset) == "function" then
            fail(name, "a sender must not expose reset(); the host calls configure({})")
        end
    end
    print("ok   " .. name)
end

-- The AP seam: modules reach the server only through this handle, and it must
-- not expose anything that opens, closes or polls the connection.
local AP_LIFECYCLE = { "connect", "close", "poll", "data_package_valid", "available", "load_error" }
do
    checked = checked + 1
    local ok, ap = pcall(require, "ap_client")
    if not ok then
        fail("ap_client", "does not load: " .. tostring(ap))
    else
        local handle = ap.handle
        if type(handle) ~= "table" then
            fail("ap_client", "no handle table")
        else
            for field in pairs(AP_FIELDS) do
                if type(handle[field]) ~= "function" then
                    fail("ap_client.handle", "missing " .. field .. "()")
                end
            end
            for field in pairs(handle) do
                if not AP_FIELDS[field] then
                    fail("ap_client.handle", "undocumented member " .. tostring(field))
                end
            end
        end
        for _, field in ipairs(AP_LIFECYCLE) do
            if handle and handle[field] ~= nil then
                fail("ap_client.handle", "leaks the connection lifecycle: " .. field)
            end
        end
    end
    print("ok   ap_client.handle: the module-facing AP seam")
end

-- Orphan scan: every script under Scripts/ must be accounted for above.
do
    checked = checked + 1
    local orphans, total = {}, 0
    local p = assert(io.popen("find " .. SCRIPTS .. " -name '*.lua' -type f | sort", "r"))
    for path in p:lines() do
        total = total + 1
        local rel = path:match("Scripts/(.*)$")
        if not (rel and ACCOUNTED[rel]) then
            orphans[#orphans + 1] = tostring(rel)
        end
    end
    p:close()
    if #orphans == 0 then
        print("ok   all " .. total .. " scripts accounted for")
    else
        fail("orphans", table.concat(orphans, ", ")
            .. " (not an inventory entry, host part, library, generated table or core)")
    end
end

print(string.format("%d/%d passed", checked - failures, checked))
os.exit(failures == 0 and 0 or 1)