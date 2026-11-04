-- Author: Tim Harrison
-- Created: 2026-09-29
-- Updated: 2026-11-03

-- hud_banner.lua: show received items, sent checks and checkd notices on the
-- game's dragon fanfare banner, one fanfare per burst.
--
-- Fire the game's fanfare, freeze the Intro so the window stays up, then swap
-- the message text line by line; release by resuming the Intro once the queue
-- drains, so the widget's own chain plays the Outro and clears its state.
-- The measured recipe, freeze points and failure modes are in the "burst mode"
-- notes (docs/fanfare_text.md). The `message text` property is the lever (Base
-- is bound to it) and the only trustworthy readback — Base:GetText() reads back
-- empty while a window is held.
--
-- Release ownership: the game never unpauses the Intro itself, so the frozen
-- widget is a lease. Every path that ends a burst (`close_window`, `abandon`,
-- `reset`, `note_disconnected`) hands the window back by resuming the paused
-- Intro; the widget's own OnAnimationFinished chain then plays the Outro and
-- writes `state = 0`. `state` is the widget's to write, never ours: stopping
-- the Intro instead kills the chain and can strand the window at `state == 1`
-- (the 2026-11-02 wedge). A resume that has not closed the window after ~4s
-- falls back once to the legacy close and is then relinquished. Ownership is
-- the lease, never the text on screen: a fanfare the module holds no lease on
-- is the game's own chain and is left alone.
--
-- Received items are aggregated: the queue is drained into one line per distinct
-- item, so a batch of 32 Dragon Eggs is "Received 32x Dragon Egg" once instead of
-- 32 banners. Sent checks are always individual lines, in order, one per check.
-- The window's length follows that line count (one line per ~1s), and a burst
-- longer than one window's budget spills into the next burst.
--
-- Received items carry a watermark, kept in the shared srtap_state file for
-- this seed+slot so a later session does not replay the item history AP
-- re-delivers on every connect, while items AP granted while the game was closed
-- (the tail of that sync) are still announced. It is written at the module's
-- durability points only — prime end, every ten new items, menu return, socket
-- drop — never per item or per burst, and it suppresses the banner only: the
-- item fan-out still counts the whole backlog, because the reconciles' recount
-- depends on it.

local M = {}

local logger = require("logger")
local U = require("util")
local S = require("srtap_state")

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

local dir = nil -- the host's state directory (fillers shares the same file)
local shown_upto = -1 -- highest AP item index this connect has accounted for
local flushed_upto = -1 -- shown_upto at the last persisted write
local ITEM_FLUSH_EVERY = 10 -- new items that force a mid-session flush
local priming = false -- the connect backlog is still arriving: swallow it
local prime_quiet = 0 -- in-play polls with no item since the last one
local primed = 0 -- items the current prime treated as history
local backlog = 0 -- items suppressed because they were already announced

local EFFT_DRAGON, DRAGON = 1, "Nestor" -- stand-in fanfare; the text is ours
local TICK_S = 0.25 -- host poll interval; the module paces itself against it
local WRITE_MS = 100 -- first line lands after the fire (proven)
local FREEZE_MS = 300 -- Intro freeze: 300-450ms holds the window, 580ms is too late.
-- 450 was tried for readability (the glow has cleared by then) but on the live
-- machine the window then closed ~1s into every burst: the hold is frame-rate
-- sensitive, so stay at the low end.
local LINE_TICKS = 4 -- poll ticks a line stays up (~1s each)
local BURST_MAX_TICKS = 60 -- longest one window is held (~15s); the rest of the
-- queue continues in the next burst, so a long replay is slower, never lossy
local GAP_TICKS = 2 -- quiet ticks between bursts
local HAND_BACK_GAP = 4 -- first backoff after a burst is handed back (~1s)
local HAND_BACK_MAX = 40 -- longest backoff after repeated hand-backs (~10s)
local OPENING_TICKS = 8 -- abandon a burst whose timers never landed (~2s)
local MISS_LIMIT = 3 -- consecutive widget-lookup misses before the burst drops
local RESUME_VERIFY_TICKS = 16 -- in-play polls (~4s) a resumed Intro gets to close itself
local FALLBACK_VERIFY_TICKS = 4 -- in-play polls (~1s) the legacy close gets to land
local IDLE_OPEN_TICKS = 120 -- in-play polls (~30s) the game's own window may hold
local PRIME_QUIET_TICKS = 4 -- in-play polls (~1s) of quiet that end the connect prime

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
local misses = 0 -- consecutive get_widget() misses while open
local hand_backs = 0 -- bursts handed back in a row without a normal close
local ticks = 0 -- in-play polls so far; the lease's retry clock
local lease = nil -- the window this module froze: {w, state, stage, attempts, due}
local idle_open = 0 -- consecutive in-play polls the game's own window has shown
local idle_warned = false -- the idle-open WARN was already logged this session
local not_in_play_seen = false -- the last tick was not in play: re-assert on resume
local not_in_play = false -- the last tick saw a game that was not in play: no burst

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

