-- fillers: apply received filler items.
--
-- Extra Life goes through the gamestate's own inventory UFunction:
-- add item to player inventory(EIT_Life=18, n) -> update param count (capped
-- at 99 by the game, HUD notified; docs/game_state_control.md §9.1).
-- Looks (colors, Big Head, Flat Spyro) drive the Spyro pawn's own cheat-code
-- handlers (ICheatCodes interface on BP_CPS1999_Playable_C).
-- The Damage Trap subtracts one hit from the pawn's GAS health attribute
-- (UPhasmidHealthSystemAttributeSet.HealthCurrent on AbilitySystem; Sparx
-- tiers are whole units, so -1 = one hit like an enemy catch). There is no
-- "hurt Spyro" UFunction in the SDK dump — the reflected attribute write is
-- the only lever (docs/game_state_control.md).
--
-- Exactly once: AP resends every item on each connect, so Extra Life items are
-- counted by item index and the granted total persists per seed+slot. Looks
-- are session state: the backlog rebuilds them, and they are re-applied to
-- every new pawn (level loads spawn a fresh one).
--
-- Colors follow the game's own color cheat (docs/kismet/BP_CPS1999_Playable.txt):
-- the gamestate's global float "code.color" holds a CheatTints index (0 = no
-- tint), and ICheatCodeSetSpyroTintColor() reads it to tint the body material
-- (CheckCheatTint re-applies it to new pawns). ICheatCodeSetSpyroSkin is NOT a
-- color: it swaps the mesh (1 = retro Spyro, 2 = sunglasses) and clears
-- code.color.
--
-- THREADING (level_locks lesson): the async tick only reads and decides; all
-- writes run inside ONE ExecuteInGameThread job at a time (U.job_runner:
-- abandoned after JOB_TIMEOUT, JOB_TIMEOUT of backoff after a failed job).
--
-- API (main.lua): init{log, regions, dir}, configure(slot_data) on slot connect,
-- note_item(name, index) per received item, tick(gamestate) from the poll
-- loop, status() for the heartbeat. log is a leveled logger (logger.tagged,
-- [FILLERS]) or the spec's collector function; warn/error reach the console.

local U = require("util")
local logger = require("logger")

local M = {}

local PAWN_CLASS = "BP_CPS1999_Playable_C"
local EIT_LIFE = 18
local STABLE_TICKS = 8      -- x 250ms poll: never write until the level has held 2s
local JOB_TIMEOUT = 5       -- seconds before an unfinished job is abandoned (and failed-job backoff)

local COLORS = {
    ["Turn Spyro Red"] = {1, 0, 0},
    ["Turn Spyro Blue"] = {0, 0, 1},
    ["Turn Spyro Pink"] = {1, 0.4, 0.7},
    ["Turn Spyro Yellow"] = {1, 1, 0},
    ["Turn Spyro Green"] = {0, 1, 0},
    ["Turn Spyro Black"] = {0, 0, 0},
}

local MODES = {
    ["Big Head Mode"] = "ICheatCodeBigHeadMode",
    ["Flat Spyro Mode"] = "ICheatCodeFlatSpyroMode",
}

local TRAP_NAME = "Damage Trap"

local log = logger.tagged("[FILLERS]")
local regions = {}          -- map path -> region (generated regions.lua)
local dir = "C:/srtap_bridge/"
local can_write = false     -- ExecuteInGameThread available
local state_file = nil
local life_indices = {}     -- AP item index -> true (Extra Life, this session)
local trap_indices = {}     -- AP item index -> true (Damage Trap, this session)
local lives_received = 0
local lives_granted = 0     -- persisted per seed+slot
local look = {color = nil, modes = {}}
local look_serial = 0       -- bumps on every look change
local applied = {pawn = nil, serial = 0}
local traps_received = 0    -- damage traps: session count (no persistence —
                            -- an unlucky reconnect could re-hit, which is fine for a trap)
local cur_path, stable_ticks = nil, 0
local jobs = U.job_runner{log = function() return log end, timeout = JOB_TIMEOUT}
local probed_pawn = nil

