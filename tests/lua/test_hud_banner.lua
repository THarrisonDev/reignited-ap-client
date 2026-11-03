-- Author: Tim Harrison
-- Created: 2026-09-29
-- Updated: 2026-10-31

-- Spec for client/ue4ss_mod/srt_bridge/Scripts/hud_banner.lua. Fakes the UE4SS
-- surface (FindFirstOf, StaticFindObject, timers, game thread, the fanfare
-- widget) and drives the host tick, verifying the burst contract: one fanfare
-- per burst, the Intro frozen to hold the window, one text swap per line,
-- released with the Outro.
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
local widget

--- Build the fake fanfare widget: State follows the frozen window, the property
--- is the lever, and Base mirrors what the player sees.
local function new_widget()
    local w = {
        _prop = "Rescued ",
        _base = "Rescued ",
        _window_until = 0,
        _paused = false,
        _state_written = nil,
        _valid = true,
        intro_stops = 0,
        outros = 0,
    }
    w.Intro = { GetStartTime = function() return 0 end, GetEndTime = function() return 0.6 end }
    w.Outro = { GetStartTime = function() return 0 end, GetEndTime = function() return 0.267 end }
    w.Base = {
        SetText = function(_, ft) w._base = ft and ft.text or "?" end,
        GetText = function() return { ToString = function() return "" end } end, -- blank while held
    }
    w.IsValid = function() return w._valid end
    w.PauseAnimation = function() w._paused = true; return 0.4 end
    w.StopAnimation = function()
        w.intro_stops = w.intro_stops + 1
        w._paused = false
        w._window_until = 0
    end
    w.PlayAnimation = function(_, anim)
        if anim == w.Outro then w.outros = w.outros + 1 end
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
            widget._state_written = nil
            local name = c or b
            assert(name == "Nestor", "fanfare stand-in name")
        end,
    }
end

