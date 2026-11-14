-- Author: Tim Harrison
-- Created: 2026-09-26
-- Updated: 2026-11-13

-- fillers: apply received filler items — Extra Life, cheat-code looks (colors,
-- Big Head, Flat Spyro) and Damage Trap. Its one persisted value (the granted
-- life count) lives in the shared srtap_state file for this seed+slot.
--
-- The look is applied on the pawn's own mesh/anim instance and verified by
-- reading that state back (the game's visual path, see
-- docs/kismet/BP_CPS1999_Playable.txt and docs/falcon_sdk_dump/). The
-- gamestate's code.* globals are written for the game's own spawn path, never
-- trusted as proof: their handler has guards that skip the apply silently.

local U = require("util")
local logger = require("logger")
local C = require("constants")
local S = require("srtap_state")

local M = {}

local PAWN_CLASS = "BP_CPS1999_Playable_C"
local EIT_LIFE = C.eit.EIT_Life
local STABLE_TICKS = 8      -- x 250ms poll: never write until the level has held 2s
local JOB_TIMEOUT = 5       -- seconds before an unfinished job is abandoned (and failed-job backoff)
local COLOR_DURATION = 30   -- seconds a color tint stays active before it reverts
local MODE_DURATION = 30    -- seconds a Big Head / Flat Spyro grant stays active before it wears off
local LOOK_BACKOFF = 2      -- seconds before a look write that did not stick is retried

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

-- Each cheat keeps a global float mirror the game's spawn path re-reads; we
-- write them to agree with what the pawn shows, never to learn it.
local MODE_GLOBALS = {
    ["ICheatCodeBigHeadMode"] = "code.bighead",
    ["ICheatCodeFlatSpyroMode"] = "code.flat",
}
local COLOR_GLOBAL = "code.color"

local TINT_PARAM = "Tint Color"           -- material parameter the game's tint uses
local VANILLA_MESH = "SK_CPS1999_Spyro"   -- the only mesh the game tints
local FLAT_SCALE = {X = 0.2, Y = 1, Z = 1}
local UNIT_SCALE = {X = 1, Y = 1, Z = 1}
local SCALE_TOLERANCE = 0.01

-- The game's tint base, most specific path first. The first that resolves is
-- cached for the session.
local GREYSCALE_PATHS = {
    "/Game/CPS1999_Spyro/Materials/MI_CPS1999_Spyro_Greyscale.MI_CPS1999_Spyro_Greyscale",
    "/CPS1999_Spyro/Materials/MI_CPS1999_Spyro_Greyscale.MI_CPS1999_Spyro_Greyscale",
    "/Game/CPS1999_Spyro/Materials/MI_CPS1999_Spyro_Greyscale",
    "/CPS1999_Spyro/Materials/MI_CPS1999_Spyro_Greyscale",
}

-- The vanilla body material, restored on revert. It is resolved by name rather
-- than remembered from slot 0: whatever slot 0 held when we tinted may be a
-- game-created MID that the GC frees once we replace it, and handing a freed
-- material back to SetMaterial faults the engine (crash 2026-11-10).
local BODY_PATHS = {
    "/Game/CPS1999_Spyro/Materials/MI_CPS1999_Spyro_Body.MI_CPS1999_Spyro_Body",
    "/CPS1999_Spyro/Materials/MI_CPS1999_Spyro_Body.MI_CPS1999_Spyro_Body",
    "/Game/CPS1999_Spyro/Materials/MI_CPS1999_Spyro_Body",
    "/CPS1999_Spyro/Materials/MI_CPS1999_Spyro_Body",
}

local TRAP_NAME = "Damage Trap"

local TAG = "[FILLERS]"

