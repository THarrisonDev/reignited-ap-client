-- Author: Tim Harrison
-- Created: 2026-09-26
-- Updated: 2026-10-23

-- Mod scripts must never reach a local by its global name.
--
-- A `local function f` called above its definition compiles to a global
-- lookup of `f`, which is nil at runtime; inside safe()/pcall the error is
-- swallowed and the caller silently stops (the Sept 2026 poll_dragons bug).
-- `luac -l` lists every global read (GETTABUP _ENV "name"), so any local
-- function/variable name that also shows up there is that bug.
--
-- Run from the client repo root: lua tests/lua/test_mod_globals.lua

local DIR = "ue4ss_mod/srt_bridge/Scripts/"

-- Every mod script, discovered rather than listed, so a new file is covered
-- without touching this spec.
local FILES = {}
do
    local p = assert(io.popen("find " .. DIR .. " -name '*.lua' -type f | sort", "r"))
    for path in p:lines() do
        FILES[#FILES + 1] = path:gsub("^" .. DIR, "")
    end
    p:close()
    assert(#FILES > 0, "no mod scripts found under " .. DIR)
end

local LUAC = "luac"
if os.execute("command -v luac5.4 >/dev/null 2>&1") then LUAC = "luac5.4" end

local failures, checked = 0, 0

local function read_file(path)
    local f = assert(io.open(path, "r"), "cannot open " .. path)
    local text = f:read("a")
    f:close()
    return text
end

local function global_reads(path)
    local p = assert(io.popen(LUAC .. " -l -p " .. path .. " 2>&1", "r"))
    local listing = p:read("a")
    p:close()
    assert(listing:find("GETTABUP") or listing:find("main <"), "luac -l produced no listing for " .. path .. ":\n" .. listing)
    local names = {}
    for name in listing:gmatch('GETTABUP[^\n]-_ENV "([%a_][%w_]*)"') do
        names[name] = true
    end
    return names
end

for _, file in ipairs(FILES) do
    local path = DIR .. file
    local locals = {}
    for name in read_file(path):gmatch("\nlocal function ([%a_][%w_]*)") do locals[name] = true end
    for names in read_file(path):gmatch("\nlocal ([%a_][%w_, ]*)") do
        for name in names:gmatch("[%a_][%w_]*") do locals[name] = true end
    end
    local bad = {}
    for name in pairs(global_reads(path)) do
        if locals[name] then bad[#bad + 1] = name end
    end
    table.sort(bad)
    checked = checked + 1
    if #bad > 0 then
        failures = failures + 1
        print(string.format("FAIL %s: locals reached as globals (used above their definition?): %s",
            file, table.concat(bad, ", ")))
    else
        print("ok   " .. file .. ": no local reached as a global")
    end
end

print(string.format("%d/%d passed", checked - failures, checked))
os.exit(failures == 0 and 0 or 1)
