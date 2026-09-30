-- hud_banner.lua: bottom-of-screen banner for received items. Uses the
-- fanfare widget's own display window, proven in fanfare_test (Sept 2026,
-- docs/fanfare_text.md): HUD.ShowFanfare(EFFT_Dragon=1, "Nestinor") starts a
-- real banner; ~100ms later (write landed and stuck at 100ms, 250, ..., 8s
-- in the probe) "message text" is overwritten with our FText and the Base
-- TextBlock too — the banner shows the custom string for the rest of the
-- window. Direct ShowFanfare(name) text does NOT work (name hits a dragon
-- lookup table); raw SetText without a fanfare has no window.
--
-- API: init(opts), note_item(name), status().
-- note_item queues; the runner shows one banner at a time (latest wins on a
-- backlog, earliest dropped). All game access inside ONE ExecuteInGameThread
-- job per banner (crash lessons in the probe mod source).

local M = {}

local logger = require("logger")
local U = require("util")

local log = logger.tagged("[BANNER]")
local jobs = U.job_runner{log = function() return log end}
local queue = {}            -- strings, FIFO
local queued, shown, failed = 0, 0, 0

local EFFT_DRAGON = 1

-- KismetTextLibrary default object: Conv_StringToText source
local kt_lib = nil

local function get_kt_lib()
    if U.valid(kt_lib) then return kt_lib end
    kt_lib = U.safe(function()
        return StaticFindObject("/Script/Engine.Default__KismetTextLibrary")
    end, nil)
    return U.valid(kt_lib) and kt_lib or nil
end

local function get_hud()
    local pc = U.safe(function() return FindFirstOf("PlayerController") end, nil)
    if not pc then return nil end
    local hud = U.safe(function() return pc.GetHUD() end, nil)
    return U.valid(hud) and hud or nil
end

local function get_widget()
    return U.safe(function() return FindFirstOf("UI_FanFareMessage_C") end, nil)
end

local function apply_write(fmw, kt, text)
    local ftext = U.safe(function() return kt:Conv_StringToText(text) end, nil)
    if not ftext then
        log.warn("no FText conversion — banner shows canned text: " .. text)
        return
    end
    local okprop = pcall(function() fmw["message text"] = ftext end)
    local base = U.safe(function() return fmw.Base end, nil)
    local okbase = base and pcall(function() base:SetText(ftext) end) or false
    if okprop or okbase then
        shown = shown + 1
        log.info("banner: " .. text)
    else
        failed = failed + 1
        log.warn("banner write failed: " .. text)
    end
    -- +2s re-assert: a following anim event that re-renders before our
    -- write is caught in the probe; re-write once for convergence
    if type(ExecuteWithDelay) == "function" then
        ExecuteWithDelay(2000, function()
            ExecuteInGameThread(function()
                local cur = U.safe(function()
                    return fmw["message text"]:ToString() end, nil)
                if cur == text then return end
                pcall(function() fmw["message text"] = ftext end)
                if base then pcall(function() base:SetText(ftext) end) end
            end)
        end)
    end
    return true
end

-- one banner show: fanfare -> 100ms -> property+TextBlock write
local function show(text)
    local hud = get_hud()
    if not hud then
        log.warn("no HUD — banner dropped: " .. text)
        return false
    end
    local fmw = get_widget()
    if not fmw then
        log.warn("no fanfare widget — banner dropped: " .. text)
        return false
    end
    local kt = get_kt_lib()
    if not kt then
        log.warn("no KismetTextLibrary — banner dropped: " .. text)
        return false
    end
    -- start a real banner (dragon rescue path, name goes to table)
    U.safe(function() hud.ShowFanfare(EFFT_DRAGON, "Nestinor") end)
    -- write at +100ms (proven floor in the probe); one timer hop, then the
    -- game thread — same shape as the probe's proven serial pattern
    if type(ExecuteWithDelay) ~= "function" then
        -- no timers: write immediately (may be eaten by the binding; the
        -- +2s re-assert below still converges)
        apply_write(fmw, kt, text)
        return true
    end
    ExecuteWithDelay(100, function()
        ExecuteInGameThread(function() apply_write(fmw, kt, text) end)
    end)
    return true
end


-- drain: one banner per ready() job slot; a backlog keeps only the latest
-- (older banners would just queue the same fanfare repeatedly)
local function drain()
    if not jobs.ready() or #queue == 0 then return end
    local text = table.remove(queue, 1)
    jobs.submit(function()
        local ok = show(text)
        if #queue > 2 then
            -- collapse: keep only the newest backlog entry — older banners
            -- would just replay the same fanfare back to back
            local dropped = #queue - 1
            local latest = table.remove(queue)
            queue = { latest }
            log.warn("banner backlog collapsed, dropped " .. dropped)
        end
        return ok and true or false      -- false triggers runner backoff
    end, {desc = "banner job", fail = "banner apply failed"})
end

function M.init(opts)
    log = logger.leveled("[BANNER]", opts and opts.log)
end

function M.tick()
    drain()
end

function M.note_item(name)
    if type(name) ~= "string" or name == "" then return end
    queued = queued + 1
    queue[#queue + 1] = name
    drain()
end

function M.status()
    return string.format("queued=%d shown=%d failed=%d waiting=%d",
        queued, shown, failed, #queue)
end

return M