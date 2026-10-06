-- fanfare_test: independent UE4SS mod measuring how long the HUD fanfare
-- banner (`UI_FanFareMessage_C`, the "x/x dragons!" popup) stays on screen.
-- Read-only vs the save: message display + widget state only, no progression
-- writes.
--
-- Why: hud_banner.lua overwrites the banner text and re-asserts across its
-- window, so we need the real window length to space re-asserts and banners.
-- Two facts matter:
--   1. window lifetime: sample widget `State` (0=idle, 1=showing) — see
--      docs/fanfare_text.md. `IsVisible()` is always true and opacity stays
--      1.00, so neither is a closure signal.
--   2. whether our text STAYS on screen: the displayed text is
--      `Base:GetText()`, NOT the `message text` property. hud_banner's
--      readback checks the property it just wrote (tautological, always
--      "confirmed"), so a game-side Tick/binding can repaint Base back to
--      "Rescued ..." while we never notice. Sample Base text to catch that.
--   3. collision with the game's own fanfare queue: `ShowFanfare` and our
--      injection both land in `pending immediate messages`, drained FIFO by
--      the widget's Tick. Sampling the queue depth and `State` shows whether
--      our entry waits behind a game entry and gets clobbered. Pressing DEL
--      while a banner is already up deliberately tests this.
--
-- THREADING: keybind callbacks do NOT run on the async Lua tick, so every
-- game-object access is wrapped in ExecuteInGameThread. `ExecuteWithDelay`
-- chains fine around it.
--
-- Install: copy to <game>/Falcon/Binaries/Win64/Mods/fanfare_test and add
-- "fanfare_test : 1" to mods.txt.
--
-- Press DEL in-game (during gameplay, not menus): fires a dragon fanfare,
-- writes a sentinel after 100ms (the production recipe), then samples every
-- 25ms, logging every field transition until the window closes. If a window
-- is already up when pressed, it reports the queue depth it found first, so
-- the collision case is captured on purpose. The summary reports the last
-- sample where the banner looked visible plus a full final field dump.

local MOD_DIR = debug.getinfo(1, "S").source:match("^@(.*[/\\])")
local LOG_PATH = MOD_DIR .. "FanfareTest.log"

local log_fh = nil
local function log(line)
    local stamped = os.date("%H:%M:%S ") .. line .. "\n"
    print("[FANFARE] " .. line .. "\n")
    local f = log_fh
    if f then
        if pcall(function() f:write(stamped) f:flush() end) then return end
        pcall(function() f:close() end)
        log_fh = nil
    end
    f = io.open(LOG_PATH, "a")
    if f then log_fh = f; pcall(function() f:write(stamped) f:flush() end) end
end

local function safe(fn, default)
    local ok, res = pcall(fn)
    if ok then return res end
    if type(res) == "function" then
        local _, msg = pcall(res)
        log("safe() swallowed: " .. tostring(msg))
    else
        log("safe() swallowed: " .. tostring(res))
    end
    return default
end

-- EFanfareType (docs/falcon_sdk_dump/Falcon_enums.hpp:262)
local EFFT_DRAGON = 1
local SENTINEL = "SRT_LIFETIME_PROBE"
local SAMPLE_MS = 25
local MAX_MS = 12000

local function probe()
    local hud = safe(function()
        return FindFirstOf("PlayerController"):GetHUD() end, nil)
    if not hud then log("lifetime probe: no HUD"); return end
    local fmw = safe(function() return FindFirstOf("UI_FanFareMessage_C") end, nil)
    if not fmw then log("lifetime probe: no UI_FanFareMessage_C"); return end
    local kt = safe(function()
        return StaticFindObject("/Script/Engine.Default__KismetTextLibrary")
    end, nil)
    if not kt then log("lifetime probe: no KismetTextLibrary"); return end
    local ftext = safe(function() return kt:Conv_StringToText(SENTINEL) end, nil)
    if not ftext then log("lifetime probe: no FText"); return end

    local function qdepth()
        return tonumber(safe(function() return #fmw["pending immediate messages"] end, 0)) or 0
    end
    local function snap()
        return {
            state = tonumber(safe(function() return fmw.State end, nil)),
            queue = qdepth(),
            base = safe(function() return fmw.Base:GetText():ToString() end, nil),
            prop = safe(function() return fmw["message text"]:ToString() end, nil),
        }
    end
    local function fmt(s)
        return string.format("state=%s queue=%s base='%s' prop='%s'",
            tostring(s.state), tostring(s.queue), tostring(s.base), tostring(s.prop))
    end

    local prev = snap()
    log("lifetime probe: baseline " .. fmt(prev))
    if prev.state == 1 then
        log("lifetime probe: window already up (collision test); queue=" .. prev.queue)
    end
    safe(function() hud.ShowFanfare(EFFT_DRAGON, "Nestinor") end)

    local n, last_visible_ms, clobbered_ms, stuck_ms = 0, nil, nil, nil
    local sample
    sample = function()
        n = n + 1
        local s = snap()
        if s.state ~= prev.state or s.queue ~= prev.queue or
            s.base ~= prev.base or s.prop ~= prev.prop then
            log(string.format("lifetime @%dms %s", n * SAMPLE_MS, fmt(s)))
            prev = s
        end
        -- production writes both; Base is what the player sees. Record when
        -- our text first reaches Base, and when the game later reverts it.
        if s.base == SENTINEL then
            stuck_ms = stuck_ms or n * SAMPLE_MS
        elseif stuck_ms and not clobbered_ms then
            clobbered_ms = n * SAMPLE_MS
        end
        if s.state == 1 then last_visible_ms = n * SAMPLE_MS end
        if n * SAMPLE_MS >= MAX_MS then
            log("lifetime probe done: last_visible~" .. tostring(last_visible_ms) ..
                "ms stuck~" .. tostring(stuck_ms) .. "ms clobbered~" ..
                tostring(clobbered_ms) .. "ms tail " .. fmt(s))
            return
        end
        ExecuteWithDelay(SAMPLE_MS, function() ExecuteInGameThread(sample) end)
    end

    -- match the production recipe: render first, then overwrite property +
    -- Base, then sample
    ExecuteWithDelay(100, function()
        ExecuteInGameThread(function()
            pcall(function() fmw["message text"] = ftext end)
            pcall(function() fmw.Base:SetText(ftext) end)
            sample()
        end)
    end)
    log("lifetime probe: fired; sampling every " .. SAMPLE_MS .. "ms for " .. MAX_MS .. "ms")
end

log("fanfare_test v7 loaded; press DEL during gameplay to measure window + queue collision")

RegisterKeyBind(Key.DEL, {}, function()
    if type(ExecuteInGameThread) ~= "function" then
        log("lifetime probe: ExecuteInGameThread unavailable")
        return
    end
    ExecuteInGameThread(probe)
end)
