-- Author: Tim Harrison
-- Created: 2026-10-18

-- banner_probe: independent UE4SS mod answering the questions that decide how
-- srt_bridge/hud_banner.lua shows items — can the fanfare window be extended or
-- held open, can we spawn and drive our own widget, and can we draw text
-- through the HUD's canvas instead of borrowing the fanfare at all.
--
-- Facts already proven are in docs/fanfare_text.md; the API surface comes from
-- docs/falcon_sdk_dump/UI_FanFareMessage.hpp, UMG.hpp and Engine.hpp.
--
-- Read-only vs the save: message text and widget lifetimes only, no progression
-- writes. It does disturb the live fanfare widget, which is the point — key 0
-- puts it back.
--
-- Keys (this keyboard has no F keys; the number row is unbound in gameplay):
--   1   vanilla window, and the Intro/Outro lengths behind it
--   2   extend with SetPlaybackSpeed(Intro, 0.25)
--   3   hold with PauseAnimation(Intro)
--   4   spawn our own UI_FanFareMessage_C and drive it
--   5   draw text via a ReceiveDrawHUD hook
--   6   run the three window checks back to back (~35s)
--   7   burst: hold one window and swap the text 5 times (each press tries a
--       later Intro freeze point: 300, 450, 580ms)
--   0   abort: restore playback, stop animations, drop our widget, unhook
--
-- Every line lands in BannerProbe.log beside this script and on the UE4SS
-- console as [PROBE].

local MOD_DIR = debug.getinfo(1, "S").source:match("^@(.*[/\\])")
local LOG_PATH = MOD_DIR .. "BannerProbe.log"

local log_fh = nil

--- Append one stamped line to the probe log and the UE4SS console.
local function log(line)
    local stamped = os.date("%H:%M:%S ") .. line .. "\n"
    print("[PROBE] " .. line .. "\n")
    local f = log_fh
    if f then
        if pcall(function() f:write(stamped) f:flush() end) then return end
        pcall(function() f:close() end)
        log_fh = nil
    end
    f = io.open(LOG_PATH, "a")
    if f then
        log_fh = f
        pcall(function() f:write(stamped) f:flush() end)
    end
end

local swallowed = 0

--- Return fn()'s result, or default when it throws, logging the reason (bounded:
--- the sampler would otherwise repeat one broken read on every step).
local function safe(fn, default)
    local ok, res = pcall(fn)
    if ok then return res end
    swallowed = swallowed + 1
    if swallowed <= 20 then
        log("safe swallowed: " .. tostring(res))
    elseif swallowed == 21 then
        log("safe swallowed: (further errors suppressed)")
    end
    return default
end

--- Call the first spelling of a blueprint function that works, returning its
--- name or nil: spaced BP names ("Show Message") may or may not resolve.
local function call_forms(obj, names, ...)
    local args = { ... }
    for _, name in ipairs(names) do
        if pcall(function() obj[name](obj, table.unpack(args)) end) then
            return name
        end
    end
    return nil
end

local EFFT_DRAGON = 1
local DRAGON = "Nestor" -- any name in the dragon table; the text is ours
local STEP_MS = 100
local SELF_HIT_TEST = 4 -- ESlateVisibility.SelfHitTestInvisible: never eat input
local HUD_DRAW = "/Script/Engine.HUD:ReceiveDrawHUD"
-- FVector2D/FLinearColor as UE4SS takes them: named fields first, positional as
-- the fallback. The probe logs which form the engine accepts.
local DRAW_FORMS = {
    {
        pos = { X = 60, Y = 220 },
        color = { R = 1, G = 1, B = 1, A = 1 },
        shadow = { R = 0, G = 0, B = 0, A = 0.5 },
        offset = { X = 1, Y = 1 },
        outline = { R = 0, G = 0, B = 0, A = 1 },
    },
    {
        pos = { 60, 220 },
        color = { 1, 1, 1, 1 },
        shadow = { 0, 0, 0, 0.5 },
        offset = { 1, 1 },
        outline = { 0, 0, 0, 1 },
    },
}
local SPAWN_TEXT = { "Show Message", "ShowMessage", "show message" }