local log = logger.tagged(TAG)
local dir = logger.bridge_dir
local can_write = false     -- ExecuteInGameThread available
local life_indices = {}     -- AP item index -> true (Extra Life, this session)
local trap_indices = {}     -- AP item index -> true (Damage Trap, this session)
local lives_received = 0
local lives_granted = 0     -- persisted per seed+slot (srtap_state)
local look = {color = nil, color_expire = nil, modes = {}}  -- color_expire/modes[fn] = expire_at (os.time())
local traps_received = 0    -- session count; not persisted (a re-hit on reconnect is fine)
local applied_pawn = nil    -- actor key of the pawn the tint state below belongs to
local tint = {              -- the pawn's material state, reset for every new pawn
    on = false,             -- a tint is verified on the pawn
    index = nil,            -- the CheatTints index it shows
    mid = nil,              -- our dynamic material instance
    mid_off = false,        -- the MID path failed here: fall back to the cheat handler
    warned = false,         -- the skin WARN was already logged for this pawn
}
local base_mat, base_path = nil, nil  -- resolved greyscale material and the path that hit
local body_mat = nil        -- resolved vanilla body material (the revert target)
local tint_fname = nil      -- "Tint Color" as a real FName (never a Lua string)
local look_backoff = 0      -- os.time() before which a failed look write is not retried
local transient_upto = -1   -- highest AP item index already handled for looks/traps
local applied_modes = {}    -- cheat fn -> last state our handler wrote (flag-less anim)
local look_failure = nil    -- last distinct look failure, so its WARN logs once
local jobs = U.job_runner{log = function() return log end, timeout = JOB_TIMEOUT}
local probed_pawn = nil

-- ---------------------------------------------------------------------------
-- UE4SS helpers (shared: util.lua)
-- ---------------------------------------------------------------------------
local safe = U.safe
local valid = U.valid
local num = U.prop
local actor_key = U.actor_key

--- Return obj's full name, or nil when it cannot be read.
--- @return string|nil
local function obj_name(obj)
    if obj == nil then return nil end
    local name = safe(function() return obj:GetFullName() end, nil)
    if type(name) ~= "string" then name = safe(function() return obj:ToString() end, nil) end
    return type(name) == "string" and name or nil
end

--- Return an object identity key: its address when UE4SS exposes one.
--- @return string|nil
local function obj_key(obj)
    if obj == nil then return nil end
    return actor_key(obj) or tostring(obj)
end

--- Return whether a and b are the same game object.
--- @return boolean
local function same_obj(a, b)
    local ka = obj_key(a)
    return ka ~= nil and ka == obj_key(b)
end

--- Return v as a boolean, or nil when it is not a readable flag.
--- @return boolean|nil
local function bool_of(v)
    if v == true or v == false then return v end
    if type(v) == "number" then return v ~= 0 end
    return nil
end

