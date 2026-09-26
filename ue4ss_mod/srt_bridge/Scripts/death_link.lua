-- death_link: AP DeathLink. When the slot's death_link option is on, Spyro's
-- own deaths bounce to the other DeathLink players, and an incoming DeathLink
-- bounce kills Spyro here.
--
-- The kill is the damage-trap lever at full strength: the pawn's GAS health
-- attribute set (U.find_health_set -> HealthCurrent) written to 0 — the game
-- kills Spyro itself at 0 (docs/game_state_control.md). Echo protection works
-- both ways: a bounce whose source is our own slot (or whose time is not newer
-- than our last bounce) is ignored, and the death our induced kill causes is
-- suppressed so it never bounces back out. A kill whose write does not stick
-- is dropped (WARN), never retried — a missed death link is acceptable, a
-- kill loop is not.
--
-- THREADING (fillers lesson): the async tick only reads and decides; all
-- writes run inside ONE ExecuteInGameThread job at a time (U.job_runner).
-- A thrown kill job backs the runner off; the kill itself is never requeued
-- (pending_kill is cleared at submit).
--
-- Pure logic: send/now/me are injected (main wires ap:Bounce,
-- ap:get_server_time, ap:get_slot); the spec runs without UE4SS.
--
-- API (main.lua): init{log, send, now, me}, configure(slot_data) on slot
-- connect, on_bounced(cmd) for every Bounced packet, tick(gamestate) from
-- the poll loop, status() for the heartbeat. log is a leveled logger (tagged
-- [DEATHLINK]) or the spec's collector function; the kill/bounce records
-- (info) and all warnings reach the console.

local U = require("util")
local logger = require("logger")

local M = {}

local PAWN_CLASS = "BP_CPS1999_Playable_C"
local JOB_TIMEOUT = 5       -- seconds before an unfinished job is abandoned (and failed-job backoff)

local log = logger.tagged("[DEATHLINK]")
local send = function() return false end
local now = function() return 0 end
local me = function() return "?" end
local enabled = false       -- slot_data.options.death_link == 1
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

local function submit(pawn)
    jobs.submit(function() run_kill(pawn) end, {fail = "kill failed"})
end

-- ---------------------------------------------------------------------------
-- API
-- ---------------------------------------------------------------------------
function M.init(opts)
    log = logger.leveled("[DEATHLINK]", opts and opts.log)
    send = (opts and opts.send) or send
    now = (opts and opts.now) or now
    me = (opts and opts.me) or me
    can_write = type(ExecuteInGameThread) == "function"
end

function M.configure(sd)
    enabled = type(sd) == "table" and type(sd.options) == "table"
        and sd.options.death_link == 1
    dead, suppress, pending_kill = false, false, false
    last_death_time = nil
    log.info("configured: enabled=" .. tostring(enabled))
end

function M.on_bounced(cmd)
    if not enabled then return end
    if type(cmd) ~= "table" or type(cmd.data) ~= "table" or type(cmd.tags) ~= "table" then
        return
    end
    local tagged = false
    for _, t in ipairs(cmd.tags) do
        if t == "DeathLink" then tagged = true break end
    end
    if not tagged then return end
    local data = cmd.data
    if data.source == me() then
        log.debug("ignoring own bounce (echo)")
        return
    end
    if type(data.time) == "number" and last_death_time ~= nil
        and data.time <= last_death_time then
        log.debug("ignoring stale bounce (time " .. tostring(data.time) .. ")")
        return
    end
    pending_kill = true
    log.info("death from " .. tostring(data.source or "?") .. " — kill pending")
end

function M.tick(gs)
    local pawn = safe(function() return FindFirstOf(PAWN_CLASS) end, nil)
    if not valid(pawn) then return end
    local is_dead = safe(function() return pawn:IsDead() end, nil)
    if is_dead == nil then is_dead = false end

    if pending_kill and not is_dead and can_write and jobs.ready() then
        pending_kill = false
        submit(pawn)
    end

    if not dead and is_dead then
        if suppress then
            suppress = false
            log.debug("induced death suppressed (not bounced)")
        elseif enabled then
            local t = now()
            local okS, r = pcall(send, {time = t, source = me(), cause = "death"})
            if okS and r == true then
                last_death_time = t
                log.info(string.format("death bounced (time %.2f)", t))
            else
                log.warn("bounce send failed (" .. tostring(r) ..
                    "); not retried on this death")
            end
        end
    end
    dead = is_dead
end

function M.status()
    return string.format("enabled=%s dead=%s pending=%s suppressed=%s",
        tostring(enabled), tostring(dead), tostring(pending_kill), tostring(suppress))
end

return M