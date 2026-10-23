-- Author: Tim Harrison
-- Created: 2026-10-18
-- Updated: 2026-10-21

-- Spec for client/ue4ss_mod/banner_probe/Scripts/main.lua. Fakes the UE4SS
-- surface (keys, timers, game thread, hooks, the fanfare widget, UMG create and
-- the HUD canvas) and drives each probe check the way the keys do, asserting on
-- the [PROBE] lines. It cannot prove the *game* honours these calls — that is
-- what the mod is for — only that the probe runs every path without throwing.
-- Run from the client repo root: lua tests/lua/test_banner_probe.lua

package.path = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "support/?.lua;" .. package.path
local H = require("harness")
local fanfare = require("fanfare")

H.add_path("../../../ue4ss_mod/banner_probe/Scripts")

local real_print = print
local check, done = H.checker(real_print)

-- captured [PROBE] lines and the keys/hooks the module registered
local lines, keys, timers, jobs = {}, {}, {}, {}
local hooks = {}

print = function(s)
    local line = tostring(s)
    if line:find("[PROBE]", 1, true) then
        lines[#lines + 1] = line:gsub("^%[PROBE%] ", ""):gsub("\n$", "")
    end
end

local fake_now = H.now
os.time = function() return fake_now end

-- game-thread re-entrancy is the failure this spec must guard: a job that
-- schedules another job wedges UE4SS in the game, so the fake flags it.
local in_job, reentries = false, {}
ExecuteInGameThread = function(fn)
    if in_job then reentries[#reentries + 1] = debug.traceback("nested game thread") end
    jobs[#jobs + 1] = fn
end
ExecuteWithDelay = function(ms, fn) timers[#timers + 1] = { ms = ms, fn = fn } end
RegisterKeyBind = function(key, fn) keys[key] = fn end
RegisterHook = function(name, fn)
    hooks[name] = { fn = fn, unregistered = false }
    return 11, 12
end
UnregisterHook = function(name)
    if hooks[name] then hooks[name].unregistered = true end
end

-- ESlateVisibility / EFanfareType stand-ins, as the module only passes ints
-- the number row only: unbound in gameplay, and this keyboard has no F keys
Key = { ZERO = 48, ONE = 49, TWO = 50, THREE = 51, FOUR = 52, FIVE = 53, SIX = 54, SEVEN = 55 }

-- one fake animation: records the playback calls the checks make
local function fake_anim(name, end_time)
    return {
        name = name,
        _speed = 1.0,
        _paused = false,
        _stopped = false,
        GetStartTime = function() return 0.0 end,
        GetEndTime = function() return end_time end,
    }
end

local function new_widget(opts)
    local w = {
        _state = 0,
        _state_written = nil,
        _window_until = 0,
        _paused = false,
        _text = "Rescued ",
        _prop = "Rescued ",
        _removed = false,
        _valid = true,
        _added = false,
        _visibility = 0,
        _calls = {},
    }
    w.Intro = fake_anim("Intro", 2.5)
    w.Outro = fake_anim("Outro", 0.3)
    w.NormalPosition = fake_anim("NormalPosition", 0.5)
    w.FlightPosition = fake_anim("FlightPosition", 0.5)
    w.Base = {
        SetText = function(_, ft) w._text = ft and ft.text or "?" end,
        GetText = function() return { ToString = function() return w._text end } end,
    }
    w.IsValid = function() return w._valid end
    w.GetClass = function() return { GetFullName = function() return "Class FakeFanfare" end } end
    w.GetFullName = function() return "FakeFanfare_1" end
    w.GetAnimationCurrentTime = function() return 0.5 end
    w.IsAnimationPlaying = function() return not w._paused end
    w.SetPlaybackSpeed = function(_, anim, speed) anim._speed = speed end
    w.PauseAnimation = function(_, anim) anim._paused = true; w._paused = true; return 1.0 end
    w.StopAnimation = function(_, anim)
        anim._stopped = true
        anim._paused = false
        w._paused = false
        w._window_until = 0
    end
    w.PlayAnimation = function(_, anim) anim._played = (anim._played or 0) + 1 end
    w.AddToViewport = function() w._added = true end
    w.RemoveFromParent = function() w._removed = true end
    w.SetVisibility = function(_, v) w._visibility = v end
    w["Show Message"] = function(_, ftype, name)
        w._calls[#w._calls + 1] = "Show Message:" .. tostring(name)
        w._window_until = fake_now + 2.8
    end
    -- properties with spaces go through __index/__newindex in UE4SS
    return fanfare.attach(w, function() return fake_now end)
end

local live = new_widget()
local hud_obj = {
    -- accept both call shapes; record the name whichever slot it arrives in
    ShowFanfare = function(a, b, c)
        local name = c or b
        live._window_until = fake_now + 2.8
        live._state_written = nil -- the game owns State again while it shows
        live._calls[#live._calls + 1] = "ShowFanfare:" .. tostring(name)
    end,
}
local pc = { GetHUD = function() return hud_obj end }
local kt = {
    IsValid = function() return true end,
    Conv_StringToText = function(_, s)
        return { text = s, ToString = function() return s end }
    end,
}
local canvas = {
    _drawn = {},
    -- the fake rejects unnamed struct tables, so the module's fallback is tested
    K2_DrawText = function(_, font, text, pos, color, kerning, shadow, offset, cx, cy, outlined, outline)
        if type(pos) ~= "table" or pos.X == nil then error("need named FVector2D fields") end
        if type(color) ~= "table" or color.R == nil then error("need named FLinearColor fields") end
        canvas._drawn[#canvas._drawn + 1] = text
    end,
}
local engine = { SubtitleFont = { name = "font" } }
local widget_class = { GetFullName = function() return "Class UI_FanFareMessage_C" end }
local wbl = {
    Create = function(_, world, cls, owner)
        local w = new_widget()
        w.GetClass = function() return cls end
        return w
    end,
}

FindFirstOf = function(class)
    if class == "PlayerController" then return pc end
    if class == "UI_FanFareMessage_C" then return live end
    if class == "Engine" then return engine end
    return nil
end
StaticFindObject = function(path)
    if path == "/Script/Engine.Default__KismetTextLibrary" then return kt end
    if path == "/Script/UMG.Default__WidgetBlueprintLibrary" then return wbl end
    if path == "/Engine/EngineFonts/Roboto.Roboto" then return engine.SubtitleFont end
    return nil
end
live.GetClass = function() return widget_class end

-- Advance the fake clock while running game-thread jobs and due timers. A
-- deadline stops a long timer (the canvas check's 8s window) from firing early.
local function pump(deadline)
    for _ = 1, 20000 do
        local js = jobs
        jobs = {}
        for _, fn in ipairs(js) do
            in_job = true
            fn()
            in_job = false
        end
        local due, later = {}, {}
        for _, t in ipairs(timers) do
            if deadline and fake_now + (t.ms or 0) / 1000 > deadline then
                later[#later + 1] = t
            else
                due[#due + 1] = t
            end
        end
        timers = later
        if #due == 0 and #jobs == 0 then return end
        for _, t in ipairs(due) do
            fake_now = fake_now + (t.ms or 0) / 1000
            t.fn()
        end
    end
end

local function joined()
    return table.concat(lines, "\n")
end

local function reset()
    lines = {}
end

dofile(H.support .. "../../../ue4ss_mod/banner_probe/Scripts/main.lua")

check("load line", joined():find("banner_probe v8 loaded", 1, true) ~= nil, joined())
check("log path line", joined():find("BannerProbe.log", 1, true) ~= nil, joined())
for _, name in ipairs({ "ONE", "TWO", "THREE", "FOUR", "FIVE", "SIX", "SEVEN", "ZERO" }) do
    check("key bound " .. name, keys[Key[name]] ~= nil)
end

-- check 1: vanilla window, animation lengths, write, window transitions
reset()
keys[Key.ONE]()
pump()
local j = joined()
check("1 logs Intro length", j:find("window anim Intro: start=0", 1, true) ~= nil, j)
check("1 breadcrumbs the fanfare call", j:find("fanfare: calling ShowFanfare", 1, true) ~= nil, j)
check("1 waits for an idle widget", j:find("fanfare: waiting for an idle widget", 1, true) ~= nil, j)
check("1 confirms the fanfare returned", j:find("fanfare: ShowFanfare returned", 1, true) ~= nil, j)
check("1 writes no text", j:find("SRT_PROBE_WINDOW", 1, true) == nil, j)
check("1 says it is write-free", j:find("== 1. vanilla window (no text write)", 1, true) ~= nil, j)
check("1 opens the window", j:find("state=1", 1, true) ~= nil, j)
check("1 reports a window length", j:find("window done: opened=", 1, true) ~= nil, j)
check("1 finishes", j:find("1. window: finished", 1, true) ~= nil, j)

-- check 2: playback speed lowered, restored at the end
reset()
keys[Key.TWO]()
pump()
j = joined()
check("2 sets the speed", j:find("extend: speed set", 1, true) ~= nil, j)
check("2 restores the speed", j:find("extend: speed restored to 1.0", 1, true) ~= nil, j)
check("2 finished", j:find("2. extend: finished", 1, true) ~= nil, j)

-- check 3: pause, then restore stops animations and idles the widget
reset()
keys[Key.THREE]()
pump()
j = joined()
check("3 pauses Intro", j:find("hold: paused at", 1, true) ~= nil, j)
check("3 reports not playing", j:find("hold: playing=false", 1, true) ~= nil, j)
check("3 restores", j:find("restore: playback 1.0", 1, true) ~= nil, j)
check("3 stopped the animations", live.Intro._stopped == true)
check("3 parks the widget with the Outro", (live.Outro._played or 0) >= 1, tostring(live.Outro._played))
check("3 finished", j:find("3. hold: finished", 1, true) ~= nil, j)

-- check 4: our own widget is created, driven, and removed
reset()
keys[Key.FOUR]()
pump()
j = joined()
check("4 logs the source class", j:find("spawn: src class=", 1, true) ~= nil, j)
check("4 creates a widget", j:find("spawn: created FakeFanfare_1", 1, true) ~= nil, j)
check("4 finds the Show Message spelling", j:find("spawn: Show Message spelling=Show Message", 1, true) ~= nil, j)
check("4 logs its own animation lengths", j:find("spawn anim Intro:", 1, true) ~= nil, j)
check("4 writes the sentinel", j:find("prop='SRT_PROBE_SPAWN'", 1, true) ~= nil, j)
check("4 removes the widget", j:find("spawn: widget removed", 1, true) ~= nil, j)
check("4 finished", j:find("4. spawn: finished", 1, true) ~= nil, j)

-- check 5: the draw hook fires, both argument forms are tried in order, and the
-- hook is unregistered at the end
local HUD_DRAW = "/Script/Engine.HUD:ReceiveDrawHUD"
local draw_ctx = { get = function() return { Canvas = canvas } end }
local draw_sx = { get = function() return 1920 end }
local draw_sy = { get = function() return 1080 end }

--- Run the canvas check once against a fake that only accepts one argument form.
local function run_canvas(drawfn, want)
    reset()
    canvas._drawn = {}
    canvas.K2_DrawText = drawfn
    fake_now = fake_now + 20 -- clear any previous hook window
    keys[Key.FIVE]()
    pump(fake_now + 3)
    local hook = hooks[HUD_DRAW]
    check("5 registered the draw hook", hook ~= nil)
    check("5 hook ids logged", joined():find("canvas: hook ids=11,12", 1, true) ~= nil, joined())
    if not hook then return end
    hook.fn(draw_ctx, draw_sx, draw_sy)
    hook.fn(draw_ctx, draw_sx, draw_sy)
    local j = joined()
    check("5 logs the hook firing", j:find("canvas: ReceiveDrawHUD fired, size=1920x1080", 1, true) ~= nil, j)
    check("5 used " .. want, j:find("K2_DrawText form=" .. want:sub(-1), 1, true) ~= nil, j)
    check("5 drew text", #canvas._drawn >= 1, tostring(#canvas._drawn))
    pump()
    j = joined()
    check("5 unregistered the hook", hook.unregistered == true)
    check("5 reports the call count", j:find("canvas: done, ReceiveDrawHUD fired", 1, true) ~= nil, j)
    check("5 finished", j:find("5. canvas: finished", 1, true) ~= nil, j)
end

--- Build a draw call that only accepts one struct field spelling.
--- @param xy any FVector2D field name (named form) or index (positional form).
--- @param rgba any FLinearColor field name (named form) or index.
--- @return function
local function accepts(xy, rgba)
    return function(_, font, text, pos, color)
        if type(pos) ~= "table" or pos[xy] == nil then error("need FVector2D field " .. tostring(xy)) end
        if type(color) ~= "table" or color[rgba] == nil then
            error("need FLinearColor field " .. tostring(rgba))
        end
        canvas._drawn[#canvas._drawn + 1] = text
    end
end

-- named struct fields (the form we expect UE4SS to take)
run_canvas(accepts("X", "R"), "form 1")

-- positional struct fields (the fallback when named fields are rejected)
run_canvas(accepts(1, 1), "form 2")

-- abort: 0 restores without a check running
reset()
keys[Key.ZERO]()
pump()
check("pause restores", joined():find("restore: playback 1.0", 1, true) ~= nil, joined())
check("pause reports", joined():find("abort requested", 1, true) ~= nil, joined())

-- a key press during a running check is ignored rather than stacked
reset()
live._window_until = fake_now + 2.8
keys[Key.ONE]()
keys[Key.ONE]()
pump()
check("busy guard", joined():find("busy, a check is running", 1, true) ~= nil, joined())

-- 7: burst — one held window carries five swapped lines
reset()
fake_now = fake_now + 20
keys[Key.SEVEN]()
pump(fake_now + 60)
j = joined()
check("7 freezes the Intro", j:find("burst: froze at", 1, true) ~= nil, j)
local writes = select(2, j:gsub("burst: writing 'SRT ITEM", ""))
check("7 swaps five lines", writes == 5, tostring(writes))
check(
    "7 every swap held in prop and Base",
    j:find("burst done: swaps=5 prop_ok=5 base_ok=5", 1, true) ~= nil,
    j
)
check("7 window stayed open", j:find("open_frames=5 still_open=true", 1, true) ~= nil, j)
check("7 released the window", j:find("restore: playback 1.0", 1, true) ~= nil, j)
check("7 finished", j:find("6. burst: finished", 1, true) ~= nil, j)

-- 6 runs the window checks only: spawn and canvas stay on their own keys,
-- because a bad native call there kills the game rather than erroring.
reset()
fake_now = fake_now + 20
keys[Key.SIX]()
pump(fake_now + 300)
j = joined()
check("6 finished its range", j:find("range: finished", 1, true) ~= nil, j)
for _, n in ipairs({ "1. window", "2. extend", "3. hold" }) do
    check("6 ran " .. n, j:find(n .. ": finished", 1, true) ~= nil, j)
end
check("6 skips the spawn check", j:find("4. spawn", 1, true) == nil, j)
check("6 skips the canvas check", j:find("5. canvas", 1, true) == nil, j)

-- no check may schedule game-thread work from the game thread
check("no nested game-thread jobs", #reentries == 0, tostring(#reentries) .. ":" .. tostring(reentries[1]))

os.remove(H.support .. "../../../ue4ss_mod/banner_probe/Scripts/BannerProbe.log")
os.exit(done("banner_probe spec") == 0 and 0 or 1)