-- ---------------------------------------------------------------------------
-- UE4SS helpers (shared: util.lua)
-- ---------------------------------------------------------------------------
local safe = U.safe
local valid = U.valid
local num = U.prop
local actor_key = U.actor_key

-- ---------------------------------------------------------------------------
-- persistence: lives_granted=N in <dir>fillers_<seed>_<slot>.txt
-- ---------------------------------------------------------------------------
local function load_granted()
    local f = state_file and io.open(state_file, "r")
    if not f then return 0 end
    local n = tonumber((f:read("a") or ""):match("lives_granted=(%d+)"))
    f:close()
    return n or 0
end

local function save_granted()
    local f = state_file and io.open(state_file, "w")
    if not f then
        log.warn("cannot write " .. tostring(state_file) .. " (lives may re-grant next session)")
        return
    end
    f:write("lives_granted=" .. lives_granted .. "\n")
    f:close()
end

-- ---------------------------------------------------------------------------
-- cheat tints
-- ---------------------------------------------------------------------------
local function read_tints(pawn)
    local tints = {}
    local arr = safe(function() return pawn["CheatTints"] end, nil)
    if arr == nil then return tints end
    pcall(function()
        arr:ForEach(function(_, elem)
            local c = elem:get()
            tints[#tints + 1] = {num(c, "R") or 0, num(c, "G") or 0, num(c, "B") or 0}
        end)
    end)
    return tints
end

-- 0-based index of the tint nearest rgb, or nil when the table is unreadable
local function nearest(tints, rgb)
    local best, best_d
    for i, t in ipairs(tints) do
        local d = (t[1] - rgb[1]) ^ 2 + (t[2] - rgb[2]) ^ 2 + (t[3] - rgb[3]) ^ 2
        if best_d == nil or d < best_d then best, best_d = i - 1, d end
    end
    return best
end

local function probe(pawn, gs, key)
    if probed_pawn == key then return end
    probed_pawn = key
    local parts = {}
    for i, t in ipairs(read_tints(pawn)) do
        parts[#parts + 1] = string.format("%d=(%.2f,%.2f,%.2f)", i - 1, t[1], t[2], t[3])
    end
    local cheat = safe(function() return gs["enabledCheat"]:ToString() end, nil)
    log.debug("pawn " .. key .. " CheatTints: " ..
        (#parts > 0 and table.concat(parts, " ") or "unreadable") ..
        " enabledCheat=" .. tostring(cheat))
end

-- ---------------------------------------------------------------------------
-- game-thread work (only ever called from inside a job)
-- ---------------------------------------------------------------------------
-- Damage trap: find Spyro's own GAS health attribute set among every
-- PhasmidHealthSystemAttributeSet (U.find_health_set) and subtract one hit.
-- HealthCurrent is a reflected float (OnRep_'d); the game's own death/damage
-- logic reacts to it. Never drives health below 0 — at 0 the game kills Spyro
-- itself, exactly like a real hit.

local function apply_trap(pawn)
    local set = U.find_health_set(pawn)
    if not set then
        log.warn("damage trap: health attribute set not found (no effect)")
        return
    end
    local cur = num(set, "HealthCurrent")
    if cur == nil or cur < 0 or cur > 99 then
        log.warn("damage trap: HealthCurrent unreadable (" .. tostring(cur) .. "), skipped")
        return
    end
    local next = math.max(cur - 1, 0)
    set["HealthCurrent"] = next
    local back = num(set, "HealthCurrent")
    if back == next then
        log.info(string.format("damage trap: HealthCurrent %.0f -> %.0f", cur, next))
    else
        log.warn("damage trap: write did not stick (readback " ..
            tostring(back) .. ") — game may clamp/refresh health")
    end
end

local function run_job(gs, pawn, key, lives, serial, traps)
    if lives > 0 then
        gs["add item to player inventory"](EIT_LIFE, lives)
        lives_granted = lives_granted + lives
        save_granted()
        log.info(string.format("granted %d extra %s (total %d)",
            lives, lives == 1 and "life" or "lives", lives_granted))
    end
    if pawn == nil or not valid(pawn) then return end
    if look.color then
        local idx = nearest(read_tints(pawn), COLORS[look.color])
        if idx == 0 then
            log.warn(look.color .. " skipped: nearest CheatTints entry is 0 (no tint)")
        elseif idx then
            local set = gs:SetGlobalFloatValue("code.color", idx)
            pawn:ICheatCodeSetSpyroTintColor()
            log.info(look.color .. " -> code.color " .. idx .. " (set=" .. tostring(set) .. ")")
        else
            log.warn(look.color .. " skipped: CheatTints unreadable")
        end
    end
    for fn in pairs(look.modes) do
        pawn[fn](pawn, true)
        log.info(fn .. "(true)")
    end
    if traps > 0 and valid(pawn) then
        for _ = 1, traps do apply_trap(pawn) end
    end
    applied.pawn, applied.serial = key, serial
end

local function submit(gs, pawn, key, lives, serial, traps)
    jobs.submit(function() run_job(gs, pawn, key, lives, serial, traps) end)
end

-- ---------------------------------------------------------------------------
-- API
-- ---------------------------------------------------------------------------
function M.init(opts)
    log = logger.leveled("[FILLERS]", opts and opts.log)
    regions = (opts and opts.regions) or {}
    dir = (opts and opts.dir) or dir
    can_write = type(ExecuteInGameThread) == "function"
    if not can_write then
        log.error("ExecuteInGameThread unavailable — filler items disabled")
    end
end

function M.configure(sd)
    local id = tostring(sd and sd.seed or "noseed") .. "_" .. tostring(sd and sd.slot or "noslot")
    state_file = dir .. "fillers_" .. (id:gsub("[^%w_%-]", "_")) .. ".txt"
    life_indices, lives_received = {}, 0
    lives_granted = load_granted()
    look, look_serial = {color = nil, modes = {}}, 0
    applied = {pawn = nil, serial = 0}
    trap_indices, traps_received = {}, 0
    log.info(string.format("configured: lives_granted=%d (%s)", lives_granted, state_file))
end

function M.note_item(name, index)
    if name == "Extra Life" then
        if index ~= nil and life_indices[index] then return end
        if index ~= nil then life_indices[index] = true end
        lives_received = lives_received + 1
    elseif COLORS[name] then
        if look.color ~= name then
            look.color = name
            look_serial = look_serial + 1
        end
    elseif MODES[name] then
        if not look.modes[MODES[name]] then
            look.modes[MODES[name]] = true
            look_serial = look_serial + 1
        end
    elseif name == TRAP_NAME then
        if index == nil or not trap_indices[index] then
            if index ~= nil then trap_indices[index] = true end
            traps_received = traps_received + 1
        end
    end
end

function M.tick(gs)
    if not can_write then return end
    local path = safe(function() return gs["current level"]:ToString() end, nil)
    if path ~= cur_path then
        cur_path, stable_ticks = path, 0
        if traps_received == 0 then return end
    end
    if not (path and regions[path]) then return end
    stable_ticks = stable_ticks + 1
    -- traps bypass the settle gate (a hit wants to land now); lives/looks wait
    if stable_ticks < STABLE_TICKS and traps_received == 0 then return end
    if not jobs.ready() then return end

    local pawn = safe(function() return FindFirstOf(PAWN_CLASS) end, nil)
    local key = valid(pawn) and actor_key(pawn) or nil
    if key then probe(pawn, gs, key) else pawn = nil end
    local lives = math.max(lives_received - lives_granted, 0)
    local traps = traps_received
    local look_due = key ~= nil and look_serial > 0 and
        (applied.pawn ~= key or applied.serial ~= look_serial)
    if lives == 0 and traps == 0 and not look_due then return end
    if traps > 0 and pawn == nil then return end   -- hold traps until a pawn exists (never dropped)
    traps_received = 0
    submit(gs, (look_due or traps > 0) and pawn or nil, key, lives, look_serial, traps)
end

function M.status()
    local modes = {}
    for fn in pairs(look.modes) do modes[#modes + 1] = fn:gsub("^ICheatCode", "") end
    table.sort(modes)
    return string.format("lives granted=%d received=%d look=%s%s traps=%d",
        lives_granted, lives_received, look.color or "default",
        #modes > 0 and ("+" .. table.concat(modes, "+")) or "", traps_received)
end

return M