--- Return the game's HUD, or nil.
local function hud()
    return safe(function()
        return FindFirstOf("PlayerController"):GetHUD()
    end, nil)
end

--- Return the live fanfare widget, or nil. Re-found every time: a cached handle
-- survives a level transition pointing at freed memory.
local function fanfare()
    local w = safe(function() return FindFirstOf("UI_FanFareMessage_C") end, nil)
    return safe(function() return w:IsValid() end, false) and w or nil
end

--- Return the KismetTextLibrary used to build FText, or nil.
local function kt_lib()
    local kt = safe(function()
        return StaticFindObject("/Script/Engine.Default__KismetTextLibrary")
    end, nil)
    return safe(function() return kt:IsValid() end, false) and kt or nil
end

--- Write text into the `message text` property (the lever) and Base (the frame
-- currently painted). Mirrors hud_banner.lua's production write.
local function write_text(fmw, text)
    local kt = kt_lib()
    local ft = kt and safe(function() return kt:Conv_StringToText(text) end, nil)
    if not ft then
        log("write: no FText via KismetTextLibrary")
        return false
    end
    safe(function() fmw["message text"] = ft end)
    local base = safe(function() return fmw.Base end, nil)
    if base then safe(function() base:SetText(ft) end) end
    return true
end

--- Log each animation's length: the banner's duration lives in these assets, not
-- in a tunable property.
local function log_animations(fmw, label)
    for _, name in ipairs({ "Intro", "Outro", "NormalPosition", "FlightPosition" }) do
        local anim = safe(function() return fmw[name] end, nil)
        if anim then
            local start = safe(function() return anim:GetStartTime() end, nil)
            local finish = safe(function() return anim:GetEndTime() end, nil)
            log(string.format("%s anim %s: start=%s end=%s", label, name, tostring(start), tostring(finish)))
        end
    end
end

--- Sample the banner's observable fields: window state, the text the player sees
-- (Base) and our property write. Animation position is deliberately not read
-- here: this runs every 100ms, and every call is a crash surface.
local function snap(fmw)
    return {
        state = tonumber(safe(function() return fmw.State end, nil)),
        base = safe(function() return fmw.Base:GetText():ToString() end, nil),
        prop = safe(function() return fmw["message text"]:ToString() end, nil),
    }
end

--- Return one sample as a log field list.
local function fmt(s)
    return string.format(
        "state=%s base='%s' prop='%s'",
        tostring(s.state),
        tostring(s.base),
        tostring(s.prop)
    )
end

local IDLE_MS = 100
local IDLE_TRIES = 200 -- ~20s: the connect-time counter backlog can run for a while

--- Fire a stand-in dragon fanfare once the widget is idle, then hand it to fn at
--- +100ms (the production write delay). hud_banner waits for `State == 0` before
--- injecting because firing into a live window collides with the game's own
--- fanfare; in this probe that collision killed the game twice, so the wait is
--- not optional. fail() is called when no banner can be fired.
local function fire_then(fn, fail, attempt)
    attempt = attempt or 0
    if attempt == 0 then
        log("fanfare: waiting for an idle widget")
    end
    local h = hud()
    local fmw = fanfare()
    local kt = kt_lib()
    if not h then
        log("fanfare: no HUD (is a save loaded and in play?)")
        fail()
        return
    end
    if not fmw then
        log("fanfare: no UI_FanFareMessage_C")
        fail()
        return
    end
    if not kt then
        log("fanfare: no KismetTextLibrary")
        fail()
        return
    end
    if tonumber(safe(function() return fmw.State end, nil)) == 1 then
        if attempt >= IDLE_TRIES then
            log("fanfare: widget still busy after " .. attempt .. " tries, giving up")
            fail()
            return
        end
        if attempt % 20 == 19 then
            log("fanfare: still busy after " .. attempt .. " tries")
        end
        ExecuteWithDelay(IDLE_MS, function()
            ExecuteInGameThread(function() fire_then(fn, fail, attempt + 1) end)
        end)
        return
    end
    -- Production form verbatim (hud_banner.lua: `hud.ShowFanfare(...)`, no
    -- explicit self). A wrong arg shape here is a native crash, not a Lua error.
    log("fanfare: calling ShowFanfare")
    if not pcall(function() h.ShowFanfare(EFFT_DRAGON, DRAGON) end) then
        log("fanfare: ShowFanfare failed")
        fail()
        return
    end
    log("fanfare: ShowFanfare returned")
    ExecuteWithDelay(100, function()
        ExecuteInGameThread(function()
            log("fanfare: writing text")
            fn(fmw, kt)
        end)
    end)
