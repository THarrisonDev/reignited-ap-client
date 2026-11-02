-- Author: Tim Harrison
-- Created: 2026-09-29
-- Updated: 2026-10-31

-- hud_banner.lua: show received items, sent checks and checkd notices on the
-- game's dragon fanfare banner, one fanfare per burst.
--
-- Fire the game's fanfare, freeze the Intro so the window stays up, then swap
-- the message text line by line; release with the Outro once the queue drains.
-- The measured recipe, freeze points and failure modes are in the "burst mode"
-- notes (docs/fanfare_text.md). The `message text` property is the lever (Base
-- is bound to it) and the only trustworthy readback — Base:GetText() reads back
-- empty while a window is held.
--
-- Release ownership: the game never unpauses the Intro itself, so every path
-- that ends a burst must release the widget this burst froze (`close_window`,
-- `abandon`, `reset`, `note_disconnected`), and nothing else may unpause it.
-- A watchdog reclaims a fanfare still reporting open with no burst to own it.
--
-- Received items are aggregated: the queue is drained into one line per distinct
-- item, so a batch of 32 Dragon Eggs is "Received 32x Dragon Egg" once instead of
-- 32 banners. Sent checks are always individual lines, in order, one per check.
-- The window's length follows that line count (one line per ~1s), and a burst
-- longer than one window's budget spills into the next burst.
--
-- init{log}          wire up logging
-- note_item(name)    queue a received item
-- note_sent(text)    queue an outgoing-send line
-- note_system(text)  queue a checkd notice; preempts the other queues
-- note_disconnected() release a held burst when the socket drops
-- tick()             drive the burst (host poll loop, ~250ms)
-- status()           counters for the heartbeat log

local M = {}

local logger = require("logger")
local U = require("util")

local TAG = "[BANNER]"
local log = logger.tagged(TAG)
local jobs = U.job_runner({
  log = function()
    return log
  end,
})

-- Queues in priority order: system notices preempt items, items outrank sends.
local Q = { system = {}, item = {}, sent = {} }
local ORDER = { "system", "item", "sent" }
local counters = { queued = 0, shown = 0, failed = 0, sent_queued = 0, sent_shown = 0 }

local EFFT_DRAGON, DRAGON = 1, "Nestor" -- stand-in fanfare; the text is ours
local TICK_S = 0.25 -- host poll interval; the module paces itself against it
local WRITE_MS = 100 -- first line lands after the fire (proven)
local FREEZE_MS = 300 -- Intro freeze: 300-450ms holds the window, 580ms is too late
local LINE_TICKS = 4 -- poll ticks a line stays up (~1s each)
local BURST_MAX_TICKS = 60 -- longest one window is held (~15s); the rest of the
-- queue continues in the next burst, so a long replay is slower, never lossy
local GAP_TICKS = 2 -- quiet ticks between bursts
local OPENING_TICKS = 8 -- abandon a burst whose timers never landed (~2s)
local MISS_LIMIT = 3 -- consecutive widget-lookup misses before the burst drops
local STUCK_TICKS = 32 -- polls (~8s) a fanfare may read State == 1 with no burst

local STATE_IDLE, STATE_OPENING, STATE_OPEN = "idle", "opening", "open"
local state = STATE_IDLE
local batch = {} -- this burst's lines: {text, kind, raw, count}
local batch_i = 0 -- index of the line on screen (0 = none yet)
local current = nil -- batch[batch_i]
local written = 0 -- lines written in this burst
local burst_ticks = 0 -- ticks this window has been open
local dwell = 0 -- ticks the current line has been up
local opening = 0 -- ticks spent waiting for the freeze timer
local wait_ticks = 0 -- ticks left before the next burst may open
local gen = 0 -- bumped per burst and per reset; stale timers drop out
local held = nil -- the widget this burst froze; the only one a release may unpause
local misses = 0 -- consecutive get_widget() misses while open
local stuck = 0 -- consecutive polls State == 1 with no burst open
local shown_text = nil -- last line a write confirmed; the watchdog's ownership mark

local kt_lib, hud -- cached handles, re-fetched when they go invalid

--- Return the cached KismetTextLibrary used to convert our strings to FText.
local function get_kt_lib()
  if not U.valid(kt_lib) then
    kt_lib = U.safe(function()
      return StaticFindObject("/Script/Engine.Default__KismetTextLibrary")
    end, nil)
  end
  return U.valid(kt_lib) and kt_lib or nil
end

--- Return the game's HUD, needed to fire a fanfare. Re-fetched when a level
--- transition replaces the controller or the HUD.
local function get_hud()
  if not U.valid(hud) then
    hud = U.safe(function()
      return FindFirstOf("PlayerController"):GetHUD()
    end, nil)
  end
  return U.valid(hud) and hud or nil
