-- Author: Tim Harrison
-- Created: 2026-10-21
-- Updated: 2026-10-23

-- The level-lock scenarios every game's module shares, parameterized by the
-- game-specific slot-data shape, keys and portals. test_level_locks.lua and
-- the Spyro 2/3 specs call run(); the per-game extras are cfg flags.

local H = require("harness")
local portals = require("portals")

local S = {}

--- Run the level-lock scenarios for one game.
--- cfg carries the module/seed/portal class, the status prefix, regions, keys
--- and status fractions, the home and realm levels, the portals list (LS code,
--- display name) with the role indices (held_portal, untouched_portal,
--- home_portal), the items each case delivers, the expected shape_* and
--- locked_here values, and the optional extras (homeworld_target, explode,
--- mid_transition).
--- @param cfg table The game's slot-data shape and expectations.
function S.run(cfg)
    H.install_game_thread()

    local world = { portals = {} }
    H.find_all_of(cfg.portal_class, function() return world.portals end)
    local level = cfg.home
    local gs = H.level_gs(function() return level end)
    local KEYS = cfg.keys

    local function sd(options, level_keys)
        return {
            included_games = { cfg.game },
            required_games = { cfg.game },
            options = { death_link = 0 },
            games = { [cfg.game] = { options = options, level_keys = level_keys } },
            seed = cfg.seed,
            slot = "P1",
        }
    end
    local SD = sd({ level_locks = 1 }, KEYS)

    --- Load a fresh module instance, fixture and portal set.
    --- @return table, table  The module and the portals it will see.
    local function fresh()
        H.new_fixture(cfg.regions)
        package.loaded[cfg.module] = nil
        H.clear_queue()
        local L = require(cfg.module)
        H.clear_log()
        L.init({ log = H.collect, regions = cfg.regions })
        level = cfg.home
        world.portals = {}
        for _, p in ipairs(cfg.portals) do
            world.portals[#world.portals + 1] = portals.new(H, p[1], p[2])
        end
        return L, world.portals
    end

    -- one async poll, then the game thread runs whatever was queued
    local function ticks(L, n)
        for _ = 1, n do H.tick(L, gs); H.pump() end
    end
    local function settle(L) ticks(L, 12) end

    local scenarios = {}
    local function scenario(name, fn) scenarios[#scenarios + 1] = { name, fn } end

    scenario("disabled when level_locks is off", function()
        local L, P = fresh()
        L.configure(sd({ level_locks = 0 }, {}))
        L.note_item(cfg.off_item)
        settle(L)
        assert(P[1].props.EnableTransport == true and P[1].remakes == 0 and H.queued() == 0)
    end)

    scenario("old top-level slot data shape does not enable locks", function()
        local L, P = fresh()
        L.configure({ options = { level_locks = 1 }, level_keys = KEYS })
        L.note_item(cfg.off_item)
        settle(L)
        assert(P[1].props.EnableTransport == true and P[1].remakes == 0 and H.queued() == 0)
        assert(L.status() == cfg.status_prefix .. "enabled=false keys=0/0 locked_here=0",
            "got " .. L.status())
    end)

    scenario("games." .. cfg.game .. " slot data shape enables locks", function()
        local L, P = fresh()
        L.configure(SD)
        L.note_item(cfg.key_item)
        settle(L)
        assert(L.status():match("^" .. cfg.status_prefix .. "enabled=true keys=" .. cfg.shape_keys),
            "got " .. L.status())
        for _, i in ipairs(cfg.shape_locked) do
            assert(P[i].props.EnableTransport == false and P[i].visible() == "LOCKED")
        end
    end)

    scenario("unprefixed key names do not unlock", function()
        local L, P = fresh()
        L.configure(SD)
        L.note_item(cfg.unprefixed)
        settle(L)
        assert(P[1].props.EnableTransport == false and P[1].visible() == "LOCKED")
    end)

    scenario("waits for the item backlog, then the grace period", function()
        local L, P = fresh()
        L.configure(SD)
        settle(L)
        assert(P[1].props.EnableTransport == true, "locked before backlog/grace")
        H.advance(3)
        ticks(L, 1)
        assert(P[1].props.EnableTransport == false, "grace expiry should lock")
    end)

    scenario("locked portal: no transport, no preview, LOCKED visible", function()
        local L, P = fresh()
        L.configure(SD)
        L.note_item(cfg.held_item)
        settle(L)
        assert(P[1].props.EnableTransport == false and P[1].props.PreloadEnabled == false)
        assert(P[1].text() == "LOCKED" and P[1].visible() == "LOCKED" and P[1].remakes == 1,
            "got text=" .. P[1].text() .. " visible=" .. P[1].visible())
        assert(P[cfg.held_portal].props.EnableTransport == true and P[cfg.held_portal].remakes == 0,
            "held key stays open")
        assert(P[cfg.untouched_portal].props.EnableTransport == true and P[cfg.untouched_portal].remakes == 0,
            "level without a key untouched")
        for _, i in ipairs(cfg.also_locked) do
            assert(P[i].props.EnableTransport == false and P[i].visible() == "LOCKED")
        end
        if cfg.home_portal then
            assert(P[cfg.home_portal].props.EnableTransport == true and P[cfg.home_portal].remakes == 0,
                "a portal targeting a homeworld is never locked (TARGET_HOMES)")
        end
    end)

    scenario("several locks queue one game-thread job at a time", function()
        local L, P = fresh()
        L.configure(SD)
        L.note_item(cfg.key_item)
        ticks(L, 7)
        for _ = 1, 5 do H.tick(L, gs) end -- async polls while the game thread is busy
        assert(H.queued() == 1, "expected 1 queued job, got " .. H.queued())
        assert(P[1].props.EnableTransport == true and P[2].props.EnableTransport == true,
            "nothing may be written before the game thread runs the job")
        H.pump()
        local locked = (P[1].props.EnableTransport == false and 1 or 0)
            + (P[2].props.EnableTransport == false and 1 or 0)
        assert(locked == 1, "one job locks exactly one portal")
        ticks(L, 1)
        assert(P[1].props.EnableTransport == false and P[2].props.EnableTransport == false,
            "next poll locks the other")
        assert(P[1].visible() == "LOCKED" and P[2].visible() == "LOCKED")
    end)

    if cfg.homeworld_target then
        local t = cfg.homeworld_target
        scenario("TARGET_HOMES: a portal targeting " .. t.target .. " never locks without its key", function()
            local L = fresh()
            level = t.level
            world.portals = {
                portals.new(H, t.portals[1][1], t.portals[1][2]),
                portals.new(H, t.portals[2][1], t.portals[2][2]),
            }
            L.configure(sd({ level_locks = 1 }, t.keys))
            H.advance(3) -- past the connect grace period (no backlog items in this test)
            settle(L)
            assert(world.portals[1].props.EnableTransport == false and world.portals[1].visible() == "LOCKED",
                "a realm portal with an unheld key must lock")
            assert(world.portals[2].props.EnableTransport == true and world.portals[2].remakes == 0,
                "the homeworld-target portal must stay open while its key is not held")
        end)
    end

    scenario("game re-enable is re-locked and LOCKED re-revealed without a rebuild", function()
        local L, P = fresh()
        L.configure(SD)
        L.note_item(cfg.held_item)
        settle(L)
        H.as_game(function() P[1].actor:setPortalEnabled(true) end) -- exit-from-portal sequence finishing
        ticks(L, 1)
        assert(P[1].props.EnableTransport == false and P[1].remakes == 1)
        assert(P[1].visible() == "LOCKED", "got visible=" .. P[1].visible())
    end)

    if cfg.mid_transition then
        scenario("a portal disabled by the game before the job runs is left alone", function()
            local L, P = fresh()
            L.configure(SD)
            L.note_item(cfg.held_item)
            ticks(L, 8)
            H.tick(L, gs) -- decides to lock, queues the job
            assert(H.queued() == 1, "expected the lock job to be queued")
            H.as_game(function() P[1].actor:setPortalEnabled(false) end) -- enter transition started
            H.pump()
            assert(P[1].remakes == 0, "must not relabel a portal mid-transition")
        end)
    end

    scenario("receiving the key unlocks and restores the visible name", function()
        local L, P = fresh()
        L.configure(SD)
        L.note_item(cfg.held_item)
        settle(L)
        L.note_item(cfg.unlock_item)
        ticks(L, 1)
        assert(P[1].props.EnableTransport == true and P[1].props.PreloadEnabled == true)
        assert(P[1].text() == cfg.portals[1][2] and P[1].visible() == cfg.visible_name and P[1].remakes == 2,
            "got text=" .. P[1].text() .. " visible=" .. P[1].visible())
        if cfg.unlocked_other then
            assert(P[cfg.unlocked_other].props.EnableTransport == false,
                "a key for one portal does not unlock the other")
        end
        ticks(L, 5)
        assert(P[1].remakes == 2, "no further rebuilds once unlocked")
    end)

    scenario("a job that never runs is abandoned after the timeout", function()
        local L = fresh()
        L.configure(SD)
        L.note_item(cfg.key_item)
        ticks(L, 8) -- first poll only records the level; 7 more reach STABLE_TICKS - 1
        H.tick(L, gs)
        assert(H.queued() == 1, "expected the lock job to be queued")
        H.advance(4)
        H.tick(L, gs)
        assert(H.queued() == 1, "still waiting inside the timeout")
        H.advance(1)
        H.tick(L, gs)
        assert(H.queued() == 2, "timed-out job should be abandoned and a new one submitted")
        assert(H.logged("never finished"), "abandoning a job should be logged")
    end)

    if cfg.explode then
        scenario("a failing job backs off instead of resubmitting every tick", function()
            local L, P = fresh()
            L.configure(SD)
            L.note_item(cfg.held_item)
            P[1].explode = true
            settle(L)
            ticks(L, 8)
            local function errors()
                return H.count_logged("ERROR lock " .. cfg.portals[1][2] .. ": ", true)
            end
            assert(errors() == 1, "expected 1 ERROR inside the backoff, got " .. errors())
            H.advance(4)
            ticks(L, 4)
            assert(errors() == 1, "resubmitted inside the backoff")
            H.advance(1)
            ticks(L, 1)
            assert(errors() == 2, "expected one retry after the backoff, got " .. errors())
            P[1].explode = false
            H.advance(5)
            ticks(L, 1)
            assert(P[1].props.EnableTransport == false and P[1].visible() == "LOCKED", "lock never landed")
        end)
    end

    scenario("no game-thread API means no writes at all", function()
        ExecuteInGameThread = nil
        local L, P = fresh()
        L.configure(SD)
        L.note_item(cfg.key_item)
        settle(L)
        assert(P[1].props.EnableTransport == true and P[1].remakes == 0)
        assert(L.status():match("^" .. cfg.status_prefix .. "enabled=false"))
    end)

    scenario("no writes outside homeworlds or before the level settles", function()
        local L, P = fresh()
        L.configure(SD)
        L.note_item(cfg.held_item)
        ticks(L, 5)
        assert(P[1].props.EnableTransport == true, "wrote before the stable-level gate")
        level = cfg.realm
        settle(L)
        assert(P[1].props.EnableTransport == true and P[1].remakes == 0, "wrote in a non-homeworld level")
    end)

    scenario("reconfigure for a new seed forgets old keys", function()
        local L, P = fresh()
        L.configure(SD)
        L.note_item(cfg.unlock_item)
        settle(L)
        assert(P[1].props.EnableTransport == true)
        L.configure(SD)
        L.note_item(cfg.held_item)
        ticks(L, 1)
        assert(P[1].props.EnableTransport == false and P[1].visible() == "LOCKED")
    end)

    scenario("status reports held keys and locked portals", function()
        local L = fresh()
        L.configure(SD)
        L.note_item(cfg.held_item)
        settle(L)
        local s = L.status()
        assert(s == cfg.status_prefix .. "enabled=true keys=" .. cfg.keys_fraction
            .. " locked_here=" .. cfg.locked_here, "got " .. s)
    end)

    for _, s in ipairs(scenarios) do H.test(s[1], s[2]) end
    H.finish()
end

return S
