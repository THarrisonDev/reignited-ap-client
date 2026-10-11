-- Author: Tim Harrison
-- Created: 2026-09-26
-- Updated: 2026-10-11

-- goal_watch: reports GOAL once every required game's goal_location event has
-- been received. Detection is id-based and self-healing (ReceivedItems
-- re-delivers the full backlog on reconnect); a required game exposing no
-- goal_location keeps client goal reporting off.
-- Pure logic: send() (StatusUpdate) and log are injected.

local logger = require("logger")

local M = {}

local log = logger.tagged("[GOAL]")
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
    log = logger.leveled("[GOAL]", opts and opts.log)
    send = (opts and opts.send) or send
end

--- Build the pending-goal set from slot data's required games.
function M.configure(sd)
    pending, goals = {}, {}
    sent = false
    local required = type(sd) == "table" and type(sd.required_games) == "table"
        and sd.required_games or {}
    for _, key in ipairs(required) do
        local g = type(sd.games) == "table" and sd.games[key] or nil
        local gid = type(g) == "table" and g.goal_location or nil
        if usable_id(gid) then
            goals[key] = gid
            pending[gid] = true
        end
    end
    if #required > 0 and next(pending) == nil then
        log.info("goal tracking: no required game exposes a goal_location; goal reporting stays off")
    elseif next(pending) ~= nil then
        local names = {}
        for key, gid in pairs(goals) do
            names[#names+1] = key .. "@" .. gid
        end
        table.sort(names)
        log.info("goal tracking: waiting for " .. table.concat(names, ", "))
    end
end

--- Clear goal locations seen in received, then report GOAL when all are in.
function M.note_batch(received)
    for gid in pairs(pending) do
        for _, info in ipairs(received or {}) do
            if info.location == gid then
                pending[gid] = nil
                log.info("goal event received: location " .. gid)
                break
            end
        end
    end
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

return M