local function install()
    widget = new_widget()
    writes, fanfares, nested = {}, 0, 0
    jobs, timers = {}, {}
    local hud = hud_obj()
    FindFirstOf = function(class)
        if class == "PlayerController" then return { GetHUD = function() return hud end } end
        if class == "UI_FanFareMessage_C" then return widget end
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
local function fresh()
    install()
    logs = {}
    banner.reset()
    pump() -- land any release the reset submitted for a stray held widget
    banner.init({
        log = function(line) logs[#logs + 1] = line end,
    })
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

local TICK = 250 -- the host poll interval the module paces itself against
local STUCK_TICKS = 32 -- mirrors the module's watchdog budget (~8s at TICK)
local OPENING_TICKS = 8 -- mirrors the module's timer-loss budget (~2s at TICK)

--- Advance n host ticks, moving the poll clock and pumping work after each.
local function advance(n)
    for _ = 1, n do
        fake_now = fake_now + TICK / 1000
        banner.tick()
        pump()
    end
end

--- Advance until the burst goes idle, optionally after an expected write count
--- (a spill passes through idle between windows).
local function drain(expected)
    for _ = 1, 400 do
        local st = banner.status()
        if has(st, "state=idle") and (not expected or #writes == expected) then return end
        advance(1)
    end
end

-- scenario 1: one item = one fanfare, first line, freeze, then release
do
    local w = fresh()
    banner.note_item("Nestor's Key")
    fake_now = fake_now + TICK / 1000
    banner.tick() -- submits the open job
    run_jobs() -- fire, arm the write and freeze timers
    check("s1 one fanfare", fanfares == 1, tostring(fanfares))
    check("s1 no write before the lead-in", #writes == 0, tostring(#writes))
    run_timers() -- +100ms write, +300ms freeze
    run_jobs()
    check("s1 first line written", writes[1] == "Received Nestor's Key", tostring(writes[1]))
    check("s1 property holds the line", w._prop == "Received Nestor's Key", w._prop)
    check("s1 Base written for this frame", w._base == "Received Nestor's Key", w._base)
    check("s1 Intro frozen", w._paused == true)
    check("s1 window open", w.State == 1 or w._state_written == nil, tostring(w.State))
    check("s1 status shows open", has(banner.status(), "state=open"), banner.status())
    drain() -- hold for the dwell, then release
    check("s1 only one line written", #writes == 1, tostring(#writes))
    check("s1 Intro stopped", w.intro_stops >= 1, tostring(w.intro_stops))
    check("s1 Outro played", w.outros == 1, tostring(w.outros))
    check("s1 state reset", w._state_written == 0, tostring(w._state_written))
    check("s1 back to idle", has(banner.status(), "state=idle"), banner.status())
    check("s1 shown counter", has(banner.status(), "shown=1"), banner.status())
end

-- scenario 2: a run of items rides one fanfare, in order, one line each
do
    local w = fresh()
    for _, name in ipairs({ "A", "B", "C" }) do banner.note_item(name) end
    advance(1)
    pump()
    check("s2 one fanfare for three items", fanfares == 1, tostring(fanfares))
    check("s2 first line", writes[1] == "Received A", table.concat(writes, ","))
    drain()
    check("s2 all three lines in order", table.concat(writes, ",") == "Received A,Received B,Received C", table.concat(writes, ","))
    check("s2 one Outro for the burst", w.outros == 1, tostring(w.outros))
    check("s2 shown counter", has(banner.status(), "shown=3"), banner.status())
end

-- scenario 3: a long backlog is shown in full, spilling at the window budget
do
    local w = fresh()
    for i = 1, 30 do banner.note_item("Item " .. i) end
    advance(1)
    pump()
    check("s3 the window's length follows the queue",
        log_text():find("burst open: 30 line(s) from 30 queued, holding ~30.0s", 1, true) ~= nil, log_text())
    for _ = 1, 400 do
        local st = banner.status()
        if has(st, "state=idle") and has(st, "waiting=0") then break end
        advance(1)
    end
    check("s3 every item shown", #writes == 30, tostring(#writes))
    check("s3 in order", writes[1] == "Received Item 1" and writes[30] == "Received Item 30",
        (writes[1] or "") .. "..." .. (writes[#writes] or ""))
    check("s3 budget spills into a second window", fanfares == 2, tostring(fanfares))
    check("s3 the spill is logged",
        log_text():find("burst closed at the budget, 15 line(s) left", 1, true) ~= nil, log_text())
    check("s3 the queue drained", has(banner.status(), "waiting=0"), banner.status())
end

-- scenario 3b: repeats collapse into one counted line (the reason for batching)
do
    local w = fresh()
    for _ = 1, 32 do banner.note_item("Dragon Egg") end
    banner.note_item("Extra Life")
    advance(1)
    pump()
    check("s3b a short burst", log_text():find("burst open: 2 line(s) from 33 queued, holding ~2.0s", 1, true) ~= nil,
        log_text())
    check("s3b every item counted as queued", has(banner.status(), "queued=33"), banner.status())
    drain(2)
    check("s3b two lines for 33 items", #writes == 2, tostring(#writes))
    check("s3b the repeat is counted", writes[1] == "Received 32x Dragon Egg", table.concat(writes, " | "))
    check("s3b the single stays singular", writes[2] == "Received Extra Life", table.concat(writes, " | "))
    check("s3b two lines shown", has(banner.status(), "shown=2"), banner.status())
    check("s3b one Outro for the pair", w.outros == 1, tostring(w.outros))
end

-- scenario 3c: sent checks are always individual, even when identical
do
    local w = fresh()
    for _ = 1, 3 do banner.note_sent("To Bob: Orb") end
    advance(1)
    pump()
    check("s3c the burst holds three lines", log_text():find("burst open: 3 line(s) from 3 queued", 1, true) ~= nil,
        log_text())
    drain(3)
    check("s3c three separate lines", #writes == 3, tostring(#writes))
    check("s3c verbatim, one per check",
        table.concat(writes, " | ") == "To Bob: Orb | To Bob: Orb | To Bob: Orb",
        table.concat(writes, " | "))
    check("s3c all three counted", has(banner.status(), "sent=3"), banner.status())
end

-- scenario 3d: a mixed batch keeps items first, sends one per check
do
    local w = fresh()
    for _ = 1, 2 do banner.note_item("Gem") end
    banner.note_sent("To Bob: Orb")
    banner.note_sent("To Bob: Orb")
    advance(1)
    pump()
    drain(3)
    check(
        "s3d collapsed items first, then every send",
        table.concat(writes, " | ") == "Received 2x Gem | To Bob: Orb | To Bob: Orb",
        table.concat(writes, " | ")
    )
end

-- scenario 4: received items outrank sent lines
do
    local w = fresh()
    banner.note_sent("To Bob: Orb")
    banner.note_item("Dragon")
    advance(1)
    pump()
    drain()
    check("s4 item shown first", writes[1] == "Received Dragon", table.concat(writes, ","))
    check("s4 sent line follows", writes[2] == "To Bob: Orb", table.concat(writes, ","))
    check("s4 sent counted", has(banner.status(), "sent=1"), banner.status())
end

-- scenario 5: a checkd notice preempts the waiting queues
do
    local w = fresh()
    banner.note_item("Item A")
    banner.note_item("Item B")
    banner.note_system("Save Scanning Failed!")
    advance(1)
    pump()
    drain()
    check("s5 notice shown", writes[1] == "Save Scanning Failed!", table.concat(writes, ","))
    check("s5 queued item dropped", table.concat(writes, ","):find("Item B", 1, true) == nil,
        table.concat(writes, ","))
end

-- scenario 6: never inject while the game's own fanfare is up
do
    local w = fresh()
    w._window_until = fake_now + 2.8 -- the game is mid-fanfare
    banner.note_item("Waits")
    advance(1)
    check("s6 no fanfare while busy", fanfares == 0, tostring(fanfares))
    advance(14) -- let the game's window lapse
    check("s6 fires once idle", fanfares == 1, tostring(fanfares))
    pump()
    check("s6 line lands", writes[1] == "Received Waits", tostring(writes[1]))
end

-- scenario 7: the widget dies mid-burst — the burst is abandoned, not crashed
do
    local w = fresh()
    banner.note_item("A")
    banner.note_item("B")
    advance(1)
    pump()
    check("s7 first line up", w._prop == "Received A", w._prop)
    w._valid = false
    advance(8)
    check("s7 burst abandoned", has(banner.status(), "state=idle"), banner.status())
    local before = #writes
    advance(8)
    check("s7 no writes after the widget died", #writes == before, tostring(#writes))
end

-- scenario 8: no HUD (menu/loading) is a quiet retry, not a stream of warnings
do
    local warned = 0
    install()
    banner.reset()
    banner.init({ log = function() warned = warned + 1 end })
    FindFirstOf = function() return nil end
    banner.note_item("Later")
    advance(6)
    check("s8 nothing fired without a HUD", fanfares == 0, tostring(fanfares))
    check("s8 no warning spam", warned == 0, tostring(warned))
end

-- scenario 9: the game repaints its canned text mid-window -> re-assert once
do
    local w = fresh()
    banner.note_item("Holds")
    advance(1)
    pump()
    check("s9 line up", w._prop == "Received Holds", w._prop)
    w._prop = "Rescued " -- the game's Tick repainted the property
    local before = #writes
    advance(1)
    check("s9 rewritten", w._prop == "Received Holds", w._prop)
    check("s9 exactly one extra write", #writes == before + 1, tostring(#writes))
    advance(1)
    check("s9 no rewrite when it holds", #writes == before + 1, tostring(#writes))
end

-- scenario 10: after a burst closes, the next item opens a new window
do
    local w = fresh()
    banner.note_item("First")
    advance(1)
    pump()
    drain()
    check("s10 one fanfare so far", fanfares == 1, tostring(fanfares))
    banner.note_item("Second")
    advance(3) -- a gap of ticks precedes a new burst
    check("s10 second fanfare", fanfares == 2, tostring(fanfares))
    pump()
    check("s10 second line up", w._prop == "Received Second", w._prop)
    drain()
end

-- scenario 11: status and reset
do
    local w = fresh()
    banner.note_item("A")
    banner.note_sent("S")
    local st = banner.status()
    check(
        "s11 status fields",
        has(st, "queued=1") and has(st, "sent_queued=1") and has(st, "waiting=2"),
        st
    )
    banner.reset()
    st = banner.status()
    check("s11 reset clears", has(st, "queued=0") and has(st, "waiting=0") and has(st, "state=idle"), st)
    banner.note_item("After reset")
    advance(1)
    pump()
    check("s11 still works after reset", w._prop == "Received After reset", w._prop)
    drain()
end

-- scenario 12: reset while open releases the frozen widget, not leaving it stuck
do
    local w = fresh()
    banner.note_item("Held")
    advance(1)
    pump()
    check("s12 burst open", has(banner.status(), "state=open"), banner.status())
    banner.reset()
    pump()
    check("s12 reset unpauses the frozen Intro", w._paused == false, tostring(w._paused))
    check("s12 widget parked", w._state_written == 0, tostring(w._state_written))
    check("s12 one Outro", w.outros == 1, tostring(w.outros))
    check("s12 idle after reset", has(banner.status(), "state=idle"), banner.status())
    banner.note_item("After reset")
    advance(1)
    pump()
    check("s12 a later item opens a new fanfare", fanfares == 2, tostring(fanfares))
    check("s12 its line lands", writes[#writes] == "Received After reset", table.concat(writes, ","))
    drain()
end

-- scenario 13: a single missed lookup is not destruction; three in a row is
do
    local w = fresh()
    banner.note_item("Debounce")
    advance(1)
    pump()
    check("s13 burst open", has(banner.status(), "state=open"), banner.status())
    local restore = miss_lookups(1)
    advance(1)
    restore()
    check("s13 one miss keeps the burst", has(banner.status(), "state=open"), banner.status())
    check("s13 the Intro stays frozen", w._paused == true, tostring(w._paused))
    check("s13 one miss is quiet", log_text():find("WARN", 1, true) == nil, log_text())
    drain()
    check("s13 the burst finishes normally", w.outros == 1, tostring(w.outros))
end
do
    local w = fresh()
    banner.note_item("Vanishing")
    advance(3) -- the gap left by the previous close
    pump()
    check("s13 second burst open", has(banner.status(), "state=open"), banner.status())
    local restore = miss_lookups(3)
    advance(3)
    restore()
    check("s13 three misses drop the burst", has(banner.status(), "state=idle"), banner.status())
    check("s13 the drop is logged",
        log_text():find("went missing 3 polls running", 1, true) ~= nil, log_text())
    check("s13 the abandoned burst still releases", w._paused == false, tostring(w._paused))
    check("s13 one Outro for the abandoned burst", w.outros == 1, tostring(w.outros))
end

-- scenario 14: close releases the widget this burst froze, never a fresh instance
do
    local w = fresh()
    banner.note_item("Old")
    advance(1)
    pump()
    check("s14 burst open", has(banner.status(), "state=open"), banner.status())
    local old = w
    w = new_widget() -- a level transition replaced the widget under the burst
    widget = w
    w._prop = old._prop -- no re-assert churn: drive straight to the dwell close
    drain()
    check("s14 the held widget is released", old._paused == false, tostring(old._paused))
    check("s14 one Outro on the held widget", old.outros == 1, tostring(old.outros))
    check("s14 the fresh instance is untouched", w.outros == 0, tostring(w.outros))
end

-- scenario 15: a repaint loop cannot hold the window past the budget
do
    local w = fresh()
    banner.note_item("Repaint")
    advance(1)
    pump()
    check("s15 burst open", has(banner.status(), "state=open"), banner.status())
    for _ = 1, 50 do
        w._prop = "Rescued "
        advance(1)
    end
    check("s15 still holding before the budget", has(banner.status(), "state=open"), banner.status())
    for _ = 1, 12 do
        w._prop = "Rescued "
        advance(1)
    end
    check("s15 the budget closes it", has(banner.status(), "state=idle"), banner.status())
    check("s15 released", w.outros == 1, tostring(w.outros))
end

-- scenario 16: a fanfare left reporting open on our own line is reclaimed
do
    local w = fresh()
    banner.note_item("Leak")
    advance(1)
    pump()
    drain() -- a normal burst; the property keeps our last line after it closes
    local outros = w.outros
    w._state_written = nil -- the release never reached the widget: State reads open
    w._paused = true -- a leaked freeze: State == 1 with the module idle
    advance(STUCK_TICKS + 2)
    check("s16 the watchdog releases it", w._paused == false, tostring(w._paused))
    check("s16 one more Outro", w.outros == outros + 1, tostring(w.outros))
    check("s16 the reclaim is logged", log_text():find("with no burst", 1, true) ~= nil, log_text())
    banner.note_item("After watchdog")
    advance(1)
    pump()
    check("s16 a new fanfare then opens", fanfares == 2, tostring(fanfares))
    check("s16 its line lands", writes[#writes] == "Received After watchdog", tostring(writes[#writes]))
    drain()
end

-- scenario 17: a socket drop releases the burst and saves its unwritten lines
do
    local w = fresh()
    for _, name in ipairs({ "A", "B", "C" }) do banner.note_item(name) end
    advance(1)
    pump()
    check("s17 first line up", w._prop == "Received A", w._prop)
    banner.note_disconnected()
    pump()
    check("s17 disconnect releases the Intro", w._paused == false, tostring(w._paused))
    check("s17 one Outro", w.outros == 1, tostring(w.outros))
    check("s17 idle after the drop", has(banner.status(), "state=idle"), banner.status())
    check("s17 the unwritten lines came back", has(banner.status(), "waiting=2"), banner.status())
    advance(4)
    pump()
    drain()
    check("s17 the next burst shows them", table.concat(writes, ",") == "Received A,Received B,Received C",
        table.concat(writes, ","))
end

-- scenario 18: a burst dropped in the opening frame never resurrects
do
    local w = fresh()
    banner.note_item("Opening")
    fake_now = fake_now + TICK / 1000
    banner.tick() -- submit the open job
    run_jobs() -- fire the fanfare and arm the timers
    check("s18 the burst is opening", has(banner.status(), "state=opening"), banner.status())
    for _ = 1, OPENING_TICKS + 1 do
        fake_now = fake_now + TICK / 1000
        banner.tick() -- timers stay undelivered: the opening ticks out
    end
    check("s18 the opening timeout drops the burst", has(banner.status(), "state=idle"), banner.status())
    check("s18 nothing was frozen", w._paused == false, tostring(w._paused))
    run_timers() -- the armed write and freeze land after the drop
    run_jobs()
    check("s18 the stale freeze never lands", w._paused == false, tostring(w._paused))
    check("s18 still idle", has(banner.status(), "state=idle"), banner.status())
    check("s18 no Outro for a freeze never owned", w.outros == 0, tostring(w.outros))
end

-- scenario 19: a disconnect during the lead-in keeps every line
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
    check("s19 the burst is open", has(banner.status(), "state=open"), banner.status())
    check("s19 the lead-in line is unwritten", w._prop == "Rescued ", w._prop)
    banner.note_disconnected()
    pump()
    check("s19 the frozen Intro is released", w._paused == false, tostring(w._paused))
    check("s19 one Outro", w.outros == 1, tostring(w.outros))
    check("s19 both lines are waiting", has(banner.status(), "waiting=2"), banner.status())
    advance(3)
    pump()
    drain()
    check("s19 the next burst shows both", table.concat(writes, ",") == "Received A,Received B",
        table.concat(writes, ","))
end

-- scenario 20: the watchdog leaves the game's own fanfare chain alone
do
    local w = fresh()
    w._paused = true -- State == 1, but the property is the game's canned text
    check("s20 the property is not a line we wrote", w._prop == "Rescued ", w._prop)
    advance(STUCK_TICKS + 4)
    check("s20 no release", w.outros == 0, tostring(w.outros))
    check("s20 the game still holds it", w._paused == true, tostring(w._paused))
    check("s20 no reclaim WARN", log_text():find("with no burst", 1, true) == nil, log_text())
end

-- scenario 21: an opening timeout puts its lines back for the next burst
do
    fresh()
    banner.note_item("Lost")
    banner.note_item("Found")
    fake_now = fake_now + TICK / 1000
    banner.tick() -- submit the open job
    run_jobs() -- fire the fanfare and arm the timers
    check("s21 the burst is opening", has(banner.status(), "state=opening"), banner.status())
    for _ = 1, OPENING_TICKS + 1 do
        fake_now = fake_now + TICK / 1000
        banner.tick() -- the timers never land: the opening ticks out
    end
    check("s21 the burst is dropped", has(banner.status(), "state=idle"), banner.status())
    check("s21 both lines came back", has(banner.status(), "waiting=2"), banner.status())
    advance(3)
    pump()
    drain()
    check("s21 the next burst shows both", table.concat(writes, ",") == "Received Lost,Received Found",
        table.concat(writes, ","))
end

-- invariant: the module never schedules game-thread work from the game thread
check("no nested game-thread jobs", nested == 0, tostring(nested))

os.exit(done("hud_banner spec") == 0 and 0 or 1)