--- Return the widget this module's lease froze, or nil once the lease is gone or
--- the game destroyed the instance. Only this one may be written or released.
local function leased_widget()
  if not lease then
    return nil
  end
  return U.valid(lease.w) and lease.w or nil
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

--- Hand the window back to the widget's own chain: resume the paused Intro from
--- where the freeze caught it. Never writes State, stops the Intro or plays the
--- Outro — the widget's OnAnimationFinished chain owns all three, and skipping
--- it can leave `state` stuck at 1. Runs on the game thread.
--- @param w table The widget this burst froze.
--- @return boolean whether the Intro could be resumed.
local function release(w)
  local at = U.safe(function()
    return w:GetAnimationCurrentTime(w.Intro)
  end, nil)
  if type(at) ~= "number" or at <= 0 then
    return false -- not paused or already finished: only the legacy close is left
  end
  U.safe(function()
    w:PlayAnimation(w.Intro, at, 1, 0, 1.0)
  end, nil)
  return true
end

--- The legacy close, kept only as a fallback for a widget whose chain is not
--- waiting on a paused Intro: stop it, play the Outro and park State. Runs on
--- the game thread.
--- @param w table The widget this burst froze.
local function release_legacy(w)
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

--- Submit the lease's release to the one-job runner: resume the Intro (stage 1),
--- and fall back to the legacy close (stage 2) only when it cannot be resumed. A
--- failed resume re-times the lease for the fallback's shorter verification.
--- @param w table The frozen fanfare widget.
--- @param desc string Job name for logs and the abandon WARN.
local function submit_release(w, desc)
  local stage = lease and lease.stage or "resume"
  jobs.submit(function()
    if stage == "resume" and release(w) then
      log.info("released by resuming the Intro")
      return
    end
    log.warn("fanfare release fallback: StopAnimation + Outro + State (resume did not hand the window back)")
    if stage == "resume" and lease then
      lease.stage, lease.due = "fallback", ticks + FALLBACK_VERIFY_TICKS
    end
    release_legacy(w)
  end, { desc = desc, fail = desc .. " failed" })
end

--- Submit the lease's release and arm its verification on a later in-play tick.
--- The resume stage gets ~4s for Intro remainder + the 2.0s Delay + the Outro;
--- the fallback stage ~1s. The lease stays until a readback confirms the close.
--- @param desc string Job name for the submitted release.
local function request_release(desc)
  if not lease then
    return
  end
  local w = leased_widget()
  if w then
    submit_release(w, desc)
  end
  local wait = lease.stage == "fallback" and FALLBACK_VERIFY_TICKS or RESUME_VERIFY_TICKS
  lease.state, lease.attempts, lease.due = "releasing", lease.attempts + 1, ticks + wait
end

