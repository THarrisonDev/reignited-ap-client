-- hud_banner.lua: shows each received item on the game's fanfare banner at
-- the bottom of the screen.
--
-- The fanfare widget is the only banner we can put custom text on, so we fire
-- a normal dragon fanfare and overwrite its message text right after. See
-- docs/fanfare_text.md.
--
-- init{log, display}   display is how long each banner stays up (default 3s)
-- note_item(name)      queue a received item to show
-- note_sent(text)      queue an outgoing-send line to show
-- tick()               called by the host poll loop
-- status()             counters for the heartbeat log

local M = {}

local logger = require("logger")
local U = require("util")

local log = logger.tagged("[BANNER]")
local jobs = U.job_runner({
  log = function()
    return log
  end,
})

local queue = {} -- received item names waiting to show
local sent_queue = {} -- outgoing-send lines waiting to show
local queued, shown, failed = 0, 0, 0 -- running totals
local sent_queued, sent_shown = 0, 0 -- outgoing-send totals
local display = 3 -- seconds each banner stays up
local last_shown = 0 -- when the current banner went up
local epoch = 0 -- show counter, used to drop stale redos
local show_seq = 0 -- bumped per show(); stale async waits abort on a mismatch
local pending = false -- true while a show() is waiting for an idle widget

local EFFT_DRAGON = 1
local kt_lib, cached_hud = nil, nil -- cached KismetTextLibrary and HUD
local IDLE_RETRY_MS = 100 -- poll interval while waiting for an idle widget
local MAX_IDLE_RETRIES = 20 -- ~2s; give up and drop the banner past this

--- Return the cached KismetTextLibrary used to convert our strings to FText.
--- @return userdata|nil
local function get_kt_lib()
  if U.valid(kt_lib) then
    return kt_lib
  end
  kt_lib = U.safe(function()
    return StaticFindObject("/Script/Engine.Default__KismetTextLibrary")
  end, nil)
  return U.valid(kt_lib) and kt_lib or nil
end

--- Return the game's HUD, needed to fire a fanfare. Cached and re-fetched when
--- the controller or HUD is replaced by a level transition.
--- @return userdata|nil
local function get_hud()
  if U.valid(cached_hud) then
    return cached_hud
  end
  local pc = U.safe(function()
    return FindFirstOf("PlayerController")
  end, nil)
  if not pc then
    cached_hud = nil
    return nil
  end
  cached_hud = U.safe(function()
    return pc.GetHUD()
  end, nil)
  return U.valid(cached_hud) and cached_hud or nil
end

--- Return the live fanfare widget whose text we overwrite.
--- @return userdata|nil
local function get_widget()
  local w = U.safe(function()
    return FindFirstOf("UI_FanFareMessage_C")
  end, nil)
  return U.valid(w) and w or nil
end

--- Return the widget's live `message text` property, or nil when unreadable.
--- The property is the real lever: Base is bound to it, so a direct Base
--- SetText is overridden on the next repaint. Judging on the property keeps a
--- normal banner to a single write — chasing the Base readback (always
--- canned/blank) rewrote the widget on every re-assert and closed its window.
--- @param fmw userdata
--- @return string|nil
local function current_prop_text(fmw)
  return U.safe(function()
    return fmw["message text"]:ToString()
  end, nil)
end

--- Write our FText into the widget and report whether the property held; Base
--- is written too so the current frame paints our text.
--- @return boolean
local function write_props(fmw, base, ftext, text)
  pcall(function()
    fmw["message text"] = ftext
  end)
  if base then
    pcall(function()
      base:SetText(ftext)
    end)
  end
  return current_prop_text(fmw) == text
end

--- Re-assert our text when a redraw wiped it; do nothing if a newer banner
--- owns the widget. Reads the property, not Base, so an untouched banner is
--- left alone rather than rewritten (which would close its window).
local function reassert(fmw, base, ftext, text, my_epoch)
  if my_epoch ~= epoch then
    return false
  end
  if current_prop_text(fmw) == text then
    return true
  end
  return write_props(fmw, base, ftext, text)
end

--- Write text into the fanfare widget, confirming the readback and re-asserting
--- across the display window as its animation redraws.
--- @param fmw userdata Fanfare widget from get_widget().
--- @param kt userdata KismetTextLibrary from get_kt_lib().
--- @param text string Banner text to show.
--- @param my_epoch number Show counter this write belongs to.
--- @return boolean success
local function apply_write(fmw, kt, text, my_epoch)
  local ftext = U.safe(function()
    return kt:Conv_StringToText(text)
  end, nil)
  if not ftext then
    log.warn("no FText conversion — banner shows canned text: " .. text)
    return
  end
  local base = U.safe(function()
    return fmw.Base
  end, nil)
  if write_props(fmw, base, ftext, text) then
    shown = shown + 1
    log.info("banner: " .. text)
  else
    failed = failed + 1
    log.warn("banner write not confirmed: " .. text)
  end
  -- the Intro/Outro redraws can wipe our text mid-window; the window is ~2.8s
  -- (measured, docs/fanfare_text.md), so re-assert early and often, stopping
  -- once it sticks
  if type(ExecuteWithDelay) == "function" then
    for _, ms in ipairs({ 400, 900, 1500 }) do
      ExecuteWithDelay(ms, function()
        ExecuteInGameThread(function()
          reassert(fmw, base, ftext, text, my_epoch)
        end)
      end)
    end
  end
  return true
