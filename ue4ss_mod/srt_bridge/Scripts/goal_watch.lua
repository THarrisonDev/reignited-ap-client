-- Author: Tim Harrison
-- Created: 2026-09-26
-- Updated: 2026-10-23

-- goal_watch: reports GOAL once every required game's goal_location event has
-- been received. Detection is id-based and self-healing (ReceivedItems
-- re-delivers the full backlog on reconnect); a required game exposing no
-- goal_location keeps client goal reporting off.
-- Pure logic: send() (StatusUpdate) and log are injected.

local logger = require("logger")
local O = require("option")

local M = {}

local TAG = "[GOAL]"

local log = logger.tagged(TAG)
local send = function() return false end
local pending = {}   -- goal location id -> true (not yet received)
local goals = {}     -- required game key -> goal location id
local sent = false

--- Return whether v is a usable goal location id.
local function usable_id(v)
    return type(v) == "number" and v > 0
end

--- Install the injected logger and goal sender.
function M.init(opts)
    log = logger.leveled(TAG, opts and opts.log)
    send = (opts and opts.send) or send
end

--- Return the required games whose slot data carries a usable goal location.
local function read_goals(sd)
    local out = {}
    local required = type(sd) == "table" and type(sd.required_games) == "table"
        and sd.required_games or {}
    for _, key in ipairs(required) do
        local gid = O.game_data(sd, key).goal_location
        if usable_id(gid) then
            out[key] = gid
        end
    end
    return out
end

--- Log what goal reporting is waiting for, or why it stays off.
local function log_goals(sd, found)
    if next(found) == nil then
        local required = type(sd) == "table" and type(sd.required_games) == "table"
            and sd.required_games or {}
        if #required > 0 then
            log.info("goal tracking: no required game exposes a goal_location; goal reporting stays off")
        end
        return
    end
    local names = {}
    for key, gid in pairs(found) do
        names[#names + 1] = key .. "@" .. gid
    end
    table.sort(names)
    log.info("goal tracking: waiting for " .. table.concat(names, ", "))
end

--- Build the pending-goal set from slot data's required games.
function M.configure(sd)
    pending, goals = {}, read_goals(sd)
    sent = false
    for _, gid in pairs(goals) do
        pending[gid] = true
    end
    log_goals(sd, goals)
end

--- Drop the pending goals this batch delivered.
local function clear_received(received)
    local got = {}
    for _, info in ipairs(received or {}) do
        got[info.location] = true
    end
    for gid in pairs(pending) do
        if got[gid] then
            pending[gid] = nil
            log.info("goal event received: location " .. gid)
        end
    end
end

--- Report GOAL when every required game is complete; returns whether it did.
local function report()
    if sent or next(pending) ~= nil or next(goals) == nil then return false end
    local ok, err = pcall(send)
    -- pcall's first result is "did not throw"; send() itself reports success
    if ok and err == false then
        ok, err = false, "StatusUpdate returned false"
    end
    sent = ok
    log.info("all required games complete: reported goal")
    if not ok then
        log.error("StatusUpdate failed (retrying on the next batch): " .. tostring(err))
    end
    return ok
end

--- Clear goal locations seen in received, then report GOAL when all are in.
function M.note_batch(received)
    clear_received(received)
    return report()
end

--- Return a one-line sent/waiting state for debugging.
function M.status()
    local waiting = {}
    for gid in pairs(pending) do waiting[#waiting+1] = tostring(gid) end
    table.sort(waiting)
    return string.format("sent=%s waiting=%s", tostring(sent),
        #waiting > 0 and table.concat(waiting, ",") or "none")
end

--- Return whether GOAL has been reported.
function M.sent() return sent end
M.tag = TAG

return M