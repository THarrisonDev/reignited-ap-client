-- Author: Tim Harrison
-- Created: 2026-09-29
-- Updated: 2026-11-02

-- Spec for client/ue4ss_mod/srt_bridge/Scripts/hud_banner.lua. Fakes the UE4SS
-- surface (FindFirstOf, StaticFindObject, timers, game thread, the fanfare
-- widget) and drives the host tick, verifying the burst contract: one fanfare
-- per burst, the Intro frozen to hold the window, one text swap per line,
-- handed back by resuming the Intro so the widget's own chain closes it, the
-- frozen window held as a verified lease.
-- Run from the client repo root: lua tests/lua/test_hud_banner.lua

package.path = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "support/?.lua;" .. package.path
local H = require("harness")
local fanfare = require("fanfare")

local check, done = H.checker()

-- fake UE4SS surface -------------------------------------------------------
local jobs, timers = {}, {}
local in_job, nested = false, 0

local fake_now = H.now
os.time = function() return fake_now end

ExecuteInGameThread = function(fn)
    if in_job then nested = nested + 1 end -- game thread -> game thread wedges UE4SS
    jobs[#jobs + 1] = fn
end
ExecuteWithDelay = function(ms, fn) timers[#timers + 1] = { ms = ms, fn = fn } end

--- Run the queued game-thread jobs once.
local function run_jobs()
    local js = jobs
    jobs = {}
    for _, fn in ipairs(js) do
        in_job = true
        fn()
        in_job = false
    end
end

--- Run the queued timers once, advancing the clock by their delays.
local function run_timers()
    local ts = timers
    timers = {}
    for _, t in ipairs(ts) do
        fake_now = fake_now + (t.ms or 0) / 1000
        t.fn()
    end
end

--- Run queued game-thread jobs and due timers until both are empty.
local function pump()
    for _ = 1, 2000 do
        local js = jobs
        jobs = {}
        for _, fn in ipairs(js) do
            in_job = true
            fn()
            in_job = false
        end
        local ts = timers
        timers = {}
        for _, t in ipairs(ts) do
            fake_now = fake_now + (t.ms or 0) / 1000
            t.fn()
        end
        if #jobs == 0 and #timers == 0 then return end
    end
end

local writes, fanfares = {}, 0
local widget, decoy

--- Build the fake fanfare widget: State follows the frozen window and the
--- widget's own chain, the property is the lever, and Base mirrors the frame.
local function new_widget()
    local w = {
        _prop = "Rescued ",
        _base = "Rescued ",
        _window_until = 0,
        _paused = false,
        _hold = false,
        _state_written = nil,
        _intro_time = 0,
        _valid = true,
        intro_stops = 0,
        intro_plays = 0,
        outros = 0,
    }
    w.Intro = { GetStartTime = function() return 0 end, GetEndTime = function() return 0.6 end }
    w.Outro = { GetStartTime = function() return 0 end, GetEndTime = function() return 0.267 end }
    w.Base = {
        SetText = function(_, ft) w._base = ft and ft.text or "?" end,
        GetText = function() return { ToString = function() return "" end } end, -- blank while held
    }
    w.IsValid = function() return w._valid end
    w.PauseAnimation = function()
        w._paused = true
        w._intro_time = 0.3
        return w._intro_time
    end
    w.GetAnimationCurrentTime = function() return w._intro_time end
    w.StopAnimation = function()
        w.intro_stops = w.intro_stops + 1
        if fanfare.release_ignored(w) then return end -- the game cannot animate: no Outro
        w._paused = false
        w._hold = false
        w._intro_time = 0
        w._window_until = 0
    end
    w.PlayAnimation = function(_, anim, start)
        if anim == w.Outro then
            w.outros = w.outros + 1
            return
        end
        w.intro_plays = w.intro_plays + 1
        w.intro_start = start
        fanfare.resume(w)
    end
    return fanfare.attach(w, function() return fake_now end, function(text)
        writes[#writes + 1] = text
    end)
end

local function hud_obj()
    return {
        IsValid = function() return true end,
        ShowFanfare = function(a, b, c) -- dot call: (type, name); colon: (self, type, name)
            fanfares = fanfares + 1
            widget._window_until = fake_now + 2.8
            widget._paused, widget._hold, widget._state_written = false, false, nil
            local name = c or b
            assert(name == "Nestor", "fanfare stand-in name")
        end,
    }
end

local function install()
    widget, decoy = new_widget(), nil
    writes, fanfares, nested = {}, 0, 0
    jobs, timers = {}, {}
    local hud = hud_obj()
    FindFirstOf = function(class)
        if class == "PlayerController" then return { GetHUD = function() return hud end } end
        if class == "UI_FanFareMessage_C" then return decoy or widget end
        return nil
    end
    StaticFindObject = function(path)
        if path == "/Script/Engine.Default__KismetTextLibrary" then
            return {
                IsValid = function() return true end,
                Conv_StringToText = function(_, s)
                    return { text = s, ToString = function() return s end }
                end,
            }
        end
        return nil
    end
    return widget
end

local banner = require("hud_banner")
local logs = {}

-- An isolated state directory: the banner's watermark lives in
-- srtap_<seed>_<slot>.txt there, never in the real bridge dir.
local STATEDIR = os.tmpname()
os.remove(STATEDIR)
os.execute('mkdir -p "' .. STATEDIR .. '"')
STATEDIR = STATEDIR .. "/"
local SD = { seed = "S1", slot = "P1" }
local STATE_FILE = STATEDIR .. "srtap_S1_P1.txt"

--- Write the state file by hand, as a previous session would have left it.
local function write_state(text)
    local f = assert(io.open(STATE_FILE, "w"))
    f:write(text)
    f:close()
end

--- Point the state module at a scratch slot so the next configure() reloads this
--- seed+slot's file from disk (it caches the file it already loaded).
local function uncache_state()
    banner.configure({ seed = "S0", slot = "P0" })
end


local function fresh(sd)
    local old = widget
    if old then old._valid = false end -- the previous case's widget is gone
    install()
    logs = {}
    banner.reset()
    pump()
    banner.tick() -- confirm any lease the previous case left on that widget
    pump()
    banner.init({
        log = function(line) logs[#logs + 1] = line end,
        dir = STATEDIR,
    })
    if sd then banner.configure(sd) end
    return widget
end

--- Make the fanfare lookup miss the next n polls, then hand back the restore.
--- @param n number Polls to miss.
--- @return function Restores the real lookup.
local function miss_lookups(n)
    local real = FindFirstOf
    local left = n
    FindFirstOf = function(class)
        if class == "UI_FanFareMessage_C" and left > 0 then
            left = left - 1
            return nil
        end
        return real(class)
    end
    return function() FindFirstOf = real end
end

--- Return every captured log line joined.
local function log_text()
    return table.concat(logs, "\n")
end

--- Return whether a status line carries field=value as a whole field.
local function has(st, kv)
    return (" " .. st .. " "):find(" " .. kv .. " ", 1, true) ~= nil
end

--- Return how many captured log lines carry needle.
local function count_log(needle)
    local n = 0
    for _, line in ipairs(logs) do
        if line:find(needle, 1, true) then n = n + 1 end
    end
    return n
end

local TICK = 250 -- the host poll interval the module paces itself against
local IDLE_TICKS = 120 -- mirrors the module's game's-own-window budget (~30s at TICK)
local OPENING_TICKS = 8 -- mirrors the module's timer-loss budget (~2s at TICK)
local RESUME_VERIFY_TICKS = 16 -- mirrors the module's resumed-Intro window (~4s)
local FALLBACK_VERIFY_TICKS = 4 -- mirrors the module's legacy-close window (~1s)
local NOT_IN_PLAY = { not_in_play = true } -- the snapshot while the game is not in play

--- Advance n host ticks, moving the poll clock and pumping work after each.
--- @param n number Ticks to advance.
--- @param not_in_play boolean|nil Tick with a not-in-play snapshot.
local function advance(n, not_in_play)
    for _ = 1, n do
        fake_now = fake_now + TICK / 1000
        banner.tick(not_in_play and NOT_IN_PLAY or nil)
        pump()
        fanfare.tick() -- the widget's own chain runs on its own clock
    end
end

--- Run a resumed window's own chain out (Intro -> Delay -> Outro -> state 0).
local function settle()
    for _ = 1, fanfare.CHAIN_TICKS do fanfare.tick() end
end

--- Queue one item and open its burst, landing the first line and the freeze.
--- @param name string Item name.
local function open_burst(name)
    banner.note_item(name)
    advance(1)
    pump()
end

--- Advance until the burst goes idle, optionally after an expected write count
--- (a spill passes through idle between windows), then let the widget's chain
--- finish its hand-back.
local function drain(expected)
    for _ = 1, 400 do
        local st = banner.status()
        if has(st, "state=idle") and (not expected or #writes == expected) then
            settle()
            return
        end
        advance(1)
    end
end

--- Assert the legacy fallback ran, warned once, and settled the lease.
local function settled_by_fallback(w)
    check("the fallback stopped the Intro", w.intro_stops == 1, tostring(w.intro_stops))
    check("the fallback parked State", w._state_written == 0, tostring(w._state_written))
    check("one WARN naming the fallback", count_log("fanfare release fallback") == 1, log_text())
    advance(FALLBACK_VERIFY_TICKS + 2)
    check("the lease is confirmed and cleared", has(banner.status(), "lease=none/0"), banner.status())
end

--- Submit an open and let the opening frame time out without its timers.
local function time_out_opening()
    fake_now = fake_now + TICK / 1000
    banner.tick() -- submit the open job
    run_jobs() -- fire the fanfare and arm the timers
    check("the burst is opening", has(banner.status(), "state=opening"), banner.status())
    for _ = 1, OPENING_TICKS + 1 do
        fake_now = fake_now + TICK / 1000
        banner.tick() -- the timers never land: the opening ticks out
    end
    check("the opening timeout drops the burst", has(banner.status(), "state=idle"), banner.status())
end

--- Open a burst on two items and return the widget with its first line up.
local function open_two_lines()
    local w = fresh()
    banner.note_item("A")
    banner.note_item("B")
    advance(1)
    pump()
    for _ = 1, 25 do -- a job the previous case left behind can hold the runner
        if has(banner.status(), "state=open") then break end
        advance(1)
        pump()
    end
    check("burst open", has(banner.status(), "state=open"), banner.status())
    check("first line up", w._prop == "Received A", w._prop)
    return w
end


-- one item = one fanfare, first line, freeze, then the hand-back
do
    local w = fresh()
    banner.note_item("Nestor's Key")
    fake_now = fake_now + TICK / 1000
    banner.tick() -- submits the open job
    run_jobs() -- fire, arm the write and freeze timers
    check("one fanfare", fanfares == 1, tostring(fanfares))
    check("no write before the lead-in", #writes == 0, tostring(#writes))
    run_timers() -- +100ms write, +450ms freeze
    run_jobs()
    check("first line written", writes[1] == "Received Nestor's Key", tostring(writes[1]))
    check("property holds the line", w._prop == "Received Nestor's Key", w._prop)
    check("Base written for this frame", w._base == "Received Nestor's Key", w._base)
    check("Intro frozen", w._paused == true)
    check("window open", w.State == 1, tostring(w.State))
    check("status shows open", has(banner.status(), "state=open"), banner.status())
    drain() -- hold for the dwell, then hand the window back
    check("only one line written", #writes == 1, tostring(#writes))
    check("the Intro was resumed", w.resumed == 1, tostring(w.resumed))
    check("the module never stopped the Intro", w.intro_stops == 0, tostring(w.intro_stops))
    check("the module never wrote State", w._state_written == nil, tostring(w._state_written))
    check("the widget's own chain closed the window", w.State == 0, tostring(w.State))
    check("back to idle", has(banner.status(), "state=idle"), banner.status())
    check("shown counter", has(banner.status(), "shown=1"), banner.status())
end

-- a run of items rides one fanfare, in order, one line each
do
    local w = fresh()
    for _, name in ipairs({ "A", "B", "C" }) do banner.note_item(name) end
    advance(1)
    pump()
    check("one fanfare for three items", fanfares == 1, tostring(fanfares))
    check("first line", writes[1] == "Received A", table.concat(writes, ","))
    drain()
    check("all three lines in order", table.concat(writes, ",") == "Received A,Received B,Received C", table.concat(writes, ","))
    check("one hand-back for the burst", w.resumed == 1, tostring(w.resumed))
    check("the widget closed itself once", w.closed == 1, tostring(w.closed))
    check("shown counter", has(banner.status(), "shown=3"), banner.status())
end

-- a long backlog is shown in full, spilling at the window budget
do
    local w = fresh()
    for i = 1, 30 do banner.note_item("Item " .. i) end
    advance(1)
    pump()
    check("the window's length follows the queue",
        log_text():find("burst open: 30 line(s) from 30 queued, holding ~30.0s", 1, true) ~= nil, log_text())
    for _ = 1, 400 do
        local st = banner.status()
        if has(st, "state=idle") and has(st, "waiting=0") then break end
        advance(1)
    end
    check("every item shown", #writes == 30, tostring(#writes))
    check("in order", writes[1] == "Received Item 1" and writes[30] == "Received Item 30",
        (writes[1] or "") .. "..." .. (writes[#writes] or ""))
    check("budget spills into a second window", fanfares == 2, tostring(fanfares))
    check("the spill is logged",
        log_text():find("burst closed at the budget, 15 line(s) left", 1, true) ~= nil, log_text())
    check("the queue drained", has(banner.status(), "waiting=0"), banner.status())
end

-- repeats collapse into one counted line (the reason for batching)
do
    local w = fresh()
    for _ = 1, 32 do banner.note_item("Dragon Egg") end
    banner.note_item("Extra Life")
    advance(1)
    pump()
    check("a short burst", log_text():find("burst open: 2 line(s) from 33 queued, holding ~2.0s", 1, true) ~= nil,
        log_text())
    check("every item counted as queued", has(banner.status(), "queued=33"), banner.status())
    drain(2)
    check("two lines for 33 items", #writes == 2, tostring(#writes))
    check("the repeat is counted", writes[1] == "Received 32x Dragon Egg", table.concat(writes, " | "))
    check("the single stays singular", writes[2] == "Received Extra Life", table.concat(writes, " | "))
    check("two lines shown", has(banner.status(), "shown=2"), banner.status())
    check("one closed window for the pair", w.closed == 1, tostring(w.closed))
end

-- sent checks are always individual, even when identical
do
    local w = fresh()
    for _ = 1, 3 do banner.note_sent("To Bob: Orb") end
    advance(1)
    pump()
    check("the burst holds three lines", log_text():find("burst open: 3 line(s) from 3 queued", 1, true) ~= nil,
        log_text())
    drain(3)
    check("three separate lines", #writes == 3, tostring(#writes))
    check("verbatim, one per check",
        table.concat(writes, " | ") == "To Bob: Orb | To Bob: Orb | To Bob: Orb",
        table.concat(writes, " | "))
    check("all three counted", has(banner.status(), "sent=3"), banner.status())
end

-- a mixed batch keeps items first, sends one per check
do
    local w = fresh()
    for _ = 1, 2 do banner.note_item("Gem") end
    banner.note_sent("To Bob: Orb")
    banner.note_sent("To Bob: Orb")
    advance(1)
    pump()
    drain(3)
    check(
        "collapsed items first, then every send",
        table.concat(writes, " | ") == "Received 2x Gem | To Bob: Orb | To Bob: Orb",
        table.concat(writes, " | ")
    )
end

-- received items outrank sent lines
do
    local w = fresh()
    banner.note_sent("To Bob: Orb")
    banner.note_item("Dragon")
    advance(1)
    pump()
    drain()
    check("item shown first", writes[1] == "Received Dragon", table.concat(writes, ","))
    check("sent line follows", writes[2] == "To Bob: Orb", table.concat(writes, ","))
    check("sent counted", has(banner.status(), "sent=1"), banner.status())
end

-- a checkd notice preempts the waiting queues
do
    local w = fresh()
    banner.note_item("Item A")
    banner.note_item("Item B")
    banner.note_system("Save Scanning Failed!")
    advance(1)
    pump()
    drain()
    check("notice shown", writes[1] == "Save Scanning Failed!", table.concat(writes, ","))
    check("queued item dropped", table.concat(writes, ","):find("Item B", 1, true) == nil,
        table.concat(writes, ","))
end

-- never inject while the game's own fanfare is up
do
    local w = fresh()
    w._window_until = fake_now + 2.8 -- the game is mid-fanfare
    banner.note_item("Waits")
    advance(1)
    check("no fanfare while busy", fanfares == 0, tostring(fanfares))
    advance(14) -- let the game's window lapse
    check("fires once idle", fanfares == 1, tostring(fanfares))
    pump()
    check("line lands", writes[1] == "Received Waits", tostring(writes[1]))
end

-- the widget dies mid-burst — the burst is abandoned, not crashed
do
    local w = fresh()
    banner.note_item("A")
    banner.note_item("B")
    advance(1)
    pump()
    check("first line up", w._prop == "Received A", w._prop)
    w._valid = false
    advance(8)
    check("burst abandoned", has(banner.status(), "state=idle"), banner.status())
    local before = #writes
    advance(8)
    check("no writes after the widget died", #writes == before, tostring(#writes))
end

-- no HUD (menu/loading) is a quiet retry, not a stream of warnings
do
    local warned = 0
    install()
    banner.reset()
    banner.init({ log = function() warned = warned + 1 end })
    FindFirstOf = function() return nil end
    banner.note_item("Later")
    advance(6)
    check("nothing fired without a HUD", fanfares == 0, tostring(fanfares))
    check("no warning spam", warned == 0, tostring(warned))
end

-- a mismatch means the window is the game's — one hand-back, no re-assert,
-- and no further write while the game holds it
do
    local w = fresh()
    banner.note_item("Holds")
    advance(1)
    pump()
    check("line up", w._prop == "Received Holds", w._prop)
    local before = #writes
    w._prop = "Rescued " -- the widget's own show next message took the text
    advance(1)
    check("the game's text survives", w._prop == "Rescued ", w._prop)
    check("no write lands after it", #writes == before, table.concat(writes, ","))
    advance(3)
    check("the burst stays dropped", has(banner.status(), "state=idle"), banner.status())
    check("the line is requeued, not lost", has(banner.status(), "waiting=1"), banner.status())
    check("still nothing written into the game's window", #writes == before, table.concat(writes, ","))
end

-- after a burst closes, the next item opens a new window
do
    local w = fresh()
    banner.note_item("First")
    advance(1)
    pump()
    drain()
    check("one fanfare so far", fanfares == 1, tostring(fanfares))
    banner.note_item("Second")
    advance(3) -- a gap of ticks precedes a new burst
    check("second fanfare", fanfares == 2, tostring(fanfares))
    pump()
    check("second line up", w._prop == "Received Second", w._prop)
    drain()
end

-- status and reset
do
    local w = fresh()
    banner.note_item("A")
    banner.note_sent("S")
    local st = banner.status()
    check(
        "status fields",
        has(st, "queued=1") and has(st, "sent_queued=1") and has(st, "waiting=2")
            and has(st, "idle_open=0") and st:find("lease=", 1, true) ~= nil,
        st
    )
    banner.reset()
    st = banner.status()
    check("reset clears", has(st, "queued=0") and has(st, "waiting=0") and has(st, "state=idle"), st)
    banner.note_item("After reset")
    advance(1)
    pump()
    check("still works after reset", w._prop == "Received After reset", w._prop)
    drain()
end

-- reset while open hands the frozen widget back, not leaving it stuck
do
    local w = fresh()
    banner.note_item("Held")
    advance(1)
    pump()
    check("burst open", has(banner.status(), "state=open"), banner.status())
    banner.reset()
    pump()
    settle()
    check("reset resumed the frozen Intro", w.resumed == 1, tostring(w.resumed))
    check("reset never stops or rewrites it", w.intro_stops == 0 and w._state_written == nil,
        tostring(w.intro_stops) .. "/" .. tostring(w._state_written))
    check("idle after reset", has(banner.status(), "state=idle"), banner.status())
    banner.note_item("After reset")
    advance(3)
    pump()
    check("a later item opens a new fanfare", fanfares == 2, tostring(fanfares))
    check("its line lands", writes[#writes] == "Received After reset", table.concat(writes, ","))
    drain()
end

-- a single missed lookup is not destruction; three in a row is
do
    local w = fresh()
    banner.note_item("Debounce")
    advance(1)
    pump()
    check("burst open", has(banner.status(), "state=open"), banner.status())
    local restore = miss_lookups(1)
    advance(1)
    restore()
    check("one miss keeps the burst", has(banner.status(), "state=open"), banner.status())
    check("the Intro stays frozen", w._paused == true, tostring(w._paused))
    check("one miss is quiet", log_text():find("WARN", 1, true) == nil, log_text())
    drain()
    check("the burst finishes normally", w.closed == 1, tostring(w.closed))
end
do
    local w = fresh()
    banner.note_item("Vanishing")
    advance(3) -- the gap left by the previous close
    pump()
    check("second burst open", has(banner.status(), "state=open"), banner.status())
    local restore = miss_lookups(3)
    advance(3)
    restore()
    settle()
    check("three misses drop the burst", has(banner.status(), "state=idle"), banner.status())
    check("the drop is logged",
        log_text():find("went missing 3 polls running", 1, true) ~= nil, log_text())
    check("the abandoned burst is handed back", w.resumed == 1, tostring(w.resumed))
    check("one closed window for the abandoned burst", w.closed == 1, tostring(w.closed))
end

-- close hands back the widget this burst froze, never a fresh instance
do
    local w = fresh()
    banner.note_item("Old")
    advance(1)
    pump()
    check("burst open", has(banner.status(), "state=open"), banner.status())
    local old = w
    w = new_widget() -- a level transition replaced the widget under the burst
    widget = w
    w._prop = old._prop -- no re-assert churn: drive straight to the dwell close
    drain()
    check("the held widget was resumed", old.resumed == 1, tostring(old.resumed))
    check("the held widget closed itself", old.closed == 1, tostring(old.closed))
    check("the fresh instance is untouched", w.closed == nil and w._paused == false, tostring(w.closed))
end

-- a repaint loop never fights — every burst hands back on its first
-- mismatch, and no line is lost
do
    local w = fresh()
    banner.note_item("Repaint")
    advance(1)
    pump()
    check("burst open", has(banner.status(), "state=open"), banner.status())
    w._prop = "Rescued "
    advance(1)
    check("the first steal hands back at once", has(banner.status(), "state=idle"), banner.status())
    check("no release for the game's window", (w.resumed or 0) == 0 and w.intro_stops == 0,
        tostring(w.resumed) .. "/" .. tostring(w.intro_stops))
    w._paused, w._hold, w._window_until = false, false, 0 -- the game's message ends
    advance(4)
    pump()
    check("the requeued line gets its own burst", has(banner.status(), "state=open"), banner.status())
    w._prop = "Rescued " -- stolen a second time
    advance(1)
    check("stolen again, handed back again", has(banner.status(), "state=idle"), banner.status())
    check("two steals, zero re-asserts", count_log("game fanfare took the window") == 2, log_text())
    check("the line is still requeued", has(banner.status(), "waiting=1"), banner.status())
end

-- a widget that cannot say where its Intro stopped gets the legacy close at
-- once, never a resume of an animation that is not paused
do
    local w = fresh()
    open_burst("NoTime")
    w.GetAnimationCurrentTime = nil -- not paused, or the API is unavailable
    drain()
    check("no resume was attempted", (w.resumed or 0) == 0, tostring(w.resumed))
    check("the fallback played the Outro", w.outros == 1, tostring(w.outros))
    settled_by_fallback(w)
end

-- a socket drop hands back the burst and saves its unwritten lines
do
    local w = fresh()
    for _, name in ipairs({ "A", "B", "C" }) do banner.note_item(name) end
    advance(1)
    pump()
    check("first line up", w._prop == "Received A", w._prop)
    banner.note_disconnected()
    pump()
    check("disconnect resumes the Intro", w.resumed == 1, tostring(w.resumed))
    check("never written by the module", w._state_written == nil and w.intro_stops == 0,
        tostring(w._state_written) .. "/" .. tostring(w.intro_stops))
    check("idle after the drop", has(banner.status(), "state=idle"), banner.status())
    check("the unwritten lines came back", has(banner.status(), "waiting=2"), banner.status())
    advance(4)
    pump()
    drain()
    check("the next burst shows them", table.concat(writes, ",") == "Received A,Received B,Received C",
        table.concat(writes, ","))
end

-- a burst dropped in the opening frame never resurrects
do
    local w = fresh()
    banner.note_item("Opening")
    time_out_opening()
    check("nothing was frozen", w._paused == false, tostring(w._paused))
    run_timers() -- the armed write and freeze land after the drop
    run_jobs()
    check("the stale freeze never lands", w._paused == false, tostring(w._paused))
    check("still idle", has(banner.status(), "state=idle"), banner.status())
    check("no release for a freeze never owned", (w.resumed or 0) == 0 and w.intro_stops == 0,
        tostring(w.resumed) .. "/" .. tostring(w.intro_stops))
end

-- a disconnect during the lead-in keeps every line
do
    local w = fresh()
    banner.note_item("A")
    banner.note_item("B")
    fake_now = fake_now + TICK / 1000
    banner.tick() -- submit the open job
    run_jobs() -- fire the fanfare and arm the timers
    local ts = timers
    timers = {}
    -- deliver the freeze only: the first line's write has not landed yet
    fake_now = fake_now + (ts[2].ms or 0) / 1000
    ts[2].fn()
    run_jobs()
    check("the burst is open", has(banner.status(), "state=open"), banner.status())
    check("the lead-in line is unwritten", w._prop == "Rescued ", w._prop)
    banner.note_disconnected()
    pump()
    check("the frozen Intro is resumed", w.resumed == 1, tostring(w.resumed))
    check("the module wrote no State", w._state_written == nil, tostring(w._state_written))
    check("both lines are waiting", has(banner.status(), "waiting=2"), banner.status())
    advance(3)
    pump()
    drain()
    check("the next burst shows both", table.concat(writes, ",") == "Received A,Received B",
        table.concat(writes, ","))
end

-- a window the module holds no lease on is the game's own
do
    local w = fresh()
    w._paused = true -- State == 1, but this module never froze it
    advance(IDLE_TICKS - 2)
    check("no release", (w.resumed or 0) == 0 and w.intro_stops == 0,
        tostring(w.resumed) .. "/" .. tostring(w.intro_stops))
    check(
        "quiet before the budget",
        count_log("leaving the game's own window alone") == 0,
        log_text()
    )
    advance(4)
    check("one WARN after ~30s", count_log("leaving the game's own window alone") == 1, log_text())
    advance(IDLE_TICKS)
    check(
        "stays quiet afterwards",
        count_log("leaving the game's own window alone") == 1,
        log_text()
    )
    check("never released", (w.resumed or 0) == 0 and w.intro_stops == 0,
        tostring(w.resumed) .. "/" .. tostring(w.intro_stops))
    check("the game still holds it", w._paused == true, tostring(w._paused))
    check("no lease", has(banner.status(), "lease=none/0"), banner.status())
end

-- an opening timeout puts its lines back for the next burst
do
    fresh()
    banner.note_item("Lost")
    banner.note_item("Found")
    time_out_opening()
    check("both lines came back", has(banner.status(), "waiting=2"), banner.status())
    advance(3)
    pump()
    drain()
    check("the next burst shows both", table.concat(writes, ",") == "Received Lost,Received Found",
        table.concat(writes, ","))
end

-- a hand-back that lands nowhere is relinquished, once, after the one
-- resume and the one fallback
do
    local w = fresh()
    fanfare.refuse_chain(w) -- the resumed Intro never finishes
    fanfare.refuse(w, 1) -- and the legacy close lands nowhere either
    open_burst("Stuck")
    drain()
    advance(RESUME_VERIFY_TICKS + 2)
    check("the one fallback ran", w.intro_stops == 1, tostring(w.intro_stops))
    advance(FALLBACK_VERIFY_TICKS + 2)
    check("exactly one WARN", count_log("fanfare release relinquished") == 1, log_text())
    check("the lease is cleared", has(banner.status(), "lease=none/0"), banner.status())
    advance(30)
    check("no attempt after the relinquish", w.intro_stops == 1, tostring(w.intro_stops))
    check("still one WARN", count_log("fanfare release relinquished") == 1, log_text())
    w._state_written = 0 -- the game finally closed its own window
    banner.note_item("After")
    advance(4)
    pump()
    check("a later burst still opens", fanfares == 2, tostring(fanfares))
    drain()
end

-- the lease is confirmed by the window state, not by its text
do
    local w = fresh()
    open_burst("Mine")
    check("burst open", has(banner.status(), "state=open"), banner.status())
    check("the lease is frozen", has(banner.status(), "lease=frozen/0"), banner.status())
    drain()
    w._prop = "Rescued " -- the game repaints its canned string after the hand-back
    advance(RESUME_VERIFY_TICKS)
    check("the repaint did not decide ownership", has(banner.status(), "lease=none/0"), banner.status())
    check("the window is closed", w.State == 0, tostring(w.State))
    check("one hand-back only", w.resumed == 1, tostring(w.resumed))
end

-- a not-in-play window freezes the pacing without losing the burst
do
    local w = open_two_lines()
    advance(2) -- two ticks of the line's four before the window closes
    check("the first line holds", #writes == 1, table.concat(writes, ","))
    banner.note_item("C") -- arrives out of play: it waits for its own burst
    advance(30, true)
    check("no writes out of play", #writes == 1, tostring(#writes))
    check("no line advanced", has(banner.status(), "left=1"), banner.status())
    check("the property is untouched", w._prop == "Received A", w._prop)
    check("no new burst", fanfares == 1, tostring(fanfares))
    check("the queue is untouched", has(banner.status(), "waiting=1"), banner.status())
    advance(1) -- resume: one re-assert before the pacing continues
    check("the line is re-asserted once", #writes == 2 and writes[2] == "Received A",
        table.concat(writes, ","))
    advance(1) -- the frozen dwell resumes where the window left it
    check("no line before the dwell is spent", #writes == 2, table.concat(writes, ","))
    advance(1)
    check("the next line follows", writes[3] == "Received B", table.concat(writes, ","))
    drain()
    check("the burst finishes", w.closed == 1, tostring(w.closed))
    check("one re-assert for the whole window", #writes == 3, table.concat(writes, ","))
end

-- a not-in-play window spends no release attempts; the fallback fires once
-- play resumes
do
    local w = fresh()
    fanfare.refuse_chain(w) -- the resumed Intro never closes the window
    open_burst("Held")
    drain()
    check("the resume could not close it", has(banner.status(), "lease=releasing/1"), banner.status())
    local stops = w.intro_stops
    advance(20, true)
    check("no fallback out of play", w.intro_stops == stops, tostring(w.intro_stops))
    check("the lease waits", has(banner.status(), "lease=releasing/1"), banner.status())
    advance(RESUME_VERIFY_TICKS + 2)
    check("the fallback fires on resume", w.intro_stops == stops + 1, tostring(w.intro_stops))
    advance(FALLBACK_VERIFY_TICKS + 2)
    check("and confirms", has(banner.status(), "lease=none/0"), banner.status())
    check("the window is closed", w.State == 0, tostring(w.State))
end

-- a lease the game destroyed while out of play is dropped, not written
do
    local w = fresh()
    open_burst("Old")
    check("burst open", has(banner.status(), "state=open"), banner.status())
    local old = w
    advance(2, true) -- the game leaves play mid-burst
    old._valid = false -- a level load replaced the instance
    w = new_widget()
    widget = w
    local before = #writes
    advance(1) -- resume: verify first, so nothing is written into the dead widget
    check("nothing written into the dead widget", #writes == before, table.concat(writes, ","))
    check("the lease is dropped", has(banner.status(), "lease=none/0"), banner.status())
    check("the burst is dropped", has(banner.status(), "state=idle"), banner.status())
    check("quietly", log_text():find("WARN", 1, true) == nil, log_text())
    check("the new instance is untouched", (w.resumed or 0) == 0 and w._paused == false,
        tostring(w.resumed))
    banner.note_item("New")
    advance(4)
    pump()
    check("the next burst opens on the new widget", fanfares == 2, tostring(fanfares))
    check("its line lands", w._prop == "Received New", w._prop)
    drain()
    check("and it hands the new widget back", w.resumed == 1, tostring(w.resumed))
    check("the old widget is never touched", old.closed == nil, tostring(old.closed))
end

-- the re-assert after a not-in-play window writes into the leased widget only
do
    local w = fresh()
    open_burst("Leased")
    check("burst open", has(banner.status(), "state=open"), banner.status())
    local d = new_widget() -- a second live instance the lookup finds first
    decoy = d
    advance(2, true)
    local before = #writes
    advance(1) -- resume: one re-assert
    check("exactly one write", #writes == before + 1, table.concat(writes, ","))
    check("into the leased widget", w._prop == "Received Leased", w._prop)
    check("never into the decoy", d._prop == "Rescued ", d._prop)
    decoy = nil
    drain()
    check("the leased widget was handed back", w.resumed == 1, tostring(w.resumed))
    check("the decoy is untouched", (d.resumed or 0) == 0 and d.intro_stops == 0, tostring(d.resumed))
end

-- a release resumes the Intro and the widget's own chain closes it
do
    local w = fresh()
    open_burst("Back")
    check("burst open", has(banner.status(), "state=open"), banner.status())
    drain()
    check("the Intro was resumed", w.resumed == 1, tostring(w.resumed))
    check("exactly one resume log", count_log("released by resuming the Intro") == 1, log_text())
    check("no StopAnimation", w.intro_stops == 0, tostring(w.intro_stops))
    check("the module wrote no State", w._state_written == nil, tostring(w._state_written))
    check("the widget's own chain closed the window", w.closed == 1, tostring(w.closed))
    advance(RESUME_VERIFY_TICKS)
    check("the window reads closed", w.State == 0, tostring(w.State))
    check("the lease is confirmed", has(banner.status(), "lease=none/0"), banner.status())
end

-- a resume the widget never finishes falls back once, then clears
do
    local w = fresh()
    fanfare.refuse_chain(w) -- the resumed Intro never finishes: state stays 1
    open_burst("Stuck")
    drain()
    check("the release resumed the Intro", w.resumed == 1, tostring(w.resumed))
    check("the module wrote no State yet", w._state_written == nil, tostring(w._state_written))
    check("the lease waits on the resume", has(banner.status(), "lease=releasing/1"), banner.status())
    advance(RESUME_VERIFY_TICKS + 2)
    settled_by_fallback(w)
end

-- the game's own message takes the window mid-burst — the burst hands it
-- back on the first mismatch and never writes over the game
do
    local w = open_two_lines()
    local before = #writes
    w._prop = "Rescued Nestor" -- the game's show next message took the text
    advance(1)
    check("the mismatch hands the window back", has(banner.status(), "state=idle"), banner.status())
    check("nothing of ours is written over the game's text", w._prop == "Rescued Nestor", w._prop)
    check("no re-assert", #writes == before, table.concat(writes, ","))
    check("every line came back", has(banner.status(), "waiting=2"), banner.status())
    check("no release was submitted", (w.resumed or 0) == 0 and w.intro_stops == 0,
        tostring(w.resumed) .. "/" .. tostring(w.intro_stops))
    check("the lease was handed back", has(banner.status(), "lease=none/0"), banner.status())
    check("the hand-back is logged",
        count_log("game fanfare took the window — burst yielded, 2 line(s) requeued") == 1, log_text())
    check("the game still owns the window", w.State == 1, tostring(w.State))
    w._paused, w._hold, w._window_until = false, false, 0 -- the game's chain finishes
    advance(4)
    pump()
    drain()
    check("a later burst shows every line once",
        table.concat(writes, ",") == "Received A,Received A,Received B", table.concat(writes, ","))
end

-- a notice arriving while the game is not in play waits for it
do
    fresh()
    banner.tick(NOT_IN_PLAY) -- the host already saw the window: start() must hold
    banner.note_system("Save Scanning Failed!")
    advance(4, true)
    check("no fanfare out of play", fanfares == 0, tostring(fanfares))
    check("the notice is still queued", has(banner.status(), "waiting=1"), banner.status())
    advance(1)
    check("the first in-play tick opens one", fanfares == 1, tostring(fanfares))
    check("the notice is shown", writes[1] == "Save Scanning Failed!", table.concat(writes, ","))
end

-- Persistent state: one srtap_<seed>_<slot>.txt per seed+slot, written only at
-- the module's durability points (prime end, menu return, socket drop).
local PRIME_QUIET_TICKS = 4 -- mirrors the module's priming window (~1s)

-- a first run has no watermark, so the whole connect sync is history and
-- nothing is announced
do
    fresh() -- the host's menu-return reset first, as a real boot does
    os.remove(STATE_FILE)
    uncache_state()
    banner.configure(SD)
    for i = 1, 20 do banner.note_item("Item " .. i, i) end
    advance(1) -- a second ItemsReceived message lands a tick later
    for i = 21, 40 do banner.note_item("Item " .. i, i) end
    check("no fanfare for the sync", fanfares == 0, tostring(fanfares))
    check("nothing queued", has(banner.status(), "waiting=0"), banner.status())
    advance(PRIME_QUIET_TICKS)
    check("the prime ended", has(banner.status(), "priming=n"), banner.status())
    check("logged once", count_log("connect backlog: 40 item(s) treated as history") == 1, log_text())
    banner.note_item("Fresh Item", 41)
    advance(1)
    pump()
    check("the next item is announced", fanfares == 1, tostring(fanfares))
    check("its line", writes[1] == "Received Fresh Item", table.concat(writes, ","))
    drain()
end

-- a stored watermark swallows the replay and announces only the items
-- received while the game was closed
do
    fresh() -- the host's menu-return reset first, as a real boot does
    write_state("seen_upto=40\n")
    uncache_state()
    banner.configure(SD)
    check("not priming with a stored watermark", has(banner.status(), "priming=n"), banner.status())
    for i = 1, 40 do banner.note_item("Item " .. i, i) end
    advance(2)
    check("the replay is silent", fanfares == 0, tostring(fanfares))
    check("the replay is counted", has(banner.status(), "backlog=40"), banner.status())
    check("nothing queued from the replay", has(banner.status(), "waiting=0"), banner.status())
    banner.note_item("Offline Bounty", 41)
    advance(1)
    pump()
    check("the offline item is announced", fanfares == 1, tostring(fanfares))
    check("exactly one line", #writes == 1, table.concat(writes, ","))
    check("its line", writes[1] == "Received Offline Bounty", table.concat(writes, ","))
    drain()
    banner.note_disconnected()
end

-- the widget's own chain closes the window under an open burst — the burst
-- drops on that tick instead of pacing into a closed widget
do
    local w = fresh()
    for _, name in ipairs({ "A", "B", "C" }) do banner.note_item(name) end
    advance(1)
    pump()
    check("burst open", has(banner.status(), "state=open"), banner.status())
    check("first line up", w._prop == "Received A", w._prop)
    advance(1) -- one dwell tick, then the window closes on its own
    local before = #writes
    fanfare.close(w)
    advance(1)
    check("the burst drops on that tick", has(banner.status(), "state=idle"), banner.status())
    check("nothing is written into the closed window", #writes == before, table.concat(writes, ","))
    check("the remaining lines are requeued", has(banner.status(), "waiting=3"), banner.status())
    check("no release was submitted", (w.resumed or 0) == 0 and w.intro_stops == 0,
        tostring(w.resumed) .. "/" .. tostring(w.intro_stops))
    check("the lease was handed back", has(banner.status(), "lease=none/0"), banner.status())
    check("the drop is logged",
        count_log("fanfare closed under the burst — dropped, 3 line(s) requeued") == 1, log_text())
    w._valid = false -- a level load replaced the instance
    widget = new_widget()
    advance(3) -- the gap before the next burst
    pump()
    drain()
    check("the next burst shows every line",
        table.concat(writes, ",") == "Received A,Received A,Received B,Received C", table.concat(writes, ","))
end

-- a new session announces the item that arrived after the stored watermark,
-- and the menu return clears the session cleanly
do
    fresh() -- the host's menu-return reset first, as a real boot does
    write_state("seen_upto=40\n")
    uncache_state()
    banner.configure(SD)
    banner.note_item("After The Offline Tail", 41)
    advance(1)
    pump()
    check("the new item is announced", fanfares == 1, tostring(fanfares))
    banner.reset()
    check("reset leaves the banner idle", has(banner.status(), "state=idle"), banner.status())
    settle()
end

-- a window that keeps dying must not re-fire at the same pace: each
-- consecutive hand-back waits longer, and no line is lost
do
    local w = open_two_lines()
    fanfare.close(w) -- the window dies the moment it is up
    advance(1)
    check("the burst is handed back", has(banner.status(), "state=idle"), banner.status())
    check("both lines are still waiting", has(banner.status(), "waiting=2"), banner.status())
    local ticks_to_reopen
    for i = 1, 30 do
        advance(1)
        pump()
        if fanfares == 2 then ticks_to_reopen = i break end
    end
    check("a single hand-back keeps the normal gap", (ticks_to_reopen or 0) >= 2, tostring(ticks_to_reopen))
    local w2 = widget
    fanfare.close(w2)
    advance(1)
    local ticks_to_third
    for i = 1, 60 do
        advance(1)
        pump()
        if fanfares == 3 then ticks_to_third = i break end
    end
    check("a second hand-back backs off further", (ticks_to_third or 0) > (ticks_to_reopen or 0) + 2,
        tostring(ticks_to_third))
    check("no line was dropped", (banner.status():find("waiting=", 1, true) ~= nil), banner.status())
end

os.execute('rm -rf "' .. STATEDIR .. '"')

-- invariant: the module never schedules game-thread work from the game thread
check("no nested game-thread jobs", nested == 0, tostring(nested))

os.exit(done("hud_banner spec") == 0 and 0 or 1)
