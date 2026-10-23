-- Author: Tim Harrison
-- Created: 2026-09-26
-- Updated: 2026-10-11

-- fillers: apply received filler items — Extra Life, cheat-code looks (colors,
-- Big Head, Flat Spyro) and Damage Trap. See docs/game_state_control.md.

local U = require("util")
local logger = require("logger")
local C = require("constants")

local M = {}

local PAWN_CLASS = "BP_CPS1999_Playable_C"
local EIT_LIFE = C.eit.EIT_Life
local STABLE_TICKS = 8      -- x 250ms poll: never write until the level has held 2s
local JOB_TIMEOUT = 5       -- seconds before an unfinished job is abandoned (and failed-job backoff)
local COLOR_DURATION = 30   -- seconds a color tint stays active before it reverts
local MODE_DURATION = 30    -- seconds a Big Head / Flat Spyro grant stays active before it wears off

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

-- Each cheat keeps a global float mirror the game updates when the cheat
-- toggles; reading these (not a write-once latch) is what makes re-assertion
-- survive a death/respawn/cutscene that drops the look on the same pawn.
local MODE_GLOBALS = {
    ["ICheatCodeBigHeadMode"] = "code.bighead",
    ["ICheatCodeFlatSpyroMode"] = "code.flat",
}
local COLOR_GLOBAL = "code.color"

local TRAP_NAME = "Damage Trap"

local TAG = "[FILLERS]"

local log = logger.tagged(TAG)
local dir = "C:/srtap_bridge/"
local can_write = false     -- ExecuteInGameThread available
local state_file = nil
local life_indices = {}     -- AP item index -> true (Extra Life, this session)
local trap_indices = {}     -- AP item index -> true (Damage Trap, this session)
local lives_received = 0
local lives_granted = 0     -- persisted per seed+slot
local look = {color = nil, color_expire = nil, modes = {}}  -- color_expire/modes[fn] = expire_at (os.time())
local traps_received = 0    -- session count; not persisted (a re-hit on reconnect is fine)
local applied_pawn = nil    -- actor key of the pawn the look was last pushed to;
                            -- a new pawn (level load) forces a re-apply even
                            -- though the cheat globals persist
local revert_color = false  -- a color expired: push code.color back to 0 once
local jobs = U.job_runner{log = function() return log end, timeout = JOB_TIMEOUT}
local probed_pawn = nil

-- ---------------------------------------------------------------------------
-- UE4SS helpers (shared: util.lua)
-- ---------------------------------------------------------------------------
local safe = U.safe
local valid = U.valid
local num = U.prop
local actor_key = U.actor_key

-- The game mirrors each look in a global float (code.color/code.bighead/...),
-- updated by its own handlers. Reading them tells us what the game currently
-- shows, so a dropped look is re-asserted on the next tick. UE4SS out-params
-- come back in a table; -1 means the read failed.
--- Return the float value of gamestate global key, or nil when unreadable.
--- @return number|nil
local function read_global(gs, key)
    local out = {}
    safe(function() return gs:GetGlobalFloatValue(key, out) end, false)
    local v = out.Value
    if type(v) ~= "number" then v = out.value end
    if type(v) == "table" then v = v.value end          -- UE4SS out-param quirk
    return tonumber(v)
end

-- ---------------------------------------------------------------------------
-- persistence: lives_granted=N in <dir>fillers_<seed>_<slot>.txt
-- ---------------------------------------------------------------------------
--- Return the persisted lives_granted count, or 0 when absent/unreadable.
local function load_granted()
    local f = state_file and io.open(state_file, "r")
    if not f then return 0 end
    local n = tonumber((f:read("a") or ""):match("lives_granted=(%d+)"))
    f:close()
    return n or 0
end

--- Persist the lives_granted count; warn when the file cannot be written.
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
--- Return the pawn's CheatTints as a list of {R,G,B} tables, empty when unreadable.
--- @return table
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

--- Return the 0-based index of the tint nearest rgb, or nil when unreadable.
--- @return number|nil
local function nearest(tints, rgb)
    local best, best_d
    for i, t in ipairs(tints) do
        local d = (t[1] - rgb[1]) ^ 2 + (t[2] - rgb[2]) ^ 2 + (t[3] - rgb[3]) ^ 2
        if best_d == nil or d < best_d then best, best_d = i - 1, d end
    end
    return best
end

-- CheatTints index the desired color wants: 0 (no tint) when none is desired,
-- the nearest entry otherwise, or nil when the table is unreadable (retry).
--- Return the CheatTints index for the desired color.
--- @return number|nil
local function color_index(pawn)
    if look.color == nil then return 0 end
    if not valid(pawn) then return nil end
    return nearest(read_tints(pawn), COLORS[look.color])