--- Drop the burst with no game-thread work; the next one may open after the
--- gap. Safe from inside a game-thread job, where submitting would wedge it.
--- The lease survives: a release already submitted is verified on a later tick.
--- @param reason string|nil WARN line, when the drop is abnormal.
local function drop(reason)
  if reason then
    log.warn(reason)
  end
  state, batch, batch_i, current = STATE_IDLE, {}, 0, nil
  written, burst_ticks, dwell, opening, misses = 0, 0, 0, 0, 0
  wait_ticks = GAP_TICKS
  gen = gen + 1 -- any timer still armed for this burst drops out at its gen check
end

--- Hand the window back to the widget's own chain: requeue the lines that did
--- not land — the one on screen included, since on a steal the player saw the
--- game's text and on a close we cannot prove it held its dwell — clear the lease
--- without releasing, and drop the burst. A closed or borrowed window must not be
--- touched: a release would either kill the game's chain (the 2026-11-02 wedge)
--- or act on a window that is already gone.
--- @param reason string Why the window is no longer ours.
local function hand_back(reason)
  log.info(reason .. ", " .. (#batch - batch_i + 1) .. " line(s) requeued")
  return_lines(math.max(batch_i, 1))
  lease = nil
  drop()
  -- A window that keeps dying re-opened every gap would fire a fanfare each
  -- time; back off further with each consecutive hand-back (a normal close and
  -- a session reset both clear the streak).
  hand_backs = hand_backs + 1
  -- One hand-back keeps the normal gap; a streak backs off, so a window that
  -- keeps dying cannot fire a fanfare every couple of seconds.
  wait_ticks = hand_backs == 1 and GAP_TICKS or math.min(HAND_BACK_GAP * hand_backs, HAND_BACK_MAX)
end

--- Drop a burst whose leased widget the game destroyed (a level load replaces
--- the instance): there is nothing left to release.
--- @return boolean whether the burst was dropped.
local function lease_lost()
  if lease or state ~= STATE_OPEN then
    return false
  end
  log.info("fanfare widget replaced under the burst — burst dropped")
  drop()
  return true
end

--- Release the burst's frozen widget, then drop the burst. Async thread only:
--- the release runs as a job.
--- @param reason string WARN line naming the failure.
local function abandon(reason)
  request_release("banner abandon release")
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

--- Close the burst: release the widget its lease holds, never a freshly-found
--- instance, and park it. Called from the async tick, so the release is a job.
local function close_window()
  if not lease then
    log.warn("burst closed with no leased fanfare — nothing to release")
    drop()
    return
  end
  log.debug("burst closed after " .. written .. " line(s)")
  hand_backs = 0
  request_release("banner close")
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
      lease = { w = w, state = "frozen", stage = "resume", attempts = 0, due = ticks }
      state, opening = STATE_OPEN, 0
    end)
  end)
  return true
end

--- Count a missed widget lookup and abandon the burst once the debounce
--- (MISS_LIMIT consecutive misses) is spent.
local function count_miss()
  misses = misses + 1
  if misses < MISS_LIMIT then
    return
  end
  abandon("fanfare widget went missing " .. MISS_LIMIT .. " polls running — burst dropped")
end

--- Close the burst at its budget, returning the lines that did not land so the
--- next window carries them.
local function budget_close()
  local left = #batch - batch_i
  if left > 0 then
    log.info("burst closed at the budget, " .. left .. " line(s) left")
    return_lines(batch_i + 1)
  end
  close_window()
end

--- Hold the window and pace the lines. Called once per poll tick while open.
local function step()
  local w = leased_widget()
  if not w then
    return -- the lease is gone: the next tick drops the burst
  end
  if U.prop(w, "State") ~= 1 then
    -- The widget's own chain closed the window (a game message finished, or any
    -- other reason): pacing into a closed widget is invisible, and write_line
    -- still "confirms" because `message text` outlives the window.
    hand_back("fanfare closed under the burst — dropped")
    return
  end
  if not get_widget() then
    count_miss()
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
    -- ownership test so a borrowed window cannot hold past the budget.
    budget_close()
    return
  end
  -- `message text` has exactly one writer besides us: the widget's own show next
  -- message, which also plays the Intro from 0 and cancels our pause. So a
  -- mismatch means the window is already the game's — re-asserting would clobber
  -- a legitimate message and only delay the requeue, so hand it back at once.
  if current and U.fstr(w, "message text") ~= current.text then
    hand_back("game fanfare took the window — burst yielded")
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