-- The game mirrors each cheat in a global float; the fallback tint path uses
-- one. UE4SS out-params come back in a table; -1 means the read failed.
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
-- cheat tints
-- ---------------------------------------------------------------------------
--- Return the pawn's CheatTints as parallel lists: the raw FLinearColor structs
--- (what SetVectorParameterValue takes) and {R,G,B} tables (what nearest reads).
--- @return table, table
local function tint_entries(pawn)
    local raw, colors = {}, {}
    local arr = safe(function() return pawn["CheatTints"] end, nil)
    if arr == nil then return raw, colors end
    pcall(function()
        arr:ForEach(function(_, elem)
            local c = elem:get()
            raw[#raw + 1] = c
            colors[#colors + 1] = {num(c, "R") or 0, num(c, "G") or 0, num(c, "B") or 0}
        end)
    end)
    return raw, colors
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

--- Return the CheatTints index the desired color wants: 0 when none is desired,
--- the nearest entry otherwise, nil when the table is unreadable (retry).
--- @return number|nil
local function wanted_index(shown)
    if look.color == nil then return 0 end
    return nearest(shown.colors, COLORS[look.color])
end

-- ---------------------------------------------------------------------------
-- pawn mesh state (reads only)
-- ---------------------------------------------------------------------------
--- Return the pawn's skeletal mesh component, or nil.
local function pawn_mesh(pawn)
    local mesh = safe(function() return pawn.Mesh end, nil)
    if not valid(mesh) then return nil end
    return mesh
end

--- Return the mesh's component scale, or nil when unreadable.
local function mesh_scale(mesh)
    local scale = safe(function() return mesh:GetComponentScale() end, nil)
    if scale == nil then scale = safe(function() return mesh:K2_GetComponentScale() end, nil) end
    return scale
end

--- Return whether scale matches want on every axis within tolerance.
local function scale_is(scale, want)
    local x, y, z = num(scale, "X"), num(scale, "Y"), num(scale, "Z")
    if x == nil or y == nil or z == nil then return false end
    return math.abs(x - want.X) <= SCALE_TOLERANCE
        and math.abs(y - want.Y) <= SCALE_TOLERANCE
        and math.abs(z - want.Z) <= SCALE_TOLERANCE
end

--- Return scale as "x,y,z" for a WARN, or "unreadable".
local function scale_text(scale)
    local x, y, z = num(scale, "X"), num(scale, "Y"), num(scale, "Z")
    if x == nil or y == nil or z == nil then return "unreadable" end
    return string.format("%.2f,%.2f,%.2f", x, y, z)
end

--- Return the material in slot 0, or nil.
local function mesh_material(mesh)
    return safe(function() return mesh:GetMaterial(0) end, nil)
end

--- Return the mesh's anim instance, or nil.
local function mesh_anim(mesh)
    return safe(function() return mesh:GetAnimInstance() end, nil)
end

--- Return the asset leaf of a full object name ("SkeletalMesh X.X" -> "X").
local function leaf_name(name)
    return name:match("([%w_]+)%.[%w_]+$") or name
end

--- Return whether the pawn wears a skin: a mesh other than vanilla Spyro's.
local function skin_active(mesh)
    local name = obj_name(safe(function() return mesh.SkeletalMesh end, nil))
    return name ~= nil and leaf_name(name) ~= VANILLA_MESH
end

--- Read what the pawn currently shows (mesh, slot 0, anim, scale, tints).
--- @return table
local function read_shown(pawn)
    local raw, colors = tint_entries(pawn)
    local mesh = pawn_mesh(pawn)
    if mesh == nil then return {tints = raw, colors = colors} end
    local skeletal = obj_name(safe(function() return mesh.SkeletalMesh end, nil))
    return {
        mesh = mesh,
        material = mesh_material(mesh),
        anim = mesh_anim(mesh),
        scale = mesh_scale(mesh),
        skeletal = skeletal,
        skinned = skin_active(mesh),
        tints = raw,
        colors = colors,
    }
end

--- Return the greyscale base material, caching the first path that resolves.
--- @return userdata|nil
local function find_base()
    if base_mat ~= nil then return base_mat end
    for _, path in ipairs(GREYSCALE_PATHS) do
        local obj = safe(function() return StaticFindObject(path) end, nil)
        if valid(obj) then
            base_mat, base_path = obj, path
            log.debug("greyscale material: " .. path)
            return obj
        end
    end
    return nil
end

--- Return the tint material parameter as a real FName, or nil when it cannot
--- be built. An FName parameter must never be handed a Lua string: UE4SS's
--- marshaller dereferences a null name entry and takes the game down (crash
--- 2026-11-10, RC::LuaType::push_nameproperty).
--- @return userdata|nil
local function tint_param_name()
    if tint_fname ~= nil then return tint_fname end
    local lib = safe(function()
        return StaticFindObject("/Script/Engine.Default__KismetStringLibrary")
    end, nil)
    if not valid(lib) then return nil end
    local name = safe(function() return lib:Conv_StringToName(TINT_PARAM) end, nil)
    if name == nil then return nil end
    tint_fname = name
    return name
end

--- Return raw as a plain FLinearColor table, or nil when its channels are
--- unreadable. The array element from CheatTints is not passed through: only
--- numeric fields are marshalled.
--- @return table|nil
local function linear_color(raw)
    local r, g, b = num(raw, "R"), num(raw, "G"), num(raw, "B")
    if r == nil or g == nil or b == nil then return nil end
    return {R = r, G = g, B = b, A = num(raw, "A") or 1}
end

--- Log the pawn's mesh, slot 0, anim class, greyscale path and tints once per pawn.
local function probe(gs, key, shown)
    if probed_pawn == key then return end
    probed_pawn = key
    local parts = {}
    for i, t in ipairs(shown.colors) do
        parts[#parts + 1] = string.format(" %d=(%.2f,%.2f,%.2f)", i - 1, t[1], t[2], t[3])
    end
    if find_base() == nil then base_path = base_path or "not found" end
    local cheat = safe(function() return gs["enabledCheat"]:ToString() end, nil)
    log.debug(string.format(
        "pawn %s mesh=%s slot0=%s anim=%s greyscale=%s CheatTints:%s enabledCheat=%s",
        key, shown.skeletal or "unreadable", obj_name(shown.material) or "none",
        obj_name(shown.anim) or "none", base_path,
        #parts > 0 and table.concat(parts) or " unreadable", tostring(cheat)))
end

-- ---------------------------------------------------------------------------
-- desired look (the tick decides with reads; only a job writes)
-- ---------------------------------------------------------------------------
--- Back off a look write, logging msg once per distinct failure.
local function fail_look(msg)
    look_backoff = os.time() + LOOK_BACKOFF
    if look_failure ~= msg then
        look_failure = msg
        log.warn(msg)
    end
end

--- Back off and log a retry WARN once per retry window.
local function hold(msg)
    if os.time() >= look_backoff then log.warn(msg) end
    look_backoff = os.time() + LOOK_BACKOFF
end

--- Log the skin WARN once per pawn: a skinned Spyro keeps its own material.
local function warn_skin(shown)
    if tint.warned then return end
    tint.warned = true
    log.warn("tint skipped: skin active (" .. (shown.skeletal or "unreadable") .. ")")
end

--- Return whether the pawn still differs from CheatTints index idx.
local function tint_pending(idx, shown)
    if idx == 0 then return tint.on or same_obj(shown.material, tint.mid) end
    if tint.mid_off then return not (tint.on and tint.index == idx) end
    if not same_obj(shown.material, tint.mid) then return true end
    return tint.index ~= idx
end

--- Add the colour part of the plan: plan.color = index (0 reverts to default).
--- force re-plans the tint even when it looks applied, for a job that also
--- changes a mode (the mode handler rebuilds the material and drops the tint).
local function plan_color(shown, plan, force)
    local idx = wanted_index(shown)
    if idx == nil then
        hold((look.color or "color") .. " skipped: CheatTints unreadable, will retry")
        return
    end
    if shown.skinned then
        if idx > 0 then warn_skin(shown) end
        return
    end
    if not force and not tint_pending(idx, shown) then return end
    plan.color, plan.tint, plan.name = idx, shown.tints[idx + 1], look.color
end

--- Return whether Big Head is on: the anim flag when the instance exposes one,
--- otherwise what our handler last wrote (an instance without the property
--- cannot be read back).
--- @return boolean
local function big_head_on(shown)
    if shown.anim ~= nil then
        local known = bool_of(num(shown.anim, "CheatBigHeadEnabled"))
        if known ~= nil then return known end
    end
    return applied_modes["ICheatCodeBigHeadMode"] == true
end

--- Add the mode part of the plan: plan.big / plan.flat carry the wanted state.
local function plan_modes(shown, plan)
    local want = look.modes["ICheatCodeBigHeadMode"] ~= nil
    if want ~= big_head_on(shown) then plan.big = want end
    local flat_want = look.modes["ICheatCodeFlatSpyroMode"] ~= nil
    if flat_want ~= scale_is(shown.scale, FLAT_SCALE) then plan.flat = flat_want end
end

--- Return the look plan for the pawn, or nil when it already shows the look.
--- @return table|nil
local function plan_look(shown)
    if os.time() < look_backoff then return nil end
    if shown.mesh == nil then
        hold("look skipped: pawn mesh unavailable, will retry")
        return nil
    end
    local plan = {}
    plan_color(shown, plan)
    plan_modes(shown, plan)
    if next(plan) == nil then return nil end
    if (plan.big ~= nil or plan.flat ~= nil) and (look.color ~= nil or tint.on) then
        plan_color(shown, plan, true)
    end
    return plan
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

--- Grant the due extra lives and log the new total.
local function grant_lives(gs, lives)
    if lives <= 0 then return end
    gs["add item to player inventory"](EIT_LIFE, lives)
    lives_granted = lives_granted + lives
    -- Lives are rare and a lost count re-grants them, so this ledger entry is
    -- written at once rather than batched with the banner's watermark.
    S.set("lives_granted", lives_granted)
    S.flush()
    log.info(string.format("granted %d extra %s (total %d)",
        lives, lives == 1 and "life" or "lives", lives_granted))
end

--- Tint through the game's own handler: the fallback when the MID path cannot run.
local function cheat_tint(gs, pawn, idx, name)
    gs:SetGlobalFloatValue(COLOR_GLOBAL, idx)
    safe(function() return pawn:ICheatCodeSetSpyroTintColor() end)
    local back = read_global(gs, COLOR_GLOBAL)
    if back ~= idx then
        fail_look(string.format("code.color write read back %s (expected %d)", tostring(back), idx))
        return
    end
    tint.on, tint.index = idx ~= 0, (idx ~= 0) and idx or nil
    look_failure = nil
    if idx == 0 then
        log.info("color reverted to default (cheat handler)")
    else
        log.info(string.format("%s -> code.color %d (cheat handler)", name or "color", idx))
    end
end

--- Return the pawn's MID. The cached one is reused only while slot 0 still
--- holds it: a reverted MID is unreferenced and the game's GC frees it, so a
--- later method call on the stale userdata dereferences freed memory (crash
--- 2026-11-10, UObjectBase::IsA under prepare_to_handle).
local function ensure_mid(mesh)
    if tint.mid ~= nil and same_obj(mesh_material(mesh), tint.mid) then return tint.mid end
    local mid = safe(function() return mesh:CreateDynamicMaterialInstance(0, base_mat) end, nil)
    if not valid(mid) then return nil end
    tint.mid = mid
    return mid
end

--- Return the vanilla body material, caching the first path that resolves.
--- @return userdata|nil
local function find_body()
    if body_mat ~= nil then return body_mat end
    for _, path in ipairs(BODY_PATHS) do
        local obj = safe(function() return StaticFindObject(path) end, nil)
        if valid(obj) then
            body_mat = obj
            return obj
        end
    end
    return nil
end

--- Log a tint apply and record it when slot 0 reads back as our MID.
local function verify_tint(mesh, mid, idx, raw, name)
    local r, g, b = num(raw, "R") or 0, num(raw, "G") or 0, num(raw, "B") or 0
    local head = string.format("%s -> CheatTints[%d] (%.2f,%.2f,%.2f)",
        name or "color", idx, r, g, b)
    if same_obj(mesh_material(mesh), mid) then
        tint.on, tint.index = true, idx
        look_failure = nil
        log.info(head .. " applied (material verified)")
    else
        fail_look(head .. " did not stick (slot 0 " .. (obj_name(mesh_material(mesh)) or "empty") .. ")")
    end
end

--- Put the vanilla body material back on slot 0 and clear code.color. The MID
--- is dropped with it: nothing references it once slot 0 moves off it, so it
--- must not be reused after the game's GC can run.
local function revert_tint(gs, pawn, mesh)
    local body = find_body()
    if body == nil then return cheat_tint(gs, pawn, 0) end
    safe(function() return mesh:SetMaterial(0, body) end)
    gs:SetGlobalFloatValue(COLOR_GLOBAL, 0)
    tint.mid = nil
    if same_obj(mesh_material(mesh), body) then
        tint.on, tint.index = false, nil
        look_failure = nil
        log.info("color reverted to default (verified)")
    else
        fail_look("color revert did not stick (slot 0 " ..
            (obj_name(mesh_material(mesh)) or "empty") .. ")")
    end
end

--- Apply CheatTints index idx on the pawn's slot 0 (0 reverts), then verify it.
local function apply_tint(gs, pawn, mesh, idx, raw, name)
    if tint.mid_off then return cheat_tint(gs, pawn, idx, name) end
    if idx == 0 then return revert_tint(gs, pawn, mesh) end
    if find_base() == nil then
        tint.mid_off = true
        log.warn("tint: greyscale material not found on any known path; using ICheatCodeSetSpyroTintColor")
        return cheat_tint(gs, pawn, idx, name)
    end
    local param, color = tint_param_name(), linear_color(raw)
    if param == nil or color == nil then
        tint.mid_off = true
        log.warn("tint: material parameter unavailable; using ICheatCodeSetSpyroTintColor")
        return cheat_tint(gs, pawn, idx, name)
    end
    local mid = ensure_mid(mesh)
    if mid == nil then
        tint.mid_off = true
        log.warn("tint: CreateDynamicMaterialInstance unavailable; using ICheatCodeSetSpyroTintColor")
        return cheat_tint(gs, pawn, idx, name)
    end
    safe(function() return mid:SetVectorParameterValue(param, color) end)
    safe(function() return mesh:SetMaterial(0, mid) end)
    gs:SetGlobalFloatValue(COLOR_GLOBAL, idx)
    verify_tint(mesh, mid, idx, raw, name)
end

--- Return the anim instance's Big Head flag, or nil when this build cannot read
--- it back (the write still lands; only the readback is missing).
local function big_head_flag(anim)
    if anim == nil then return nil end
    return num(anim, "CheatBigHeadEnabled")
end

--- Log a Big Head apply. The flag is the verification when this UE4SS build can
--- read it back; when it cannot, the write and notify are what run and the look
--- is recorded as applied rather than retried every tick (live 2026-11-10: the
--- flag reads nil on a working apply).
local function verify_bighead(anim, on, state)
    local flag = big_head_flag(anim)
    local known = bool_of(flag)
    if known == nil then
        applied_modes["ICheatCodeBigHeadMode"] = on
        look_failure = nil
        log.debug("BigHeadMode " .. state .. " (flag not readable on " ..
            (obj_name(anim) or "?") .. ")")
        return
    end
    if known == on then
        applied_modes["ICheatCodeBigHeadMode"] = on
        look_failure = nil
        log.info("BigHeadMode " .. state .. " (anim flag verified)")
        return
    end
    fail_look("BigHeadMode " .. state .. " did not stick (anim flag " ..
        tostring(flag) .. " on " .. (obj_name(anim) or "?") .. ")")
end

--- Turn Big Head on or off on the anim instance: write the flag the anim graph
--- reads, then fire the notify it expects. This is the pair that works live;
--- the pawn's own handler is not needed and carries extra gating.
local function apply_bighead(gs, mesh, on)
    gs:SetGlobalFloatValue(MODE_GLOBALS["ICheatCodeBigHeadMode"], on and 1 or 0)
    local anim = mesh_anim(mesh)
    if anim == nil then
        return fail_look("BigHeadMode " .. (on and "on" or "off") .. " skipped: anim instance unavailable")
    end
    pcall(function() anim["CheatBigHeadEnabled"] = on end)
    pcall(function() return anim:INotifyCheatBigHead(on) end)
    verify_bighead(anim, on, on and "on" or "off")
end

--- Squash or restore the pawn's mesh scale, then verify the component scale.
local function apply_flat(gs, mesh, on)
    gs:SetGlobalFloatValue(MODE_GLOBALS["ICheatCodeFlatSpyroMode"], on and 1 or 0)
    local want = on and FLAT_SCALE or UNIT_SCALE
    safe(function() return mesh:SetWorldScale3D(want) end)
    local state = on and "on" or "off"
    local back = mesh_scale(mesh)
    if scale_is(back, want) then
        look_failure = nil
        log.info("flat spyro " .. state .. " (mesh scale verified)")
    else
        fail_look("flat spyro " .. state .. " did not stick (scale " .. scale_text(back) .. ")")
    end
end

--- Apply a look plan: modes first (their handlers rebuild the mesh material),
--- the tint last so it survives them.
local function apply_look(gs, pawn, plan)
    if plan == nil then return end
    local mesh = pawn_mesh(pawn)
    if mesh == nil then return end
    if plan.big ~= nil then apply_bighead(gs, mesh, plan.big) end
    if plan.flat ~= nil then apply_flat(gs, mesh, plan.flat) end
    if plan.color ~= nil then apply_tint(gs, pawn, mesh, plan.color, plan.tint, plan.name) end
end

--- Grant lives and apply the due look changes and traps on the game thread.
local function run_job(gs, pawn, lives, traps, plan)
    grant_lives(gs, lives)
    if pawn == nil or not valid(pawn) then return end
    apply_look(gs, pawn, plan)
    for _ = 1, traps do apply_trap(pawn) end
end

--- Queue a look/trap job on the one-job game-thread runner.
local function submit(gs, pawn, lives, traps, plan)
    local target = (plan ~= nil or traps > 0) and pawn or nil
    jobs.submit(function()
        return run_job(gs, target, lives, traps, plan)
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

--- Forget the per-pawn material state and remember key as the known pawn.
local function reset_tint(key)
    tint = {on = false, index = nil, mid = nil, mid_off = false, warned = false}
    applied_modes = {}
    applied_pawn = key
end

--- Reset per-seed state and load the persisted lives-granted count.
--- @param sd table|nil Slot data carrying seed and slot.
function M.configure(sd)
    S.open(sd, dir)
    life_indices, lives_received = {}, 0
    lives_granted = S.get("lives_granted", 0)
    look = {color = nil, color_expire = nil, modes = {}}
    transient_upto = S.get("transient_upto", -1)
    reset_tint(nil)
    trap_indices, traps_received = {}, 0
    log.info(string.format("configured: lives_granted=%d", lives_granted))
end

--- Record an AP item index in seen, returning whether it was new.
local function first_index(seen, index)
    if index == nil then return true end
    if seen[index] then return false end
    seen[index] = true
    return true
end

--- Return whether index is newer than the last handled transient grant. AP
--- re-delivers the whole received-item history on every connect, so a replay
--- must not re-grant a look or a trap; record the watermark as a side effect.
--- @return boolean
local function fresh_index(index)
    if index == nil then return true end
    if index <= transient_upto then return false end
    transient_upto = index
    S.set("transient_upto", transient_upto)
    S.flush()
    return true
end

--- Queue a damage trap, deduped by item index.
local function note_trap(index)
    if first_index(trap_indices, index) then
        traps_received = traps_received + 1
    end
end

--- Queue a fresh colour, mode or trap grant; a replayed index is ignored.
local function note_transient(name, index)
    if not fresh_index(index) then return end
    if COLORS[name] then
        -- a repeat grant restarts the clock rather than queueing a revert
        look.color = name
        look.color_expire = os.time() + COLOR_DURATION
    elseif MODES[name] then
        -- a duplicate grant restarts the clock rather than stacking
        look.modes[MODES[name]] = os.time() + MODE_DURATION
    else
        note_trap(index)
    end
end

--- Record a received filler item by name, deduped by AP item index.
--- @param index number|nil AP item index used for dedup.
function M.note_item(name, index)
    if name == "Extra Life" then
        if first_index(life_indices, index) then lives_received = lives_received + 1 end
        return
    end
    if COLORS[name] or MODES[name] or name == TRAP_NAME then
        note_transient(name, index)
    end
end

--- Expire the tint and modes whose wall-clock duration has run out.
local function expire_look(now)
    if look.color_expire and now >= look.color_expire then
        look.color, look.color_expire = nil, nil
    end
    for fn, expire in pairs(look.modes) do
        if now >= expire then look.modes[fn] = nil end
    end
end

--- Find the pawn and its actor key, forgetting the tint state for a new pawn.
local function find_pawn()
    local pawn = U.controlled_pawn() or safe(function() return FindFirstOf(PAWN_CLASS) end, nil)
    local key = valid(pawn) and actor_key(pawn) or nil
    if not key then return nil, nil end
    if key ~= applied_pawn then reset_tint(key) end
    return pawn, key
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
    local pawn, key = find_pawn()
    local plan
    if key ~= nil then
        local shown = read_shown(pawn)
        probe(world.gs, key, shown)
        plan = plan_look(shown)
    end
    local lives = math.max(lives_received - lives_granted, 0)
    local traps = traps_received
    if not due_work(plan ~= nil, lives, traps, pawn) then return end
    traps_received = 0
    submit(world.gs, pawn, lives, traps, plan)
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
