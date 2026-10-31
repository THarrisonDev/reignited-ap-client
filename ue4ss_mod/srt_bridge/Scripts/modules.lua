-- Author: Tim Harrison
-- Created: 2026-10-16
-- Updated: 2026-10-23

-- modules: the bridge's module inventory — the one host-side description of
-- every module main.lua loads and drives.
--
-- An entry is:
--   name  -- require name (also its file under Scripts/)
--   shape -- how the session reset treats it ("sender" goes back to
--            unconfigured, everything else is reset)
--   games -- the sessions whose watcher list includes it (absent = host-driven,
--            never ticked by the poll loop)
--   opts  -- build this module's init opts from the host capabilities it uses
--
-- The host capabilities are: data (`regions`, `bridge_dir`, `checks_path`,
-- `id_to_name`, `sent_checks`, `loc_id`), the plumbing hooks (`notice`,
-- `process_item`), and the AP seam `host.ap` (every server call goes through it;
-- its members are fixed by tests/lua/test_module_contract.lua).
--
-- Everything else about a module lives in the module itself, so adding one is
-- an entry here plus its file and spec. The list order is the fan-out and
-- per-game tick order; modules are independent (none reads another's state),
-- so that order is not semantic.

local SESSION = require("session_gate")

local ALL = { SESSION.SPYRO1, SESSION.SPYRO2, SESSION.SPYRO3 }

--- Build the init opts shared by every module that maps level paths to regions.
local function regions_only(host)
  return { regions = host.regions }
end

return {
  -- Host plumbing: the poll loop drives these directly, each with its own
  -- signature and trigger, so they are not part of a watcher list.
  {
    name = "checks_drop",
    shape = "plumbing",
    opts = function(host)
      return {
        connect_gate = host.ap.can_check,
        on_send = host.ap.drop_checks,
        id_to_name = host.id_to_name,
        sent_checks = host.sent_checks,
        check_path = host.checks_path,
      }
    end,
  },
  {
    name = "checkd_notice",
    shape = "plumbing",
    opts = function(host)
      return { connect_gate = host.ap.connected, on_notice = host.notice }
    end,
  },
  {
    name = "data_pkg",
    shape = "plumbing",
    opts = function(host)
      return { process = host.process_item, resolve = host.ap.item_name }
    end,
  },
  -- Goal reporting is event-driven (note_batch), not ticked.
  {
    name = "goal_watch",
    shape = "sender",
    opts = function(host)
      return { send = host.ap.goal }
    end,
  },

  -- Spyro 1
  {
    name = "spyro1.dragons",
    shape = "reconcile",
    games = { SESSION.SPYRO1 },
    opts = function(host)
      return {
        loc_id = host.loc_id,
        log_sent = host.ap.sent_line,
        sent_checks = host.sent_checks,
        send_checks = host.ap.checks,
      }
    end,
  },
  { name = "spyro1.level_locks", shape = "watcher", games = { SESSION.SPYRO1 }, opts = regions_only },
  { name = "spyro1.balloonists", shape = "watcher", games = { SESSION.SPYRO1 }, opts = regions_only },

  -- Spyro 2
  { name = "spyro2.level_locks", shape = "watcher", games = { SESSION.SPYRO2 }, opts = regions_only },
  { name = "spyro2.abilities", shape = "watcher", games = { SESSION.SPYRO2 }, opts = function() return {} end },
  { name = "spyro2.orbs", shape = "reconcile", games = { SESSION.SPYRO2 }, opts = function() return {} end },

  -- Spyro 3
  { name = "spyro3.level_locks", shape = "watcher", games = { SESSION.SPYRO3 }, opts = regions_only },
  { name = "spyro3.egg_gates", shape = "watcher", games = { SESSION.SPYRO3 }, opts = regions_only },
  { name = "spyro3.eggs_hud", shape = "reconcile", games = { SESSION.SPYRO3 }, opts = function() return {} end },
  { name = "spyro3.sparx_powers", shape = "watcher", games = { SESSION.SPYRO3 }, opts = function() return {} end },

  -- Shared across the three games
  {
    name = "fillers",
    shape = "watcher",
    games = ALL,
    opts = function(host)
      return { dir = host.bridge_dir }
    end,
  },
  {
    name = "level_tracker",
    shape = "sender",
    games = ALL,
    opts = function(host)
      return {
        send = function(region)
          return host.ap.bounce({ type = "SRTLevel", level = region }, nil, { host.ap.player_number() })
        end,
      }
    end,
  },
  {
    name = "death_link",
    shape = "sender",
    games = ALL,
    opts = function(host)
      return {
        send = function(data)
          return host.ap.bounce(data, { "DeathLink" })
        end,
        now = host.ap.server_time,
        me = host.ap.slot_name,
      }
    end,
  },
  { name = "hud_banner", shape = "display", games = ALL, opts = function() return {} end },
}