--- Leave a fanfare the module holds no lease on alone: it is the game's own
--- chain (connect-time counter redraws can hold `State == 1` for a long time).
--- Counts the in-play polls it has shown and WARNs once when it outlasts the
--- budget, then stays quiet.
local function idle_guard()
  if lease then
    return -- our own release is unconfirmed: its retry owns the window
  end
  local w = get_widget()
  if not w or U.prop(w, "State") ~= 1 then
    idle_open = 0
    return
  end
  idle_open = idle_open + 1
  if idle_open >= IDLE_OPEN_TICKS and not idle_warned then
    idle_warned = true
    log.warn(
      "fanfare held "
        .. tostring(math.floor(idle_open * TICK_S))
        .. "s with no lease — leaving the game's own window alone"
    )
  end
end

--- Re-assert the line on the first in-play tick after a not-in-play window: the
--- game repaints its canned text while it cannot animate, and pacing resumes
--- where that window left the burst. Writes only into the leased widget.
local function resume_burst()
  if not not_in_play_seen then
    return
  end
  not_in_play_seen = false
  if state ~= STATE_OPEN or not current or not jobs.ready() then
    return
  end
  local w = leased_widget()
  if not w then
    return
  end
  jobs.submit(function()
    write_line(w, current, false)
  end, { desc = "banner resume re-assert", fail = "banner resume re-assert failed" })
end

--- Verify a submitted release on a later in-play tick: clear the lease once the
--- window reads closed, promote a resume that did not close it to the legacy
--- fallback (once), and relinquish it with one WARN when the fallback failed too.
local function verify_release()
  if not lease then
    return
  end
  if not leased_widget() then
    log.debug("release confirmed: the fanfare widget is gone")
    lease = nil
    return
  end
  if lease.state ~= "releasing" or ticks < lease.due then
    return
  end
  if U.prop(lease.w, "State") ~= 1 then
    log.debug("release confirmed after " .. lease.attempts .. " attempt(s)")
    lease = nil
    return
  end
  if lease.stage ~= "fallback" then
    if jobs.ready() then
      lease.stage = "fallback"
      request_release("banner release fallback")
    end
    return
  end
  log.warn("fanfare release relinquished after " .. lease.attempts .. " attempt(s)")
  lease = nil
end

--- Count the opening frame down and give up on a burst whose timers never
--- landed, returning its lines.
local function opening_tick()
  opening = opening + 1
  if opening <= OPENING_TICKS then
    return
  end
  if batch_i >= 1 then
    return_lines(math.min(batch_i + 1, written + 1))
  end
  abandon("burst never opened (freeze timer lost)")
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
  if not_in_play or state ~= STATE_IDLE then
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

--- Wire up logging and the state directory the watermark lives in.
--- @param opts table|nil {log, dir}
function M.init(opts)
  log = logger.leveled(TAG, opts and opts.log)
  dir = (opts and opts.dir) or dir
end

--- Write the watermark into the shared state file. Durability points are the
--- end of a first-boot prime, every ITEM_FLUSH_EVERY new items (so a session
--- that ends without a menu return loses at most that many, not the whole run),
--- menu return (M.reset) and a socket drop.
local function save_seen()
  if shown_upto < 0 then
    return
  end
  S.set("seen_upto", shown_upto)
  S.flush()
  flushed_upto = shown_upto
end