end

--- Log the pawn's CheatTints and enabled cheat once per pawn.
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
-- Damage trap: find Spyro's health attribute set (U.find_health_set) and
-- subtract one hit from HealthCurrent. The game reacts to the reflected float
-- and kills Spyro at 0, just like a real hit.
--- Subtract one hit from the pawn's health attribute set.
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

-- Apply a job's due look. Order matters: the game's mode handlers rebuild the
-- mesh material and drop an active tint, so every mode transition is written
-- FIRST and the color (if it should be visible) is re-asserted LAST. That is
-- also why a color is re-applied whenever any mode changes, not only when the
-- color itself changed.
--- Grant the due extra lives and log the new total.
local function grant_lives(gs, lives)
    if lives <= 0 then return end
    gs["add item to player inventory"](EIT_LIFE, lives)
    lives_granted = lives_granted + lives
    save_granted()
    log.info(string.format("granted %d extra %s (total %d)",
        lives, lives == 1 and "life" or "lives", lives_granted))
end

--- Write the due mode transitions, returning whether any was written.
--- The cheat globals are written too, not just the handler called: the game's
--- CheckCheat re-reads them on pawn setup, so they carry the mode to the next
--- pawn (and give reconcile a readable state to compare against).
local function set_modes(gs, pawn, turn_on, turn_off)
    local changed = false
    for _, fn in ipairs(turn_on) do
        gs:SetGlobalFloatValue(MODE_GLOBALS[fn], 1)
        pawn[fn](pawn, true)
        log.info(fn .. "(true)")
        changed = true
    end
    for _, fn in ipairs(turn_off) do
        gs:SetGlobalFloatValue(MODE_GLOBALS[fn], 0)
        pawn[fn](pawn, false)
        log.info(fn .. "(false, expired)")
        changed = true
    end
    return changed
end

--- Apply the wanted tint (or the revert), returning false when a retry is due.
local function apply_color(gs, pawn, color_changed)
    if look.color == nil then
        if not color_changed then return true end
        gs:SetGlobalFloatValue(COLOR_GLOBAL, 0)
        pawn:ICheatCodeSetSpyroTintColor()
        log.info("color reverted to default (expired)")
        return true
    end
    local idx = nearest(read_tints(pawn), COLORS[look.color])
    if idx == 0 then
        log.warn(look.color .. " skipped: nearest CheatTints entry is 0 (no tint)")
        return true
    end
    if not idx then
        log.warn(look.color .. " skipped: CheatTints unreadable, will retry")
        return false
    end
    gs:SetGlobalFloatValue(COLOR_GLOBAL, idx)
    pawn:ICheatCodeSetSpyroTintColor()
    local back = read_global(gs, COLOR_GLOBAL)
    if back == idx then
        log.info(look.color .. " -> code.color " .. idx)
        return true
    end
    log.warn(look.color .. ": code.color write read back " ..
        tostring(back) .. " (expected " .. idx .. "), will retry")
    return false
end

--- Grant lives and apply the due look changes and traps on the game thread.
local function run_job(gs, pawn, lives, traps, color_changed, turn_on, turn_off)
    grant_lives(gs, lives)
    if pawn == nil or not valid(pawn) then return end
    local mode_changed = set_modes(gs, pawn, turn_on, turn_off)
    if (color_changed or mode_changed) and not apply_color(gs, pawn, color_changed) then
        return false
    end
    if traps > 0 and valid(pawn) then
        for _ = 1, traps do apply_trap(pawn) end
    end
end

--- Queue a look/trap job on the one-job game-thread runner.
local function submit(gs, pawn, lives, traps, color_changed, turn_on, turn_off)
    local look_due = color_changed or #turn_on > 0 or #turn_off > 0
    local target = (look_due or traps > 0) and pawn or nil
    jobs.submit(function()
        return run_job(gs, target, lives, traps, color_changed, turn_on, turn_off)
    end)
end

-- ---------------------------------------------------------------------------
-- API
-- ---------------------------------------------------------------------------
--- Initialize the module from the host's opts {log, dir}.
function M.init(opts)
    log = logger.leveled(TAG, opts and opts.log)
    dir = (opts and opts.dir) or dir
    can_write = U.can_write()
    if not can_write then
        log.error("ExecuteInGameThread unavailable — filler items disabled")
    end
end

--- Reset per-seed state and load the persisted lives-granted count.
--- @param sd table|nil Slot data carrying seed and slot.
function M.configure(sd)
    local id = tostring(sd and sd.seed or "noseed") .. "_" .. tostring(sd and sd.slot or "noslot")
    state_file = dir .. "fillers_" .. (id:gsub("[^%w_%-]", "_")) .. ".txt"
    life_indices, lives_received = {}, 0
    lives_granted = load_granted()
    look = {color = nil, color_expire = nil, modes = {}}
    revert_color, applied_pawn = false, nil
    trap_indices, traps_received = {}, 0
    log.info(string.format("configured: lives_granted=%d (%s)", lives_granted, state_file))
