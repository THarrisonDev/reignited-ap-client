-- Author: Tim Harrison
-- Created: 2026-09-26
-- Updated: 2026-10-23

-- level_locks_core: factory behind the per-game spyroN/level_locks.lua
-- modules. It locks homeworld portals whose level key item is still missing,
-- re-asserting the lock when the game re-enables a portal, and unlocks when
-- the key arrives. Levers and ordering are live-proven.
--
-- Invariant: the lock record is durable per region. It survives a poll whose
-- level-path read failed (reported as a transition) and dies only when the
-- game rebuilds the portal actor, which is a real level load. Every write is
-- read back on the game thread, so a refused write is retried, never dropped.

local U = require("util")
local logger = require("logger")
local O = require("option")

local LABEL = "LOCKED"
local STABLE_TICKS = 8      -- x 250ms poll: never write until the level has held 2s
local GRACE_SECONDS = 3     -- after connect, wait this long for the item backlog
local JOB_TIMEOUT = 5       -- seconds before an unfinished job is abandoned (and failed-job backoff)

--- Build a level-lock module for one game.
--- @return table
local function new(cfg)
    -- cfg: {game, tag (log-tag), label (configure log), prefix (status),
    --        homeworlds, target_homes or nil, portal_class}
    -- target_homes: a portal whose target region is a homeworld is never
    -- locked — homeworld-to-homeworld transitions stay open (locking a
    -- homeworld's own return portal could trap the player). nil = no skip
    -- (Spyro 1 homeworlds have no onward portals).

    local M = {}

    local TAG = cfg.tag or "[LOCKS]"
    local log = logger.tagged(TAG)
    local code_to_region = {}   -- "LS102" -> "Stone Hill"
    local can_write = false     -- ExecuteInGameThread available
    local enabled = false
    local level_keys = {}       -- region -> key item name, this seed
    local lockable = 0
    local held = {}             -- received item name -> true
    local items_seen = false
    local connected_at = nil
    local locks = {}            -- region -> {region, name, actor, locked, reasserts, here}
    local jobs = U.job_runner{log = function() return log end, timeout = JOB_TIMEOUT}

    --- Return p's portal name component when it is valid, else nil.
    local function name_comp(p)
        local c = U.safe(function() return p["PortalNameComponent"] end, nil)
        if U.valid(c) then return c end
        return nil
    end

    -- -----------------------------------------------------------------------
    -- game-thread work (only ever called from inside a job)
    -- -----------------------------------------------------------------------
    --- Unhide every glyph character attached to comp (freshly remade ones
    --- spawn hidden).
    local function reveal_glyphs(comp)
        local arr = U.safe(function() return comp["Characters"] end, nil)
        if arr == nil then return end
        --- Unhide actor a when it is valid.
        local function reveal(a)
            if U.valid(a) then pcall(function() a:SetActorHiddenInGame(false) end) end
        end
        local okF = pcall(function()
            arr:ForEach(function(_, elem) reveal(elem:get()) end)
        end)
        if not okF then
            local count = U.safe(function() return arr:GetArrayNum() end, 0) or 0
            for i = 1, count do reveal(U.safe(function() return arr[i] end, nil)) end
        end
    end

    --- Rebuild comp's floating name as text, using its own scale and char width.
    local function remake(comp, text)
        local scale = U.prop(comp, "Scale")
        local width = U.prop(comp, "default char width")
        if type(scale) ~= "number" or type(width) ~= "number" then
            log.warn("relabel skipped: unreadable Scale/char width")
            return
        end
        local ok, err = pcall(function() comp["REMAKE text"](text, scale, width) end)
        if not ok then log.warn("relabel to '" .. text .. "' failed: " .. tostring(err)) end
    end

    --- Unlock a portal and restore its name label. Returns false while the game
    --- still has the portal disabled, so the job runner retries after the backoff.
    local function unlock(p, st, comp, labelled)
        if labelled then remake(comp, st.name) end
        p:setPortalEnabled(true)
        if U.prop(p, "EnableTransport") ~= true then
            log.warn("unlock " .. st.region .. " refused by the game (still disabled)")
            return false
        end
        st.locked = false
        log.info("unlocked " .. st.region)
    end

    --- Lock or re-assert a portal the game has left enabled. Returns false when
    --- the game refused the write, so the job runner retries after the backoff.
    local function lock(p, st, comp, labelled, kind)
        -- the blueprint disables the portal itself during its enter transition;
        -- only act on a portal that is still enabled right now
        if U.prop(p, "EnableTransport") ~= true then return end
        p:setPortalEnabled(false)
        if U.prop(p, "EnableTransport") ~= false then
            log.warn(kind .. " " .. st.region .. " refused by the game (still enabled)")
            return false
        end
        if kind == "lock" then
            if labelled then remake(comp, LABEL) end
            st.locked = true
            log.info("locked " .. st.region)
        else
            st.reasserts = st.reasserts + 1
            if st.reasserts <= 3 or st.reasserts % 20 == 0 then
                log.debug(string.format("re-locked %s (game re-enabled it, #%d)", st.region, st.reasserts))
            end
        end
        -- disabling hid the glyphs, and freshly remade ones spawn hidden
        if labelled then reveal_glyphs(comp) end
    end

    --- Apply a lock, reassert or unlock write to portal p for state st.
    local function run_job(p, st, kind)
        if not U.valid(p) then return end
        local comp = name_comp(p)
        local labelled = comp ~= nil and st.name ~= nil
        if kind == "unlock" then
            return unlock(p, st, comp, labelled)
        end
        return lock(p, st, comp, labelled, kind)
    end

    --- Submit the portal write job for kind to the game-thread runner.
    local function submit(p, st, kind)
        jobs.submit(function() return run_job(p, st, kind) end,
            {desc = kind .. " job for " .. st.region, fail = kind .. " " .. st.region})
    end

    -- -----------------------------------------------------------------------
    -- decisions (async thread: reads only)
    -- -----------------------------------------------------------------------
    --- Return whether region should be locked: enabled, key not yet held, and
    --- past the post-connect grace so the item backlog can arrive first.
    local function should_lock(region)
        if not enabled then return false end
        local key = level_keys[region]
        if not key or held[key] then return false end
        -- hold off right after connect so the item backlog can arrive first
        return items_seen or (connected_at ~= nil and os.time() - connected_at >= GRACE_SECONDS)
    end

    --- Return the durable lock record for region, creating it on first sight and
    --- adopting a rebuilt actor: a new address means a real level load, which
    --- leaves the portal vanilla, while a read blip leaves the actor in place and
    --- the lock survives. The name is kept from the first sighting, before this
    --- module relabels the portal.
    --- @param p userdata The portal actor.
    --- @param region string Lockable region the portal targets.
    --- @return table
    local function lock_state(p, region)
        local st = locks[region]
        if not st then
            local comp = name_comp(p)
            st = {region = region, name = comp and U.fstr(comp, "display text") or nil,
                  actor = nil, locked = false, reasserts = 0, here = false}
            locks[region] = st
        end
        st.here = true
        local addr = U.actor_key(p)
        if addr ~= st.actor then
            st.actor, st.locked, st.reasserts = addr, false, 0
        end
        return st
    end

    --- Submit this portal's write if one is due; return true if it did.
    local function plan_portal(p, st)
        if should_lock(st.region) then
            if U.prop(p, "EnableTransport") == true then
                submit(p, st, st.locked and "reassert" or "lock")
                return true
            end
        elseif st.locked then
            submit(p, st, "unlock")
            return true
        end
        return false
    end

    -- -----------------------------------------------------------------------
    -- API
    -- -----------------------------------------------------------------------
    --- Wire the injected logger and region map, build the portal-code index,
    --- and detect the game-thread write API.
    function M.init(opts)
        log = logger.leveled(TAG, opts and opts.log)
        code_to_region = U.region_codes(opts and opts.regions)
        can_write = U.can_write()
        if not can_write then
            log.error("ExecuteInGameThread unavailable — level locks disabled")
        end
    end

    --- Return the slot's level keys and how many are lockable.
    local function read_level_keys(sg)
        local keys, count = {}, 0
        local raw = type(sg.level_keys) == "table" and sg.level_keys or {}
        for region, key in pairs(raw) do
            if type(region) == "string" and type(key) == "string" then
                keys[region] = key
                count = count + 1
            end
        end
        return keys, count
    end

    --- Read this game's level keys and option from slot data and reset
    --- per-session state. The lock records stay: actor identity is the real
    --- guard, and a lock left over from a previous save is then unlocked instead
    --- of stranded disabled.
    function M.configure(sd)
        local opts = O.game_options(sd, cfg.game)
        level_keys, lockable = read_level_keys(O.game_data(sd, cfg.game))
        enabled = can_write and O.flag(opts.level_locks, "level_locks", log) and lockable > 0
        for _, st in pairs(locks) do st.here = false end
        held, items_seen, connected_at = {}, false, os.time()
        log.info(string.format("configured%s: enabled=%s lockable=%d (level_locks=%s)",
            cfg.label, tostring(enabled), lockable, tostring(opts.level_locks)))
    end

    --- Mark a received level key item as held for this session.
    function M.note_item(name)
        items_seen = true
        if type(name) ~= "string" or held[name] then return end
        held[name] = true
        for region, key in pairs(level_keys) do
            if key == name then
                log.info("key received: " .. name .. " (" .. region .. ")")
                return
            end
        end
    end

    --- Return the region a portal targets, when its code resolves.
    local function portal_region(p)
        local partner = U.valid(p) and U.fstr(p, "PartnerPortalName") or nil
        local code = partner and partner:match("^(LS%d%d%d)_LevelStart$")
        return code and code_to_region[code]
    end

    --- Return the region p targets when it may be locked, nil otherwise.
    --- Portals are scanned only inside this game's homeworlds; return portals
    --- standing in realms are never touched. A portal whose target region is a
    --- homeworld is never locked — homeworld-to-homeworld transitions stay open
    --- (locking a homeworld's own return portal could trap the player).
    --- @return string|nil
    local function lockable_region(p)
        local region = portal_region(p)
        if region == nil then return nil end
        if cfg.target_homes and cfg.target_homes[region] then return nil end
        return region
    end

    --- Plan at most one portal write for the actors in the current homeworld,
    --- recording every one of them first.
    local function poll_portals()
        local actors = U.safe(function() return FindAllOf(cfg.portal_class) end, nil) or {}
        local planned = false
        for _, p in ipairs(actors) do
            local region = lockable_region(p)
            if region then
                planned = planned or plan_portal(p, lock_state(p, region))
            end
        end
    end

    --- Poll the world snapshot: once in a stable homeworld, plan one portal write
    --- per tick.
    --- @param world table game_state snapshot.
    function M.tick(world)
        for _, st in pairs(locks) do st.here = false end
        if not world.ok then return end
        -- level locks always run in a homeworld; they hold no option flag
        if not U.gate_ready(world, true, cfg.homeworlds, STABLE_TICKS, jobs) then return end
        poll_portals()
    end

    --- Return a one-line heartbeat summary of keys held and portals locked.
    function M.status()
        local keys = 0
        for _, key in pairs(level_keys) do
            if held[key] then keys = keys + 1 end
        end
        local locked_here = 0
        for _, st in pairs(locks) do
            if st.locked and st.here then locked_here = locked_here + 1 end
        end
        return string.format("%senabled=%s keys=%d/%d locked_here=%d",
            cfg.prefix, tostring(enabled), keys, lockable, locked_here)
    end

    M.tag = TAG
    return M
end

return {new = new}