--- Take this seed+slot's stored watermark. A stored value means the connect
--- backlog was already accounted for on an earlier session, so only the tail —
--- items AP delivered while the game was closed — is news; no value means this
--- is the first boot there and the whole sync is history. AP may deliver that
--- sync in several ItemsReceived messages, so the first boot waits
--- PRIME_QUIET_TICKS of quiet rather than one batch.
--- @param sd table|nil Slot data carrying seed and slot.
function M.configure(sd)
  S.open(sd, dir)
  local seen = S.get("seen_upto", nil)
  priming = seen == nil
  shown_upto = seen or -1
  flushed_upto = shown_upto
  prime_quiet, primed, backlog = 0, 0, 0
end

--- Clear the per-session queues and counters; a burst in flight releases its
--- frozen widget before it stops, and the lease keeps its release verified. The
--- watermark is written first: the menu return is one of its durability points.
function M.reset()
  save_seen()
  if lease and lease.state ~= "releasing" then
    request_release("banner reset release") -- an outstanding release is verified, not resubmitted
  end
  Q = { system = {}, item = {}, sent = {} }
  counters = { queued = 0, shown = 0, failed = 0, sent_queued = 0, sent_shown = 0 }
  backlog, shown_upto, priming, prime_quiet, primed = 0, -1, false, 0, 0
  flushed_upto = -1
  state, batch, batch_i, current = STATE_IDLE, {}, 0, nil
  written, burst_ticks, dwell, opening, wait_ticks = 0, 0, 0, 0, 0
  misses, idle_open, idle_warned, not_in_play_seen, not_in_play = 0, 0, false, false, false
  hand_backs = 0
  gen = gen + 1
end

--- Drive the burst, called by the host poll loop with the game snapshot.
--- @param world table|nil game_state snapshot; nil reads as in play.
function M.tick(world)
  if world ~= nil and world.not_in_play == true then
    not_in_play, not_in_play_seen = true, true
    return -- the game is not in play and animates nothing: no ticks, writes or release attempts
  end
  not_in_play = false
  ticks = ticks + 1
  if priming then
    prime_quiet = prime_quiet + 1
    if prime_quiet >= PRIME_QUIET_TICKS then
      priming = false
      log.info("connect backlog: " .. primed .. " item(s) treated as history")
      save_seen()
    end
  end
  verify_release()
  if lease_lost() then
    return
  end
  resume_burst()
  if state == STATE_IDLE then
    idle_guard()
    start()
  elseif state == STATE_OPENING then
    opening_tick()
  elseif state == STATE_OPEN then
    step()
  end
end

--- Queue a received item to show, unless the watermark already accounted for it.
--- While priming, an indexed item only advances the watermark and restarts the
--- quiet window; nothing is shown. Otherwise the stored watermark is what makes
--- the replay quiet and lets the offline tail (indexes past it) announce.
--- @param name string Item name.
--- @param index number|nil AP item index; nil (no slot data) skips the watermark.
function M.note_item(name, index)
  if type(name) ~= "string" or name == "" then
    return
  end
  if index ~= nil then
    if priming then
      if index > shown_upto then
        shown_upto = index
      end
      prime_quiet, primed = 0, primed + 1
      return
    end
    if index <= shown_upto then
      backlog = backlog + 1
      return
    end
    shown_upto = index
    if shown_upto - flushed_upto >= ITEM_FLUSH_EVERY then
      save_seen() -- bound what a session that never reaches the menu replays
    end
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
  save_seen() -- the host stops ticking now: the outage is a durability point
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
  local lstate, attempts = "none", 0
  if lease then
    lstate, attempts = lease.state, lease.attempts
  end
  return string.format(
    "state=%s queued=%d backlog=%d priming=%s shown=%d failed=%d waiting=%d left=%d sent=%d sent_queued=%d sent_waiting=%d misses=%d held=%s lease=%s/%d idle_open=%d",
    state,
    counters.queued,
    backlog,
    priming and "y" or "n",
    counters.shown,
    counters.failed,
    queue_len(),
    math.max(0, #batch - batch_i),
    counters.sent_shown,
    counters.sent_queued,
    #Q.sent,
    misses,
    lease and "y" or "n",
    lstate,
    attempts,
    idle_open
  )
end
M.tag = TAG

return M