end

--- Sample getter() every STEP_MS for ms, logging each field transition, then
-- report the window it saw and call done.
---
--- Must be called ON the game thread, and steps itself directly: scheduling a
--- game-thread job from inside a game-thread job wedges UE4SS (the job waits on
--- the queue of the thread it is already running on). hud_banner never does it
--- — every one of its schedules is ExecuteWithDelay -> ExecuteInGameThread.
local function watch(label, ms, done, getter)
    getter = getter or fanfare
    local prev, elapsed = nil, 0
    local opened, last_open, closed = nil, nil, nil
    local function step()
        local fmw = getter()
        if not fmw then
            log(label .. ": widget went away at " .. elapsed .. "ms")
            if done then done() end
            return
        end
        local s = snap(fmw)
        if not prev or s.state ~= prev.state or s.base ~= prev.base or s.prop ~= prev.prop then
            log(string.format("%s @%dms %s", label, elapsed, fmt(s)))
            prev = s
        end
        if s.state == 1 then
            opened = opened or elapsed
            last_open = elapsed
        elseif opened and not closed then
            closed = elapsed
        end
        elapsed = elapsed + STEP_MS
        if elapsed > ms then
            log(
                string.format(
                    "%s done: opened=%sms last_state1=%sms closed=%sms",
                    label,
                    tostring(opened),
                    tostring(last_open),
                    tostring(closed)
                )
            )
            if done then done() end
            return
        end
        ExecuteWithDelay(STEP_MS, function() ExecuteInGameThread(step) end)
    end
    step()
end

local burst_i = 1 -- next Intro freeze point to try (the glow settles late)
local busy = false -- a check is running; new key presses are ignored
local spawned = nil -- our own widget instance, while check 4 runs
local draw_hook = nil -- {pre, post} while the canvas check is registered

--- Put the banner back: normal playback, no paused animation, state idle, our
-- spawned widget gone, the canvas hook off. The abort key and check 3 call it.
local function restore()
    local fmw = fanfare()
    if fmw then
        for _, name in ipairs({ "Intro", "Outro" }) do
            local anim = safe(function() return fmw[name] end, nil)
            if anim then
                safe(function() fmw:SetPlaybackSpeed(anim, 1.0) end)
                safe(function() fmw:StopAnimation(anim) end)
            end
        end
        safe(function() fmw.State = 0 end)
        -- Parking it: the Outro animates the widget back to its closed position,
        -- so a paused Intro cannot leave it frozen on screen.
        local outro = safe(function() return fmw.Outro end, nil)
        if outro then safe(function() fmw:PlayAnimation(outro, 0, 1, 0, 1.0) end) end
    end
    if spawned then
        safe(function() spawned:RemoveFromParent() end)
        spawned = nil
    end
    if draw_hook then
        safe(function() UnregisterHook(HUD_DRAW, draw_hook[1], draw_hook[2]) end)
        draw_hook = nil
    end
    log("restore: playback 1.0, animations stopped, State 0, spawned widget gone, hook off")
end

