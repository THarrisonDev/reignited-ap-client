-- goal_watch: client-side goal reporting. Slot data lists the required games
-- and each game's goal_location (the id of its completion event location —
-- "Spyro 1: Gnasty Gnorc Defeated", "Spyro 2: Ripto's Arena: Ripto Defeated").
-- When the event item for every required goal location has been received,
-- the client reports GOAL once (APClient.ClientStatus.GOAL).
--
-- Detection is id-based and self-healing: ReceivedItems re-delivers the full
-- backlog on every reconnect, so a drop or restart never misses the goal.
-- All_DRAGONS-style goals expose goal_location = 0 (no single verifiable
-- event); a required game without one keeps goal reporting off with a debug
-- note — the server-side generation is still correct, only the client report
-- is silent.
--
-- Pure logic: the caller wires send() (StatusUpdate) and log (leveled,
-- tagged [GOAL] — the ERROR line reaches the console); the spec runs without
-- UE4SS.
--
-- API (main.lua): configure(slot_data) on slot connect, note_batch(received)
-- per ReceivedItems packet, status() for debugging, sent() for tests.

local logger = require("logger")

local M = {}

local log = logger.tagged("[GOAL]")
local send = function() return false end
local pending = {}   -- goal location id -> true (not yet received)
local goals = {}     -- required game key -> goal location id
local sent = false

local function usable_id(v)
    return type(v) == "number" and v > 0
end

function M.init(opts)
    log = logger.leveled("[GOAL]", opts and opts.log)
    send = (opts and opts.send) or send
end

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

function M.status()
    local waiting = {}
    for gid in pairs(pending) do waiting[#waiting+1] = tostring(gid) end
    table.sort(waiting)
    return string.format("sent=%s waiting=%s", tostring(sent),
        #waiting > 0 and table.concat(waiting, ",") or "none")
end

function M.sent() return sent end

return M