end

--- Return the live fanfare widget whose text we overwrite, or nil. Never
--- cached: a stale handle survives a level transition pointing at freed memory.
local function get_widget()
  local w = U.safe(function()
    return FindFirstOf("UI_FanFareMessage_C")
  end, nil)
  return U.valid(w) and w or nil
end

--- Return the highest-priority queue that has a line, or nil.
local function next_queue()
  for _, kind in ipairs(ORDER) do
    if #Q[kind] > 0 then
      return kind, Q[kind]
    end
  end
end

--- Return how many lines are waiting across every queue.
local function queue_len()
  local n = 0
  for _, kind in ipairs(ORDER) do
    n = n + #Q[kind]
  end
  return n
end

--- Return the banner text for one line: received items carry a "Received"
--- prefix and a count, sent checks already read as a sentence and stay verbatim.
--- @param entry table {raw, kind, count}
--- @return string
local function format_line(entry)
  if entry.kind ~= "item" then
    return entry.raw
  end
  if entry.count > 1 then
    return "Received " .. entry.count .. "x " .. entry.raw
  end
  return "Received " .. entry.raw
end

--- Drain the queues into this burst's lines. Repeated received items collapse
--- into one counted line; every sent check keeps its own line, always, so the
--- player can see each thing that left the slot. Order is queue order: items
--- before sends, first-seen first.
--- @return table lines
local function take_batch()
  local lines, index = {}, {}
  for _, kind in ipairs(ORDER) do
    for _, raw in ipairs(Q[kind]) do
      if kind ~= "item" then
        -- individual, never merged
        lines[#lines + 1] = { raw = raw, kind = kind, count = 1, text = raw }
      else
        local key = kind .. "\0" .. raw
        local entry = index[key]
        if entry then
          entry.count = entry.count + 1
          entry.text = format_line(entry)
        else
          entry = { raw = raw, kind = kind, count = 1 }
          entry.text = format_line(entry)
          index[key] = entry
          lines[#lines + 1] = entry
        end
      end
    end
    Q[kind] = {}
  end
  return lines
end

--- Put this burst's unwritten lines back at the head of their queues, so a
--- budget spill or a failed open loses nothing.
--- @param from number index of the first line to return
local function return_lines(from)
  for i = #batch, from, -1 do
    local entry = batch[i]
    for _ = 1, entry.count do
      table.insert(Q[entry.kind], 1, entry.raw)
    end
  end
end

--- Release a frozen fanfare: let the Intro go, play the game's Outro and park
--- the widget where the game expects it. Runs on the game thread.
--- @param w table The widget this burst froze.
local function release(w)
  U.safe(function()
    w:StopAnimation(w.Intro)
  end, nil)
  U.safe(function()
    w:PlayAnimation(w.Outro, 0, 1, 0, 1.0)
  end, nil)
  U.safe(function()
    w.State = 0
  end, nil)
end

--- Submit release(w) to the one-job runner.
--- @param w table The frozen fanfare widget.
--- @param desc string Job name for logs and the abandon WARN.
local function submit_release(w, desc)
  jobs.submit(function()
    release(w)
  end, { desc = desc, fail = desc .. " failed" })
end

--- Drop the burst with no game-thread work; the next one may open after the
--- gap. Safe from inside a game-thread job, where submitting would wedge it.
--- @param reason string|nil WARN line, when the drop is abnormal.
local function drop(reason)
  if reason then
    log.warn(reason)
  end
  state, batch, batch_i, current = STATE_IDLE, {}, 0, nil
  written, burst_ticks, dwell, opening, misses = 0, 0, 0, 0, 0
  held = nil
  wait_ticks = GAP_TICKS
  gen = gen + 1 -- any timer still armed for this burst drops out at its gen check
end

--- Release the burst's frozen widget, then drop the burst. Async thread only:
--- the release runs as a job.
--- @param reason string WARN line naming the failure.
local function abandon(reason)
  local target = U.valid(held) and held or nil
  if target then
    submit_release(target, "banner abandon release")
  end
  drop(reason)
end

--- Write one line into the banner: the property (the lever) and Base (the frame
--- being painted). Runs on the game thread. is_new=false for a re-assert, which
--- must not consume a slot in the burst's pacing.
local function write_line(w, line, is_new)
  if not line then
    return false
  end
  local kt = get_kt_lib()
  local ft = kt and U.safe(function()
    return kt:Conv_StringToText(line.text)
  end, nil)
  if not ft then
    counters.failed = counters.failed + 1
    log.warn("no FText — banner shows canned text: " .. line.text)
    return false
  end
  if is_new ~= false then
    written = written + 1
  end
  U.safe(function()
    w["message text"] = ft
  end, nil)
  local base = U.safe(function()
    return w.Base
  end, nil)
  if base then
    U.safe(function()
      base:SetText(ft)
    end, nil)
  end
  if U.fstr(w, "message text") == line.text then
    shown_text = line.text
    counters.shown = counters.shown + 1
    if line.kind == "sent" then
      counters.sent_shown = counters.sent_shown + 1
    end
    log.info("banner: " .. line.text)
    return true
  end
  counters.failed = counters.failed + 1
  log.warn("banner write not confirmed: " .. line.text)
  return false
end

--- Close the burst: release the widget this burst froze, never a freshly-found
--- instance, and park it. Called from the async tick, so the release is a job.
local function close_window()
  local target = U.valid(held) and held or nil
  if target then
    submit_release(target, "banner close")
    log.debug("burst closed after " .. written .. " line(s)")
  else
    log.warn("burst closed with the frozen fanfare gone — nothing to release")
  end
  drop()
end

--- Fire the fanfare, write the first line, then freeze the Intro to hold the
--- window open. Runs on the game thread and arms the burst's only two timers.
--- @return boolean whether the burst opened
local function open_window(h, w)
  batch = take_batch()
  written, burst_ticks, dwell, opening = 0, 0, 0, 0
  batch_i = 1
  current = batch[1]
  if not current then
    return true
  end
  local items = 0
  for _, entry in ipairs(batch) do
    items = items + entry.count
  end
  log.info(
    string.format(
      "burst open: %d line(s) from %d queued, holding ~%.1fs",
      #batch,
      items,
      #batch * LINE_TICKS * TICK_S
    )
  )
  -- Dot call, exactly as this file has always called it: a wrong UFunction call
  -- shape is a native crash, not a Lua error pcall could catch.
  if not pcall(function()
    h.ShowFanfare(EFFT_DRAGON, DRAGON)
  end) then
    log.warn("ShowFanfare failed — burst dropped")
    return_lines(1) -- nothing was shown: put the whole batch back
    batch, batch_i, current, written, dwell = {}, 0, nil, 0, 0
    return false
  end
  state = STATE_OPENING
  gen = gen + 1
  local my_gen = gen
  ExecuteWithDelay(WRITE_MS, function()
    ExecuteInGameThread(function()
      if my_gen ~= gen then
        return
      end
      if not U.valid(w) then
        drop("fanfare widget went away before the first line")
        return
      end
      write_line(w, current)
      dwell = 0
    end)
  end)
  ExecuteWithDelay(FREEZE_MS, function()
    ExecuteInGameThread(function()
      if my_gen ~= gen then
        return
      end
      if not U.valid(w) then
        drop("fanfare widget went away before the freeze")
        return
      end
      U.safe(function()
        w:PauseAnimation(w.Intro)
      end, nil)
      held = w
      state, opening = STATE_OPEN, 0
    end)
  end)
  return true
end

--- Hold the window and pace the lines. Called once per poll tick while open.
local function step()
  local w = get_widget()
  if not w then
    misses = misses + 1
    if misses < MISS_LIMIT then
      return
    end
    abandon("fanfare widget went missing " .. MISS_LIMIT .. " polls running — burst dropped")
    return
  end
  misses = 0
  if not jobs.ready() then
    return
  end
  dwell = dwell + 1
  burst_ticks = burst_ticks + 1
  if burst_ticks >= BURST_MAX_TICKS then
    -- Out of budget, not out of items: close here and let the next burst carry
    -- on, so a long replay takes longer but loses nothing. Checked before the
    -- re-assert so a property the game repaints cannot hold past the budget.
    local left = #batch - batch_i
    if left > 0 then
      log.info("burst closed at the budget, " .. left .. " line(s) left")
      return_lines(batch_i + 1)
    end
    close_window()
    return
  end
  -- The game can repaint its canned text over ours mid-window; rewrite only
  -- when the property actually changed, never on a timer.
  if current and U.fstr(w, "message text") ~= current.text then
    jobs.submit(function()
      write_line(w, current, false)
    end, { desc = "banner re-assert", fail = "banner re-assert failed" })
    return
  end
  if dwell < LINE_TICKS then
    return
  end
  if batch_i < #batch then
    batch_i = batch_i + 1
    current = batch[batch_i]
    dwell = 0
    local line = current
    jobs.submit(function()
      write_line(w, line)
    end, { desc = "banner line", fail = "banner line failed" })
    return
  end
  close_window()
end

--- Reclaim a fanfare still reporting open with no burst to own it: the game's
--- own window is ~2.8s, so only a leaked freeze exceeds the stuck budget. Only
--- a widget still reading back our own line is ours to release; the game's own
--- messages rewrite the property.
--- @return boolean whether a release was submitted this tick.
local function watchdog()
  local w = get_widget()
  if not w or U.prop(w, "State") ~= 1 then
    stuck = 0
    return false
  end
  if U.fstr(w, "message text") ~= shown_text then
    stuck = 0
    return false
  end
  stuck = stuck + 1
  if stuck < STUCK_TICKS or not jobs.ready() then
    return false
  end
  stuck = 0
  log.warn("fanfare held ~" .. tostring(STUCK_TICKS * TICK_S) .. "s with no burst — releasing it")
  submit_release(w, "banner watchdog release")
  return true
end

--- Open the burst on the game thread, if the widget is there and idle. The
--- game's own fanfare wins: injecting into it collides.
local function try_open()
  local h, w = get_hud(), get_widget()
  if not h or not w or not get_kt_lib() then
    return -- no HUD yet (menu, loading): the next tick tries again
  end
  if U.prop(w, "State") == 1 then
    return -- a fanfare is already showing; the next tick tries again
  end
  return open_window(h, w)
end

--- Start a burst when lines are waiting, the widget is free and the runner is
--- idle. Called from the host tick and from note_system.
local function start()
  if state ~= STATE_IDLE then
    return
  end
  if wait_ticks > 0 then
    wait_ticks = wait_ticks - 1
    return
  end
  if not next_queue() or not jobs.ready() then
    return
  end
  jobs.submit(try_open, { desc = "banner open", fail = "banner open failed" })
end

--- Wire up logging.
--- @param opts table|nil {log}
function M.init(opts)
  log = logger.leveled(TAG, opts and opts.log)
end

--- Clear the per-session queues and counters; a burst in flight releases its
--- frozen widget before it stops.
function M.reset()
  if state ~= STATE_IDLE or U.valid(held) then
    local target = U.valid(held) and held or nil
    if target then
      submit_release(target, "banner reset release")
    end
  end
  Q = { system = {}, item = {}, sent = {} }
  counters = { queued = 0, shown = 0, failed = 0, sent_queued = 0, sent_shown = 0 }
  state, batch, batch_i, current = STATE_IDLE, {}, 0, nil
  written, burst_ticks, dwell, opening, wait_ticks = 0, 0, 0, 0, 0
  misses, stuck, held = 0, 0, nil
  gen = gen + 1
end

--- Drive the burst, called by the host poll loop.
function M.tick()
  if state == STATE_IDLE then
    if watchdog() then
      return -- let the release land before a new burst opens
    end
    start()
  elseif state == STATE_OPENING then
    opening = opening + 1
    if opening > OPENING_TICKS then
      if batch_i >= 1 then
        return_lines(math.min(batch_i + 1, written + 1))
      end
      abandon("burst never opened (freeze timer lost)")
    end
  elseif state == STATE_OPEN then
    step()
  end
end

--- Queue a received item to show.
--- @param name string Item name.
function M.note_item(name)
  if type(name) ~= "string" or name == "" then
    return
  end
  counters.queued = counters.queued + 1
  Q.item[#Q.item + 1] = name
end

--- Queue an outgoing-send line to show; items outrank it, so no immediate action.
--- @param text string Send line.
function M.note_sent(text)
  if type(text) ~= "string" or text == "" then
    return
  end
  counters.sent_queued = counters.sent_queued + 1
  Q.sent[#Q.sent + 1] = text
end

--- Queue a checkd notice that supersedes everything, then open a burst for it:
--- a broken scanner means the player needs to hear about it now, and a refused
--- session is never ticked by the host, so waiting for a tick would never show it.
--- @param text string One-line notice.
function M.note_system(text)
  if type(text) ~= "string" or text == "" then
    return
  end
  Q = { system = { text }, item = {}, sent = {} }
  start()
end

--- Release a held burst when the AP socket drops. The host stops ticking while
--- disconnected, so without this the freeze would last the whole outage.
function M.note_disconnected()
  if state == STATE_IDLE then
    return
  end
  if batch_i < #batch then
    return_lines(math.min(batch_i + 1, written + 1))
  end
  abandon("AP disconnected — banner released")
end

--- Return counters for the heartbeat log.
--- @return string
function M.status()
  return string.format(
    "state=%s queued=%d shown=%d failed=%d waiting=%d left=%d sent=%d sent_queued=%d sent_waiting=%d held=%s stuck=%d misses=%d",
    state,
    counters.queued,
    counters.shown,
    counters.failed,
    queue_len(),
    math.max(0, #batch - batch_i),
    counters.sent_shown,
    counters.sent_queued,
    #Q.sent,
    U.valid(held) and "y" or "n",
    stuck,
    misses
  )
end
M.tag = TAG

return M