--- Fire a fanfare, write text, optionally adjust the window in setup(w, anim),
-- then watch it for ms and run on_end(w, anim) before finishing.
local function banner_check(label, text, ms, setup, on_end, done)
    fire_then(function(w)
        if tonumber(safe(function() return w.State end, nil)) ~= 1 then
            log(label .. ": window not open at +100ms, skipping the write")
            done()
            return
        end
        write_text(w, text)
        local anim = safe(function() return w.Intro end, nil)
        if setup and setup(w, anim) == false then
            done()
            return
        end
        watch(label, ms, function()
            if on_end then on_end(w, anim) end
            done()
        end)
    end, done)
end

--- Check 1: the vanilla window, measured with no text write at all. Firing and
-- sampling only, so the riskiest operations are not in the loop.
local function check_window(done)
    log("== 1. vanilla window (no text write)")
    local fmw = fanfare()
    if fmw then log_animations(fmw, "window") end
    fire_then(function()
        watch("window", 6000, done)
    end, done)
end

--- Check 2: stretch the window by slowing the Intro animation down 4x.
local function check_extend(done)
    log("== 2. extend: SetPlaybackSpeed(Intro, 0.25)")
    banner_check("extend", "SRT_PROBE_EXTEND", 15000, function(w, anim)
        if not anim then
            log("extend: no Intro animation")
            return false
        end
        safe(function() w:SetPlaybackSpeed(anim, 0.25) end)
        local playing = safe(function() return w:IsAnimationPlaying(anim) end, nil)
        local t = safe(function() return w:GetAnimationCurrentTime(anim) end, nil)
        log("extend: speed set, playing=" .. tostring(playing) .. " time=" .. tostring(t))
    end, function(w, anim)
        safe(function() w:SetPlaybackSpeed(anim, 1.0) end)
        log("extend: speed restored to 1.0")
        restore()
    end, done)
end

--- Check 3: freeze the Intro before it finishes, so the Outro never runs and the
-- banner should stay on screen however long we like.
local function check_hold(done)
    log("== 3. hold: PauseAnimation(Intro)")
    banner_check("hold", "SRT_PROBE_HOLD", 12000, function(w, anim)
        if not anim then
            log("hold: no Intro animation")
            return false
        end
        log("hold: paused at " .. tostring(safe(function() return w:PauseAnimation(anim) end, nil)))
        log("hold: playing=" .. tostring(safe(function() return w:IsAnimationPlaying(anim) end, nil)))
    end, function() restore() end, done)
end

local BURST_SWAPS = 5
local SWAP_MS = 1000
local SWAP_VERIFY_MS = 120
-- Intro is ~0.6s; freezing early catches the glow mid-render, so each run tries
-- the next later point and logs which one it used.
local PAUSE_CYCLE = { 300, 450, 580 }

--- Check 6: hold one window open and swap the text under it, the way a burst of
-- received items would. Answers whether a single fanfare can carry several lines
-- instead of one banner per item.
local function check_burst(done)
    local pause_ms = PAUSE_CYCLE[burst_i]
    burst_i = burst_i % #PAUSE_CYCLE + 1
    log("== 6. burst: freeze Intro at " .. pause_ms .. "ms, then swap text")
    fire_then(function(w)
        local anim = safe(function() return w.Intro end, nil)
        if not anim then
            log("burst: no Intro animation")
            done()
            return
        end
        local n, prop_ok, base_ok, open_frames = 0, 0, 0, 0
        ExecuteWithDelay(pause_ms, function()
            ExecuteInGameThread(function()
                log("burst: froze at " .. tostring(safe(function() return w:PauseAnimation(anim) end, nil)))
            end)
        end)
        local function swap()
            if n >= BURST_SWAPS then
                local open = tonumber(safe(function() return w.State end, nil)) == 1
                log(
                    string.format(
                        "burst done: swaps=%d prop_ok=%d base_ok=%d open_frames=%d still_open=%s",
                        n,
                        prop_ok,
                        base_ok,
                        open_frames,
                        tostring(open)
                    )
                )
                restore()
                done()
                return
            end
            n = n + 1
            local text = "SRT ITEM " .. n .. "/" .. BURST_SWAPS
            log("burst: writing '" .. text .. "'")
            write_text(w, text)
            ExecuteWithDelay(SWAP_VERIFY_MS, function()
                ExecuteInGameThread(function()
                    local s = snap(w)
                    if s.prop == text then prop_ok = prop_ok + 1 end
                    if s.base == text then base_ok = base_ok + 1 end
                    if s.state == 1 then open_frames = open_frames + 1 end
                    log(string.format("burst %d: %s", n, fmt(s)))
                end)
            end)
            ExecuteWithDelay(SWAP_MS, function() ExecuteInGameThread(swap) end)
        end
        swap()
    end, done)
