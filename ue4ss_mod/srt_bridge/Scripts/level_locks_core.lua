-- level_locks_core: factory behind the per-game spyroN/level_locks.lua
-- modules. It locks homeworld portals whose level key item is still missing,
-- re-asserting the lock when the game re-enables a portal, and unlocks when
-- the key arrives. Levers and ordering are live-proven
-- (docs/game_state_control.md §9.5.1).

local U = require("util")
local logger = require("logger")

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

    local log = logger.tagged(cfg.tag or "[LOCKS]")
    local regions = {}          -- map path -> region (generated regions.lua)
    local code_to_region = {}   -- "LS102" -> "Stone Hill"
    local can_write = false     -- ExecuteInGameThread available
    local enabled = false
    local level_keys = {}       -- region -> key item name, this seed
    local lockable = 0
    local held = {}             -- received item name -> true
    local items_seen = false
    local connected_at = nil
    local cur_path, stable_ticks = nil, 0
    local portals = {}          -- actor address -> {region, name, locked, reasserts}
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

    --- Apply a lock, reassert or unlock write to portal p for state st.
    local function run_job(p, st, kind)
        if not U.valid(p) then return end
        local comp = name_comp(p)
        local labelled = comp ~= nil and st.name ~= nil
        if kind == "unlock" then
            if labelled then remake(comp, st.name) end
            p:setPortalEnabled(true)
            st.locked = false
            log.info("unlocked " .. st.region)
            return
        end
        -- lock / reassert: the blueprint disables the portal itself during its
        -- enter transition; only act on a portal that is still enabled right now
        if U.prop(p, "EnableTransport") ~= true then return end
        p:setPortalEnabled(false)
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

    --- Submit the portal write job for kind to the game-thread runner.
    local function submit(p, st, kind)
        jobs.submit(function() run_job(p, st, kind) end,
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

    --- Submit a job for this portal if it needs one; return true if it did.
    local function plan_portal(p, key, region)
        local st = portals[key]
        if not st then
            local comp = name_comp(p)
            st = {region = region, name = comp and U.fstr(comp, "display text") or nil,
                  locked = false, reasserts = 0}
            portals[key] = st
        end
        if should_lock(region) then
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
        log = logger.leveled(cfg.tag or "[LOCKS]", opts and opts.log)
        regions = (opts and opts.regions) or {}
        code_to_region = {}
        for path, region in pairs(regions) do
            local code = path:match("^/(LS%d%d%d)_")
            if code then code_to_region[code] = region end
        end
        can_write = type(ExecuteInGameThread) == "function"
        if not can_write then
            log.error("ExecuteInGameThread unavailable — level locks disabled")
        end
    end

    --- Read this game's level keys and option from slot data and reset
    --- per-session state.
    function M.configure(sd)
        local games = sd and type(sd.games) == "table" and sd.games or {}
        local sg = type(games[cfg.game]) == "table" and games[cfg.game] or {}
        local opts = type(sg.options) == "table" and sg.options or {}
        level_keys, lockable = {}, 0
        for region, key in pairs(type(sg.level_keys) == "table" and sg.level_keys or {}) do
            if type(region) == "string" and type(key) == "string" then
                level_keys[region] = key
                lockable = lockable + 1
            end
        end
        enabled = can_write and (opts.level_locks == 1 or opts.level_locks == true) and lockable > 0
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

    --- Poll gs: once in a stable homeworld, plan one portal write per tick.
    function M.tick(gs)
        local path = U.safe(function() return gs["current level"]:ToString() end, nil)
        if path ~= cur_path then
            cur_path, stable_ticks, portals = path, 0, {}
            return
        end
        local here = path and regions[path]
        if not (here and cfg.homeworlds[here]) then return end
        stable_ticks = stable_ticks + 1
        if stable_ticks < STABLE_TICKS then return end
        if not jobs.ready() then return end
        for _, p in ipairs(U.safe(function() return FindAllOf(cfg.portal_class) end, nil) or {}) do
            local partner = U.valid(p) and U.fstr(p, "PartnerPortalName") or nil
            local code = partner and partner:match("^(LS%d%d%d)_LevelStart$")
            local region = code and code_to_region[code]
            local key = region and U.actor_key(p)
            -- portals are scanned only inside this game's homeworlds; return
            -- portals standing in realms are never touched. A portal whose
            -- target region is a homeworld is never locked — homeworld-to-
            -- homeworld transitions stay open (locking a homeworld's own
            -- return portal could trap the player).
            if key and not (cfg.target_homes and cfg.target_homes[region])
                and plan_portal(p, key, region) then return end
        end
    end

    --- Return a one-line heartbeat summary of keys held and portals locked.
    function M.status()
        local keys = 0
        for _, key in pairs(level_keys) do
            if held[key] then keys = keys + 1 end
        end
        local locked_here = 0
        for _, st in pairs(portals) do
            if st.locked then locked_here = locked_here + 1 end
        end
        return string.format("%senabled=%s keys=%d/%d locked_here=%d",
            cfg.prefix, tostring(enabled), keys, lockable, locked_here)
    end

    return M
end

return {new = new}