-- hud_banner.lua: shows each received item on the game's fanfare banner at
-- the bottom of the screen.
--
-- The fanfare widget is the only banner we can put custom text on. So we fire
-- a normal dragon fanfare (the name just has to satisfy a lookup table) and
-- overwrite its message text right after; the widget then keeps showing our
-- string for the rest of its window. Calling ShowFanfare with our own text
-- doesn't work, and SetText on its own has no window to live in. See
-- docs/fanfare_text.md for how this was figured out.
--
-- init{log, display}   display is how long each banner stays up (default 3s)
-- note_item(name)      queue a received item to show
-- note_sent(text)      queue an outgoing-send line to show
-- tick()               called by the host poll loop
-- status()             counters for the heartbeat log
--
-- Received and sent share one fanfare window. A received item is what the
-- player just did, so it always shows before anything sent; sent lines only
-- appear once the received queue is empty, and a batch of sends collapses to
-- its newest line so a big collection can't flood the HUD.
--
-- One banner at a time. The next one waits for the current one to finish its
-- display window, otherwise the text gets restarted before you can read it.
-- If a lot pile up we just keep the newest.

local M = {}

local logger = require("logger")
local U = require("util")

local log = logger.tagged("[BANNER]")
local jobs = U.job_runner{log = function() return log end}

local queue = {}                          -- received item names waiting to show
local sent_queue = {}                     -- outgoing-send lines waiting to show
local queued, shown, failed = 0, 0, 0     -- running totals
local sent_queued, sent_shown = 0, 0      -- outgoing-send totals
local display = 3                         -- seconds each banner stays up
local last_shown = 0                      -- when the current banner went up
local epoch = 0                           -- show counter, used to drop stale redos

local EFFT_DRAGON = 1
local kt_lib = nil                        -- cached KismetTextLibrary

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

local function apply_write(fmw, kt, text, my_epoch)
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
    -- the widget redraws once more as its animation kicks in, which can wipe
    -- what we just wrote, so check back in a couple of seconds and redo it
    if type(ExecuteWithDelay) == "function" then
        ExecuteWithDelay(2000, function()
            ExecuteInGameThread(function()
                if my_epoch ~= epoch then return end   -- a newer banner has it now
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

-- Fire a fanfare, then swap in our text once it's on screen.
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
    epoch = epoch + 1
    last_shown = os.time()
    local my_epoch = epoch
    -- "Nestinor" is only here to get past the dragon-name lookup
    U.safe(function() hud.ShowFanfare(EFFT_DRAGON, "Nestinor") end)
    -- wait for it to render before overwriting (10ms is enough, 100ms is
    -- safe), still on the game thread
    if type(ExecuteWithDelay) ~= "function" then
        apply_write(fmw, kt, text, my_epoch)
        return true
    end
    ExecuteWithDelay(100, function()
        ExecuteInGameThread(function() apply_write(fmw, kt, text, my_epoch) end)
    end)
    return true
end

-- Show the next banner if one is due. We hold off until the current banner's
-- display window is over, otherwise a new fanfare restarts the widget and the
-- text never gets a chance to show. Received items outrank sent lines; each
-- queue collapses to its newest entry when it backs up.
local function drain()
    if #queue == 0 and #sent_queue == 0 then return end
    if not jobs.ready() then return end
    if os.time() - last_shown < display then return end
    local from_sent = #queue == 0
    local q = from_sent and sent_queue or queue
    local text = table.remove(q, 1)
    jobs.submit(function()
        local ok = show(text)
        if #q > 2 then
            -- replaying old fanfares back to back just flashes, so skip to
            -- the newest one instead
            local dropped = #q - 1
            local latest = table.remove(q)
            -- keep only the newest, mutated in place (a plain `queue = {}`
            -- would leave the caller's upvalue pointing at the old table)
            for i = #q, 1, -1 do q[i] = nil end
            q[1] = latest
            log.warn("banner backlog collapsed, dropped " .. dropped)
        end
        if from_sent and ok then sent_shown = sent_shown + 1 end
        return ok and true or false      -- false makes the runner back off
    end, {desc = "banner job", fail = "banner apply failed"})
end

function M.init(opts)
    log = logger.leveled("[BANNER]", opts and opts.log)
    if opts and type(opts.display) == "number" then display = opts.display end
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

function M.note_sent(text)
    if type(text) ~= "string" or text == "" then return end
    sent_queued = sent_queued + 1
    sent_queue[#sent_queue + 1] = text
    -- no immediate drain: a received item noted just after this must show
    -- first, so let tick() (or the next note_item) pick sent lines up once
    -- the received queue is empty.
end

function M.status()
    return string.format(
        "queued=%d shown=%d failed=%d waiting=%d sent=%d sent_queued=%d sent_waiting=%d",
        queued, shown, failed, #queue, sent_shown, sent_queued, #sent_queue)
end

return M