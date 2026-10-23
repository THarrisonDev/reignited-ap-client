-- Author: Tim Harrison
-- Created: 2026-09-26
-- Updated: 2026-10-11

-- session_gate: opens the AP session only while the game is in play with a
-- readable, supported save slot, and closes it at the main menu. A missing
-- required file (M.block) stops it opening at all: a session that cannot
-- resolve its regions would silently send a fraction of the checks.
-- Pure logic: the caller passes the gamestate value and a slot reader.

local logger = require("logger")

local M = {}

-- EFalconGameState values, as the game's own enum defines them
M.MAIN_MENU = 0
M.IN_PLAY = 3
M.SPYRO1 = 0           -- game indices in the trilogy menu / save
M.SPYRO2 = 1
M.SPYRO3 = 2
M.STABLE_TICKS = 2     -- consecutive InPlay ticks before reading the slot

-- game index -> apworld game key / player-facing name
local KEYS = {[0] = "spyro1", [1] = "spyro2", [2] = "spyro3"}
local NAMES = {[0] = "Spyro the Dragon", [1] = "Spyro 2", [2] = "Spyro 3"}
local SUPPORTED = {[0] = true, [1] = true, [2] = true}

--- Return the apworld game key for a game index, or nil.
function M.game_key(g) return KEYS[g] end
--- Return the player-facing game name for a game index.
function M.game_name(g) return NAMES[g] or ("game " .. tostring(g)) end

--- Return whether game index g is in the seed. Old seeds carry no
--- included_games and are Spyro 1 only.
function M.is_included(slot_data, g)
    local key = KEYS[g]
    if key == nil then return false end
    local list = type(slot_data) == "table" and slot_data.included_games
    if type(list) ~= "table" then return key == "spyro1" end
    for _, k in ipairs(list) do
        if k == key then return true end
    end
    return false
end

local log = logger.tagged("[SESSION]")
local open = false
local slot, game = nil, nil
local play_ticks = 0
local warned = nil     -- last refusal logged this menu cycle (log once)
local blocked = nil    -- reason the gate refuses to open at all, or nil

--- Reset the per-menu-cycle tick and warn-once state.
local function reset_cycle()
    play_ticks = 0
    warned = nil
end

--- Install the injected logger and close the gate.
function M.init(opts)
    log = logger.leveled("[SESSION]", opts and opts.log)
    open, slot, game = false, nil, nil
    blocked = nil
    reset_cycle()
end

--- Refuse to open a session from now on, with a one-line reason. Used when a
--- required generated file failed to load; the reason is logged once (the
--- warn-once flag never resets, so a permanently broken install stays quiet).
function M.block(reason)
    blocked = reason
end

--- Return whether the gate is blocked.
function M.is_blocked() return blocked ~= nil end

--- Return the block reason, or nil when the gate is not blocked.
function M.block_reason() return blocked end

--- Warn under key at most once per menu cycle.
local function warn_once(key, line)
    if warned == key then return end
    warned = key
    log.warn(line)
end

--- Close an open session on the main menu; returns "close" or nil.
local function menu_tick()
    reset_cycle()
    if not open then return nil end
    open, slot, game = false, nil, nil
    return "close"
end

--- Return the active (slot, game) when both are usable, or nil after warning.
local function read_open(read_slot)
    local s, g = read_slot()
    if type(s) ~= "number" or type(g) ~= "number" or s < 0 or g < 0 then
        warn_once("unreadable", "in play but the active save slot is unreadable; staying offline")
        return nil
    end
    if not SUPPORTED[g] then
        warn_once("game" .. g, string.format(
            "save slot %d is playing %s, which isn't supported yet; staying offline",
            s, M.game_name(g)))
        return nil
    end
    return s, g
end

--- Advance the gate from the gamestate; return "open", slot, game, "close",
--- or nil. read_slot returns the active (slot, game) indices or nil.
function M.tick(state, read_slot)
    if type(state) ~= "number" then return nil end
    if blocked then
        warn_once("blocked", blocked)
        return nil
    end
    if state == M.MAIN_MENU then return menu_tick() end
    if open then return nil end
    if state ~= M.IN_PLAY then
        play_ticks = 0
        return nil
    end
    play_ticks = play_ticks + 1
    if play_ticks < M.STABLE_TICKS then return nil end
    local s, g = read_open(read_slot)
    if s == nil then return nil end
    open, slot, game = true, s, g
    return "open", s, g
end

--- Return whether the gate is open.
function M.is_open() return open end

--- Return a one-line gate state for the heartbeat.
function M.status()
    if open then return string.format("open(slot=%d game=%d)", slot, game) end
    return "waiting for save selection"
end

return M