end

--- Return our spawned widget when it is still alive, else nil.
local function spawned_alive()
    if spawned and safe(function() return spawned:IsValid() end, false) then
        return spawned
    end
end

--- Check 4: build a second fanfare widget of our own and drive it. If this works
-- we stop borrowing the game's instance and own the lifetime outright.
local function check_spawn(done)
    log("== 4. spawn our own UI_FanFareMessage_C")
    local pc = safe(function() return FindFirstOf("PlayerController") end, nil)
    local live = fanfare()
    if not pc or not live then
        log("spawn: need a PlayerController and one live fanfare widget")
        done()
        return
    end
    local cls = safe(function() return live:GetClass() end, nil)
    local wbl = safe(function()
        return StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    end, nil)
    if not cls or not wbl then
        log("spawn: no widget class or WidgetBlueprintLibrary")
        done()
        return
    end
    log("spawn: src class=" .. tostring(safe(function() return cls:GetFullName() end, nil)))
    log("spawn: calling WidgetBlueprintLibrary:Create")
    local w = safe(function() return wbl:Create(pc, cls, pc) end, nil)
        or safe(function() return wbl.Create(wbl, pc, cls, pc) end, nil)
    if not w then
        log("spawn: Create returned nil")
        done()
        return
    end
    log("spawn: created " .. tostring(safe(function() return w:GetFullName() end, nil)))
    log_animations(w, "spawn")
    safe(function() w:SetVisibility(SELF_HIT_TEST) end)
    log("spawn: calling AddToViewport")
    safe(function() w:AddToViewport(0) end)
    spawned = w
    log("spawn: Show Message spelling=" .. tostring(call_forms(w, SPAWN_TEXT, EFFT_DRAGON, DRAGON)))
    write_text(w, "SRT_PROBE_SPAWN")
    watch("spawn", 8000, function()
        if spawned then
            safe(function() spawned:RemoveFromParent() end)
            spawned = nil
        end
        log("spawn: widget removed")
        done()
    end, spawned_alive)
end

--- Take one K2_DrawText argument form; true when the engine accepted it.
local function try_draw(canvas, font, i)
    local f = DRAW_FORMS[i]
    return pcall(function()
        canvas:K2_DrawText(
            font,
            "SRT canvas probe",
            f.pos,
            f.color,
            0,
            f.shadow,
            f.offset,
            false,
            false,
            true,
            f.outline
        )
    end)
end

