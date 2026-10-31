-- Author: Tim Harrison
-- Created: 2026-10-05
-- Updated: 2026-10-23

-- level_tracker: bounces the slot's current level (region) to the player's own
-- connections so the PopTracker pack can follow level-to-level. Read-only on
-- the snapshot; a failed send is retried on the next tick. send is injected
-- (main wires ap:Bounce).
-- API (main.lua): init{log, send}, configure(slot_data), tick(world), status().

local logger = require("logger")

local M = {}

local TAG = "[LEVELTAB]"

local log = logger.tagged(TAG)
local send = function() return false end
local cur_region = nil  -- last region successfully announced
local armed = false     -- false until the first configure (idle in menus)

--- Record region as the last successfully announced one.
local function set_cur(region)
    cur_region = region
end

--- Disarm tracking and forget the last announced region.
local function reset()
    armed = false
    set_cur(nil)
    log.debug("reset")
end

-- ---------------------------------------------------------------------------
-- API
-- ---------------------------------------------------------------------------
--- Install the injected logger and sender; then reset.
function M.init(opts)
    log = logger.leveled(TAG, opts and opts.log)
    send = (opts and opts.send) or send
    reset()
end

--- Arm tracking on slot connect, or reset on session close.
function M.configure(sd)
    if sd == nil then
        reset() -- main's reset_session_state passes {} — stays armed there
        return
    end
    reset()
    armed = true
end

--- Bounce the current level's region when it changes.
--- @param world table game_state snapshot.
function M.tick(world)
    if not armed then return end
    local region = world.region
    if not region or region == cur_region then return end
    local ok, r = pcall(send, region)
    if ok and r == true then
        set_cur(region)
        log.info("level -> " .. region)
    else
        log.debug("bounce failed (" .. tostring(r) .. "); retry next tick")
    end
end

--- Return the last announced region for the heartbeat.
function M.status()
    return "region=" .. tostring(cur_region)
end
M.tag = TAG

return M