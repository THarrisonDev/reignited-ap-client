-- Author: Tim Harrison
-- Created: 2026-09-26
-- Updated: 2026-10-23

-- death_link: AP DeathLink — Spyro's own deaths bounce to the other DeathLink
-- players, and an incoming bounce kills Spyro here with the full-strength
-- damage-trap lever (pawn health set HealthCurrent -> 0). Echo protection runs
-- both ways.
--
-- Pure logic: send/now/me are injected (main wires ap:Bounce,
-- ap:get_server_time, ap:get_slot); the spec runs without UE4SS.

local U = require("util")
local logger = require("logger")
local O = require("option")

local M = {}

local PAWN_CLASS = "BP_CPS1999_Playable_C"  -- Spyro's player pawn blueprint
local JOB_TIMEOUT = 5       -- seconds before an unfinished job is abandoned (and failed-job backoff)

local TAG = "[DEATHLINK]"

local log = logger.tagged(TAG)
local send = function() return false end
local now = function() return 0 end
local me = function() return "?" end
local enabled = false       -- slot_data.options.death_link (option.flag decodes it)
local dead = false          -- last observed pawn IsDead
local suppress = false      -- our induced kill is in flight: its death must not bounce
local last_death_time = nil -- our last bounce's time (echo protection)
local pending_kill = false  -- an incoming death to apply
local can_write = false     -- ExecuteInGameThread available
local jobs = U.job_runner{log = function() return log end, timeout = JOB_TIMEOUT}

local safe = U.safe
local valid = U.valid
local num = U.prop

-- ---------------------------------------------------------------------------
-- game-thread work (only ever called from inside a job)
-- ---------------------------------------------------------------------------
--- Write pawn's health to 0, marking the induced death as suppressed; a
--- readback that does not stick drops the kill and clears the suppression.
local function run_kill(pawn)
    if not valid(pawn) then return end
    local set = U.find_health_set(pawn)
    if not set then
        log.warn("kill: health attribute set not found (incoming death dropped)")
        return
    end
    suppress = true
    set["HealthCurrent"] = 0
    local back = num(set, "HealthCurrent")
    if back == 0 then
        log.info("kill applied (HealthCurrent -> 0)")
    else
        suppress = false
        log.warn("kill: write did not stick (readback " ..
            tostring(back) .. ") — incoming death dropped")
    end
end

--- Submit a kill job for pawn; a thrown job starts the runner's backoff.
local function submit(pawn)
    jobs.submit(function() run_kill(pawn) end, {fail = "kill failed"})
end

-- ---------------------------------------------------------------------------
-- API
-- ---------------------------------------------------------------------------
--- Wire the injected logger and send/now/me callables, and detect the
--- game-thread write API.
function M.init(opts)
    log = logger.leveled(TAG, opts and opts.log)
    send = (opts and opts.send) or send
    now = (opts and opts.now) or now
    me = (opts and opts.me) or me
    can_write = U.can_write()
end

--- Read the death_link option from slot data and reset per-session state.
function M.configure(sd)
    enabled = type(sd) == "table" and type(sd.options) == "table"
        and O.flag(sd.options.death_link, "death_link", log)
    dead, suppress, pending_kill = false, false, false
    last_death_time = nil
    log.info("configured: enabled=" .. tostring(enabled))
end

--- Return whether the bounce carries the DeathLink tag.
local function death_tagged(cmd)
    for _, t in ipairs(cmd.tags) do
        if t == "DeathLink" then return true end
    end
    return false
end

--- Return whether the bounce is our own echo or older than our last bounce.
local function stale_bounce(data)
    if data.source == me() then
        log.debug("ignoring own bounce (echo)")
        return true
    end
    if type(data.time) == "number" and last_death_time ~= nil
        and data.time <= last_death_time then
        log.debug("ignoring stale bounce (time " .. tostring(data.time) .. ")")
        return true
    end
    return false
end

--- Queue a kill for a DeathLink-tagged bounce unless it is our own echo or
--- older than our last bounce.
function M.on_bounced(cmd)
    if not enabled then return end
    if type(cmd) ~= "table" or type(cmd.data) ~= "table" or type(cmd.tags) ~= "table" then
        return
    end
    if not death_tagged(cmd) or stale_bounce(cmd.data) then return end
    pending_kill = true
    log.info("death from " .. tostring(cmd.data.source or "?") .. " — kill pending")
end

--- Apply a pending kill when the pawn is alive and the runner is free.
local function apply_pending(pawn, is_dead)
    if not (pending_kill and not is_dead and can_write and jobs.ready()) then return end
    pending_kill = false
    submit(pawn)
end

--- Bounce a fresh player death unless it is our own induced one.
local function bounce_death()
    if suppress then
        suppress = false
        log.debug("induced death suppressed (not bounced)")
        return
    end
    if not enabled then return end
    local t = now()
    local okS, r = pcall(send, {time = t, source = me(), cause = "death"})
    if okS and r == true then
        last_death_time = t
        log.info(string.format("death bounced (time %.2f)", t))
        return
    end
    log.warn("bounce send failed (" .. tostring(r) .. "); not retried on this death")
end

--- Poll the pawn: apply a pending kill, then bounce a fresh player death
--- (unless it is our own suppressed induced death).
function M.tick()
    local pawn = safe(function() return FindFirstOf(PAWN_CLASS) end, nil)
    if not valid(pawn) then return end
    local is_dead = safe(function() return pawn:IsDead() end, nil)
    if is_dead == nil then is_dead = false end
    apply_pending(pawn, is_dead)
    if not dead and is_dead then
        bounce_death()
    end
    dead = is_dead
end

--- Return a one-line heartbeat summary of the module's state.
function M.status()
    return string.format("enabled=%s dead=%s pending=%s suppressed=%s",
        tostring(enabled), tostring(dead), tostring(pending_kill), tostring(suppress))
end
M.tag = TAG

return M