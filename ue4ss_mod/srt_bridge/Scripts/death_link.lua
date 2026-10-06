-- death_link: AP DeathLink — Spyro's own deaths bounce to the other DeathLink
-- players, and an incoming bounce kills Spyro here with the full-strength
-- damage-trap lever (pawn health set HealthCurrent -> 0). Echo protection runs
-- both ways. See docs/game_state_control.md.
--
-- Pure logic: send/now/me are injected (main wires ap:Bounce,
-- ap:get_server_time, ap:get_slot); the spec runs without UE4SS.

local U = require("util")
local logger = require("logger")

local M = {}

local PAWN_CLASS = "BP_CPS1999_Playable_C"  -- Spyro's player pawn blueprint
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
    log = logger.leveled("[DEATHLINK]", opts and opts.log)
    send = (opts and opts.send) or send
    now = (opts and opts.now) or now
    me = (opts and opts.me) or me
    can_write = type(ExecuteInGameThread) == "function"
end

--- Read the death_link option from slot data and reset per-session state.
function M.configure(sd)
    enabled = type(sd) == "table" and type(sd.options) == "table"
        and sd.options.death_link == 1
    dead, suppress, pending_kill = false, false, false
    last_death_time = nil
    log.info("configured: enabled=" .. tostring(enabled))
end

--- Queue a kill for a DeathLink-tagged bounce unless it is our own echo or
--- older than our last bounce.
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

--- Poll the pawn: apply a pending kill, then bounce a fresh player death
--- (unless it is our own suppressed induced death).
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

--- Return a one-line heartbeat summary of the module's state.
function M.status()
    return string.format("enabled=%s dead=%s pending=%s suppressed=%s",
        tostring(enabled), tostring(dead), tostring(pending_kill), tostring(suppress))
end

return M