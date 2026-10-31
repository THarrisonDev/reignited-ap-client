-- Author: Tim Harrison
-- Created: 2026-10-21
-- Updated: 2026-10-23

-- Shared harness for the stub-based module specs: the UE4SS surfaces every
-- spec fakes (the game-thread queue, the fake clock, the world fixture, the
-- actor lookups), the module log sink, and the PASS/FAIL runners. Not a spec
-- itself: tests/lua/support/ sits outside the `make lua-tests` glob.

local support = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./"
package.path = support .. "../../../ue4ss_mod/srt_bridge/Scripts/?.lua;" .. package.path

local fixture = require("world_fixture")

local H = {}

H.support = support
H.scripts = support .. "../../../ue4ss_mod/srt_bridge/Scripts/"
H.fx = nil

--- Prepend a directory under tests/lua to package.path.
--- @param rel string Path relative to tests/lua, without a trailing slash.
function H.add_path(rel)
    package.path = support .. rel .. "/?.lua;" .. package.path
end

--- Return an FString stand-in whose ToString() yields s.
--- @param s string
--- @return table
function H.fstring(s)
    return { ToString = function() return s end }
end

--- Read a whole file, or "" when it cannot be opened.
--- @param path string
--- @return string
function H.read_file(path)
    local f = io.open(path, "r")
    if not f then return "" end
    local text = f:read("a")
    f:close()
    return text
end

--- The fake clock os.time reports, in seconds.
H.now = os.time()

--- Move the fake clock forward.
--- @param seconds number
function H.advance(seconds)
    H.now = H.now + seconds
end

os.time = function() return H.now end

--- True while a queued job runs; the fakes assert on it.
H.thread = false
H.queue = {}
H.installed = nil -- set by install_game_thread; the runner restores the fake