end

--- Return the widget's State field (0 idle, 1 showing), or nil if unreadable.
--- State is the only reliable open/close signal; see docs/fanfare_text.md.
--- @param fmw userdata
--- @return number|nil
local function widget_state(fmw)
  local s = U.prop(fmw, "State")
  return type(s) == "number" and s or nil
end

--- Fire a fanfare, then swap in our text once it's on screen. Waits for the
--- widget to go idle first: injecting while the game is mid-fanfare (a counter
--- redraw at connect, say) queues our entry behind the game's and the write
--- lands on the wrong window. See docs/fanfare_text.md.
--- @param text string Banner text to show.
--- @return boolean success
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

  show_seq = show_seq + 1
  local my_seq = show_seq
  pending = true

  -- Test stubs may omit ExecuteWithDelay; fire + write immediately.
  if type(ExecuteWithDelay) ~= "function" then
    epoch = epoch + 1
    last_shown = os.time()
    pending = false
    local my_epoch = epoch
    U.safe(function()
      hud.ShowFanfare(EFFT_DRAGON, "Nestor")
    end)
    apply_write(fmw, kt, text, my_epoch)
    return true
  end

  local function wait_idle(attempt)
    if my_seq ~= show_seq then
      return -- a newer show superseded us
    end
    local st = widget_state(fmw)
    if st == 1 and attempt < MAX_IDLE_RETRIES then
      ExecuteWithDelay(IDLE_RETRY_MS, function()
        ExecuteInGameThread(function()
          wait_idle(attempt + 1)
        end)
      end)
      return
    end
    if st == 1 then
      pending = false
      log.warn("widget busy " .. attempt .. " retries — banner dropped: " .. text)
      return
    end
    epoch = epoch + 1
    last_shown = os.time()
    pending = false
    local my_epoch = epoch
    -- ShowFanfare's name must resolve in the dragon table; Nestor is present,
    -- so use him as a stand-in and overwrite the text once our window opens.
    U.safe(function()
      hud.ShowFanfare(EFFT_DRAGON, "Nestor")
    end)
    -- Wait for it to render before overwriting, still on the game thread.
    ExecuteWithDelay(100, function()
      ExecuteInGameThread(function()
        apply_write(fmw, kt, text, my_epoch)
      end)
    end)
  end

  wait_idle(0)
  return true
end

--- Show the next banner if one is due. Received items outrank sent lines; each
--- queue collapses to its newest entry when it backs up.
local function drain()
  if #queue == 0 and #sent_queue == 0 then
    return
  end
  if not jobs.ready() then
    return
  end
  if pending then
    return
  end
  if os.time() - last_shown < display then
    return
  end
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
      for i = #q, 1, -1 do
        q[i] = nil
      end
      q[1] = latest
      log.warn("banner backlog collapsed, dropped " .. dropped)
    end
    if from_sent and ok then
      sent_shown = sent_shown + 1
    end
    return ok and true or false -- false makes the runner back off
  end, { desc = "banner job", fail = "banner apply failed" })
end

--- Wire up logging and the per-banner display time.
--- @param opts table|nil {log, display}
function M.init(opts)
  log = logger.leveled("[BANNER]", opts and opts.log)
  if opts and type(opts.display) == "number" then
    display = opts.display
  end
end

--- Drive the queue, called by the host poll loop.
function M.tick()
  drain()
end

--- Queue a received item to show.
--- @param name string Item name.
function M.note_item(name)
  if type(name) ~= "string" or name == "" then
    return
  end
  queued = queued + 1
  queue[#queue + 1] = name
  drain()
end

--- Queue an outgoing-send line to show.
--- @param text string Send line.
function M.note_sent(text)
  if type(text) ~= "string" or text == "" then
    return
  end
  sent_queued = sent_queued + 1
  sent_queue[#sent_queue + 1] = text
  -- no immediate drain: a received item noted just after this must show
  -- first, so let tick() (or the next note_item) pick sent lines up once
  -- the received queue is empty.
end

--- Return counters for the heartbeat log.
--- @return string
function M.status()
  return string.format(
    "queued=%d shown=%d failed=%d waiting=%d sent=%d sent_queued=%d sent_waiting=%d",
    queued,
    shown,
    failed,
    #queue,
    sent_shown,
    sent_queued,
    #sent_queue
  )
end

return M