--- Check 5: draw text ourselves from the HUD's canvas draw pass. No widget, no
-- window, no queue — the text is on screen while we keep drawing it.
local function check_canvas(done)
    log("== 5. canvas draw via " .. HUD_DRAW)
    local engine = safe(function() return FindFirstOf("Engine") end, nil)
        or safe(function() return StaticFindObject("/Script/Engine.Default__Engine") end, nil)
    local font = nil
    if engine then
        font = safe(function() return engine.SubtitleFont end, nil)
            or safe(function() return engine.MediumFont end, nil)
            or safe(function() return engine.LargeFont end, nil)
    end
    if not font then
        font = safe(function() return StaticFindObject("/Engine/EngineFonts/Roboto.Roboto") end, nil)
    end
    log("canvas: engine=" .. tostring(engine ~= nil) .. " font=" .. tostring(font ~= nil))

    local calls, form, drawing = 0, nil, true
    local function on_draw(ctx, size_x, size_y)
        calls = calls + 1
        if calls == 1 then
            local sx = tostring(safe(function() return size_x:get() end, nil))
            local sy = tostring(safe(function() return size_y:get() end, nil))
            log("canvas: ReceiveDrawHUD fired, size=" .. sx .. "x" .. sy)
        end
        if not drawing then return nil end
        local self = safe(function() return ctx:get() end, nil)
        local canvas = self and safe(function() return self.Canvas end, nil)
        if not canvas then
            if calls % 60 == 0 then log("canvas: no Canvas on the HUD") end
            return nil
        end
        if not font then return nil end
        if not form then
            log("canvas: calling K2_DrawText")
            for i = 1, #DRAW_FORMS do
                if try_draw(canvas, font, i) then
                    form = i
                    local how = (i == 1) and "named struct fields" or "positional struct fields"
                    log("canvas: K2_DrawText form=" .. i .. " (" .. how .. ")")
                    break
                end
            end
            if not form then
                form = -1
                log("canvas: K2_DrawText rejected both argument forms")
            end
        elseif form > 0 then
            try_draw(canvas, font, form)
        end
        return nil
    end

    local pre, post = RegisterHook(HUD_DRAW, on_draw)
    draw_hook = { pre, post }
    log("canvas: hook ids=" .. tostring(pre) .. "," .. tostring(post))
    ExecuteWithDelay(8000, function()
        ExecuteInGameThread(function()
            drawing = false
            if draw_hook then
                safe(function() UnregisterHook(HUD_DRAW, draw_hook[1], draw_hook[2]) end)
                draw_hook = nil
            end
            log("canvas: done, ReceiveDrawHUD fired " .. calls .. " times")
            done()
        end)
    end)
end

local CHECKS = {
    { name = "1. window", fn = check_window },
    { name = "2. extend", fn = check_extend },
    { name = "3. hold", fn = check_hold },
    { name = "4. spawn", fn = check_spawn },
    { name = "5. canvas", fn = check_canvas },
    { name = "6. burst", fn = check_burst },
}

--- Run one check, marking the probe busy until it reports done.
local function run(check)
    if busy then
        log(check.name .. ": busy, a check is running (0 aborts)")
        return
    end
    busy = true
    ExecuteInGameThread(function()
        check.fn(function()
            busy = false
            log(check.name .. ": finished")
        end)
    end)
end

--- Run checks first..last in order, with a second between them.
local function run_range(first, last)
    if busy then
        log("range: busy, a check is running (0 aborts)")
        return
    end
    busy = true
    local i = first - 1
    local function next_check()
        i = i + 1
        local check = CHECKS[i]
        if not check or i > last then
            busy = false
            log("range: finished")
            return
        end
        ExecuteInGameThread(function()
            check.fn(function()
                log(check.name .. ": finished")
                ExecuteWithDelay(1000, function() next_check() end)
            end)
        end)
    end
    next_check()
end

--- Abort whatever is running and put the banner back.
local function abort()
    log("abort requested")
    busy = false
    ExecuteInGameThread(restore)
end

log("banner_probe v8 loaded; 1..5 checks, 6 = 1..3, 7 burst, 0 abort")
log("log: " .. LOG_PATH)

RegisterKeyBind(Key.ONE, function() run(CHECKS[1]) end)
RegisterKeyBind(Key.TWO, function() run(CHECKS[2]) end)
RegisterKeyBind(Key.THREE, function() run(CHECKS[3]) end)
RegisterKeyBind(Key.FOUR, function() run(CHECKS[4]) end)
RegisterKeyBind(Key.FIVE, function() run(CHECKS[5]) end)
RegisterKeyBind(Key.SIX, function() run_range(1, 3) end)
RegisterKeyBind(Key.SEVEN, function() run(CHECKS[6]) end)
RegisterKeyBind(Key.ZERO, abort)