--- Queue a job the way UE4SS's ExecuteInGameThread does.
--- @param fn function
function H.queue_fn(fn)
    H.queue[#H.queue + 1] = fn
end

--- Install the ExecuteInGameThread fake.
function H.install_game_thread()
    H.queue = {}
    H.installed = true
    ExecuteInGameThread = H.queue_fn
end

--- Return how many jobs are queued.
--- @return number
function H.queued()
    return #H.queue
end

--- Drop every queued job.
function H.clear_queue()
    H.queue = {}
end

--- Run every queued job with the game-thread flag set.
function H.pump()
    local jobs = H.queue
    H.queue = {}
    for _, fn in ipairs(jobs) do
        H.thread = true
        fn()
        H.thread = false
    end
end

--- Run fn with the game-thread flag set (the game's own writes).
--- @param fn function
function H.as_game(fn)
    H.thread = true
    fn()
    H.thread = false
end

--- Build the world fixture over a path -> region map and keep it as H.fx.
--- @param regions table|nil
--- @return table
function H.new_fixture(regions)
    H.fx = fixture.new(regions)
    return H.fx
end

--- Update the snapshot and tick a module with it.
--- @param mod table Module under test.
--- @param gs table|nil Fake gamestate (the "game").
function H.tick(mod, gs)
    H.fx:tick(mod, gs)
end

--- Tick a module n times.
--- @param mod table Module under test.
--- @param gs table|nil Fake gamestate (the "game").
--- @param n number
function H.ticks(mod, gs, n)
    for _ = 1, n do H.fx:tick(mod, gs) end
end

--- Forget the fixture's level view, mirroring a session reset.
function H.reset_world()
    H.fx:reset()
end

--- Every module log line the current case produced.
H.lines = {}

--- Append one module log line.
--- @param line string
function H.collect(line)
    H.lines[#H.lines + 1] = line
end

--- Drop the collected log lines.
function H.clear_log()
    H.lines = {}
end

--- Report whether a log line matches pat.
--- @param pat string Lua pattern.
--- @param plain boolean|nil Match pat literally.
--- @return boolean
function H.logged(pat, plain)
    for _, l in ipairs(H.lines) do
        if l:find(pat, 1, plain) then return true end
    end
    return false
end

--- Count the log lines matching pat.
--- @param pat string Lua pattern.
--- @param plain boolean|nil Match pat literally.
--- @return number
function H.count_logged(pat, plain)
    local n = 0
    for _, l in ipairs(H.lines) do
        if l:find(pat, 1, plain) then n = n + 1 end
    end
    return n
end

--- Return the recorded fake calls made through fn.
--- @param calls table The fake's call record.
--- @param fn string
--- @return table
function H.calls_of(calls, fn)
    local out = {}
    for _, c in ipairs(calls) do
        if c.fn == fn then out[#out + 1] = c end
    end
    return out
end

--- Point FindAllOf at the actors in get() for class, and nil for any other.
--- @param class string UE4SS class name.
--- @param get function Returns the current actor list.
function H.find_all_of(class, get)
    FindAllOf = function(cls)
        if cls ~= class then return nil end
        local out = {}
        for _, a in ipairs(get()) do out[#out + 1] = a.actor end
        return out
    end
end

--- Point FindAllOf at the raw actors in get() for class, and nil for any other.
--- @param class string UE4SS class name.
--- @param get function Returns the current actor list.
function H.find_actors(class, get)
    FindAllOf = function(cls)
        if cls ~= class then return nil end
        local out = {}
        for _, a in ipairs(get()) do out[#out + 1] = a end
        return out
    end
end

--- Build a fake gamestate that answers only the current level.
--- @param get_level function Returns the level path.
--- @return table
function H.level_gs(get_level)
    return setmetatable({}, { __index = function(_, k)
        if k == "current level" then return H.fstring(get_level()) end
    end })
end

H.cases, H.case_failures = 0, 0
H.checks, H.check_failures = 0, 0
H.before = nil

--- Register a function the case runner calls before each case.
--- @param fn function
function H.before_each(fn)
    H.before = fn
end

--- Run one named case, dumping the module log when it fails.
--- @param name string
--- @param fn function
function H.test(name, fn)
    H.cases = H.cases + 1
    if H.before then H.before() end
    local ok, err = pcall(fn)
    if ok then
        print("PASS " .. name)
    else
        H.case_failures = H.case_failures + 1
        print("FAIL " .. name .. ": " .. tostring(err))
        for _, l in ipairs(H.lines) do print("    | " .. l) end
    end
    if H.installed then ExecuteInGameThread = H.queue_fn end
end

--- Check one condition, printing PASS/FAIL with its message.
--- @param cond any
--- @param msg string
function H.ok(cond, msg)
    H.checks = H.checks + 1
    if cond then
        print("PASS " .. msg)
    else
        H.check_failures = H.check_failures + 1
        print("FAIL " .. msg)
    end
end

--- Assert equality, naming the field on failure.
--- @param got any
--- @param want any
--- @param what string
function H.eq(got, want, what)
    if got ~= want then
        error(string.format("%s: got %s, want %s", what, tostring(got), tostring(want)), 2)
    end
end

--- Build a check recorder that reports only failures.
--- @param emit function|nil Printer for the report lines (default print).
--- @return function, function  check(name, cond, extra) and done(label).
function H.checker(emit)
    emit = emit or print
    local failures = 0
    local function check(name, cond, extra)
        if cond then return end
        failures = failures + 1
        emit("FAIL: " .. name .. (extra and (" (" .. extra .. ")") or ""))
    end
    local function done(label)
        emit(failures == 0 and (label .. ": OK") or (label .. ": " .. failures .. " failures"))
        return failures
    end
    return check, done
end

--- Print the pass count and exit with the runner's status.
function H.finish()
    if H.cases > 0 then
        print(string.format("%d/%d passed", H.cases - H.case_failures, H.cases))
        os.exit(H.case_failures == 0 and 0 or 1)
    end
    print(string.format("%d/%d passed", H.checks - H.check_failures, H.checks))
    os.exit(H.check_failures == 0 and 0 or 1)
end

return H
