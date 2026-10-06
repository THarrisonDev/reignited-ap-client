-- level_tracker: bounces the slot's current level (region) to the player's own
-- connections so the PopTracker pack can follow level-to-level. Read-only on
-- the gamestate; a failed send is retried on the next tick. send and regions
-- are injected (main wires ap:Bounce and the generated regions.lua).
-- API (main.lua): init{log, send, regions}, configure(slot_data),
-- tick(gamestate), status().

local U = require("util")
local logger = require("logger")

local M = {}

local log = logger.tagged("[LEVELTAB]")
local send = function() return false end
local regions = {}      -- level path -> region name
local cur_region = nil  -- last region successfully announced
local armed = false     -- false until the first configure (idle in menus)

local safe = U.safe

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
--- Install the injected logger, sender and region table; then reset.
function M.init(opts)
    log = logger.leveled("[LEVELTAB]", opts and opts.log)
    send = (opts and opts.send) or send
    regions = (opts and opts.regions) or regions
    reset()
end

--- Arm tracking on slot connect, or reset on session close.
function M.configure(_sd)
    if _sd == nil then
        reset() -- main's reset_session_state passes {} — stays armed there
        return
    end
    reset()
    armed = true
end

--- Bounce the current level's region when it changes.
function M.tick(gs)
    if not armed then return end
    local path = safe(function() return gs["current level"]:ToString() end, nil)
    if not path or path == "" then return end
    local region = regions[path]
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

return M