end

--- Record an AP item index in seen, returning whether it was new.
local function first_index(seen, index)
    if index == nil then return true end
    if seen[index] then return false end
    seen[index] = true
    return true
end

--- Record a received filler item by name, deduped by AP item index.
--- @param index number|nil AP item index used for dedup.
function M.note_item(name, index)
    if name == "Extra Life" then
        if first_index(life_indices, index) then lives_received = lives_received + 1 end
    elseif COLORS[name] then
        -- a repeat grant restarts the clock rather than queueing a revert
        look.color = name
        look.color_expire = os.time() + COLOR_DURATION
    elseif MODES[name] then
        -- a duplicate grant restarts the clock rather than stacking
        look.modes[MODES[name]] = os.time() + MODE_DURATION
    elseif name == TRAP_NAME and first_index(trap_indices, index) then
        traps_received = traps_received + 1
    end
end

--- Expire the tint and modes whose wall-clock duration has run out.
local function expire_look(now)
    if look.color_expire and now >= look.color_expire then
        look.color, look.color_expire, revert_color = nil, nil, true
    end
    for fn, expire in pairs(look.modes) do
        if now >= expire then look.modes[fn] = nil end
    end
end

--- Find the pawn, its actor key and whether it is one this module has not
--- pushed a look to.
local function find_pawn(gs)
    local pawn = safe(function() return FindFirstOf(PAWN_CLASS) end, nil)
    local key = valid(pawn) and actor_key(pawn) or nil
    if not key then return nil, nil, false end
    probe(pawn, gs, key)
    local new_pawn = key ~= applied_pawn
    if new_pawn then applied_pawn = key end
    return pawn, key, new_pawn
end

--- Return whether the wanted look drifts from the cheat globals the game shows.
local function look_differs(gs, pawn, key, new_pawn)
    if key == nil then return false end
    if revert_color then return true end
    local want = look.color ~= nil or next(look.modes) ~= nil
    return want and (new_pawn or color_index(pawn) ~= read_global(gs, COLOR_GLOBAL))
end

--- Return the modes to turn on and off, given the wanted set.
local function plan_modes(gs, new_pawn)
    local turn_on, turn_off = {}, {}
    for fn in pairs(look.modes) do
        if new_pawn or read_global(gs, MODE_GLOBALS[fn]) ~= 1 then turn_on[#turn_on + 1] = fn end
    end
    for fn, glob in pairs(MODE_GLOBALS) do
        if look.modes[fn] == nil and read_global(gs, glob) == 1 then
            turn_off[#turn_off + 1] = fn
        end
    end
    return turn_on, turn_off
end

--- Return whether this poll may write: settled, playable and off cooldown.
local function write_ready(world)
    if not can_write or not world.ok or not world.playable then return false end
    if world.changed and traps_received == 0 then return false end
    return world.ticks >= STABLE_TICKS or traps_received > 0
end

--- Return whether this poll has work: a due look, lives or trapped hits.
local function due_work(look_due, lives, traps, pawn)
    if look_due then return true end
    if lives <= 0 and traps == 0 then return false end
    return traps == 0 or pawn ~= nil
end

--- Poll the world snapshot, reconcile the desired look, and submit due work.
--- @param world table game_state snapshot.
function M.tick(world)
    if not write_ready(world) or not jobs.ready() then return end
    expire_look(os.time())
    local pawn, key, new_pawn = find_pawn(world.gs)
    local color_changed = look_differs(world.gs, pawn, key, new_pawn)
    local turn_on, turn_off = {}, {}
    if key ~= nil then turn_on, turn_off = plan_modes(world.gs, new_pawn) end
    local lives = math.max(lives_received - lives_granted, 0)
    local traps = traps_received
    local look_due = color_changed or #turn_on > 0 or #turn_off > 0
    if not due_work(look_due, lives, traps, pawn) then return end
    traps_received = 0
    revert_color = false
    submit(world.gs, pawn, lives, traps, color_changed, turn_on, turn_off)
end

--- Return a one-line status summary of lives, look and traps.
--- @return string
function M.status()
    local modes = {}
    for fn in pairs(look.modes) do modes[#modes + 1] = fn:gsub("^ICheatCode", "") end
    table.sort(modes)
    return string.format("lives granted=%d received=%d look=%s%s traps=%d",
        lives_granted, lives_received, look.color or "default",
        #modes > 0 and ("+" .. table.concat(modes, "+")) or "", traps_received)
end
M.tag = TAG

return M
