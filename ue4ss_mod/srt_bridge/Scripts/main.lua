-- SRTAP bridge: the Archipelago client that runs inside Spyro Reignited via
-- UE4SS. It owns the single AP connection, opens a session per picked save,
-- and dispatches the per-game watchers. Config, logging and BRIDGE_DIR live in
-- logger.lua; session_gate.lua decides when a session opens. See
-- docs/game_gates.md and docs/game_state_control.md.

local OK, AP = pcall(require, "lua-apclientpp")

-- Put the Scripts/ dir on package.path before the first require.
do
  local src = debug and debug.getinfo and debug.getinfo(1, "S")
  local dir = src and src.source and src.source:match("^@(.*[/\\])")
  if dir then
    package.path = package.path .. ";" .. dir .. "?.lua"
  end
end
local U = require("util")
local L = require("logger")
local log_info, log_error, log_debug = L.log_info, L.log_error, L.log_debug
local CFG = L.cfg
local BRIDGE_DIR = L.bridge_dir

-- Per-module leveled loggers: the tag prefixes every line, and warn/error
-- reach the console without debug=1.
local DROP_LOG = L.tagged("[DROP]")
local DRAGONS_LOG = L.tagged("[DRAGONS]")
local LOCKS_LOG = L.tagged("[LOCKS]")
local BALLOONS_LOG = L.tagged("[BALLOON]")
local S2LOCKS_LOG = L.tagged("[LOCKS2]")
local S3LOCKS_LOG = L.tagged("[LOCKS3]")
local EGGGATES_LOG = L.tagged("[EGGS3]")
local FILLERS_LOG = L.tagged("[FILLERS]")
local ABILITIES_LOG = L.tagged("[ABILITIES]")
local ORBS2_LOG = L.tagged("[ORBS2]")
local EGGHUD_LOG = L.tagged("[EGGHUD]")
local SPARX_LOG = L.tagged("[SPARX]")
local BANNER_LOG = L.tagged("[BANNER]")
local DATAPKG_LOG = L.tagged("[DATAPKG]")
local SESSION_LOG = L.tagged("[SESSION]")
local GOAL_LOG = L.tagged("[GOAL]")
local DEATHLINK_LOG = L.tagged("[DEATHLINK]")
local LEVELTAB_LOG = L.tagged("[LEVELTAB]")

local CHECKD_EXE = BRIDGE_DIR .. "srtap_checkd.exe"
--- Start the checkd save scanner, unless spawn is disabled in config.
local function spawn_checkd()
  if CFG.spawn_checkd == "0" then
    log_debug("checkd: spawn disabled in config")
    return
  end
  local f = io.open(CHECKD_EXE, "r")
  if not f then
    log_error("checkd not found at " .. CHECKD_EXE .. " (collected checks will not be sent)")
    return
  end
  f:close()
  -- The start detaches immediately; the daemon self-dedupes via checkd.hb.
  local ok, err = pcall(function()
    os.execute('start "srtapd" /b "' .. CHECKD_EXE .. '"')
  end)
  log_debug("checkd spawn: ok=" .. tostring(ok) .. " err=" .. tostring(err))
end

local CHECKS_DROP = BRIDGE_DIR .. "checks.json"
-- A session file left by a crashed run would point checkd at a save the
-- player hasn't picked yet.
local SESSION_FILE = BRIDGE_DIR .. "session.txt"
os.remove(SESSION_FILE)

if not OK then
  log_error("FATAL: lua-apclientpp not loadable: " .. tostring(AP))
  return
end

-- session_gate.lua is core, like lua-apclientpp: without it there is no
-- useful degraded mode, so a load failure is one FATAL line and the mod
-- stops here before any module or LoopAsync is wired.
local okSG, SESSION = pcall(require, "session_gate")
if not okSG or type(SESSION) ~= "table" then
  log_error(
    "FATAL: session gate: require('session_gate') failed (" .. tostring(SESSION) .. ") — bridge stays offline"
  )
  return
end
SESSION.init({ log = SESSION_LOG })

-- ---------------------------------------------------------------------------
-- Runtime state
-- ---------------------------------------------------------------------------
local ap = nil -- The lua-apclientpp client (async thread only).
local connected = false -- The slot_connected..socket_disconnected window.
local name_to_id = {} -- "Spyro 1: Region: Free Nestor" -> id.
local id_to_name = {} -- id -> fully-qualified name.
local sent_checks = {} -- id -> true (ever sent this session; shared with spyro1/dragons.lua).
local session_game = nil -- Game index of the open session (0 = Spyro 1, 1 = Spyro 2, 2 = Spyro 3).
local checks_blocked = false -- This session's game isn't in the seed: never send its checks.
local BANNER = nil -- hud_banner module; assigned below, read by sent_line at call time.

local client_version = { 0, 6, 7 }
local items_handling = 7

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
local safe = U.safe
local valid = U.valid

--- Return the live FalconGameState, or nil when it is not valid.
local function game_state()
  local gs = FindFirstOf("FalconGameState_C")
  if not valid(gs) then
    return nil
  end
  return gs
end

--- Require an optional Scripts/ module, falling back to stub on failure.
--- `prefix` is the exact error-line head, kept stable per module for log
--- greps; every field main reads must exist on the stub (test_main_load.lua
--- drives main with every optional module failing).
--- @param name string
--- @param prefix string
--- @param what string Fallback description appended to the error line.
--- @param stub table
--- @return table
local function load_module(name, prefix, what, stub)
  local ok, mod = pcall(require, name)
  if ok and type(mod) == "table" then
    return mod
  end
  log_error(prefix .. " (" .. tostring(mod) .. ") — " .. what)
  return stub
end

--- Return the location id for a fully-qualified name from slot_data.
--- @param name string
--- @return number|nil
local function loc_id(name)
  return name_to_id[name]
end

--- Return sd.games.spyro1 when present, else an empty table.
--- @param sd table|nil
--- @return table
local function s1_slot_data(sd)
  return (sd and type(sd.games) == "table" and type(sd.games.spyro1) == "table") and sd.games.spyro1 or {}
end

-- Location id -> {item, to} from the connect-time LocationScouts. `to` is
-- nil when the item is ours. Sends log before the scout reply arrives.
local scouted = {}

-- BANNER is assigned before any send can fire, so the closure reads it at
-- call time without a forward-declaration warning.
--- Build the log/banner line for a sent location check.
--- @param id number
--- @return string
local function sent_line(id)
  local line = "Sent: " .. (id_to_name[id] or ("location " .. id))
  local s = scouted[id]
  if not s then
    return line
  end
  if s.to then
    BANNER.note_sent("To " .. s.to .. ": " .. s.item)
    return line .. " -> " .. s.item .. " for " .. s.to
  end
  return line .. " -> your " .. s.item
end

-- ---------------------------------------------------------------------------
-- Module loading (all through load_module; init calls stay at their sites)
-- ---------------------------------------------------------------------------
-- checks_drop.lua ingests the checkd drop: the Go daemon writes checks.json
-- {"seq":N,"checks":[ids],"names":[...]}; we LocationChecks the surviving ids
-- over the single AP connection. The drop format is owned by checkd.
local CHECKSDROP = load_module(
  "checks_drop",
  "checks_drop: require failed",
  "checkd drop ingestion unavailable",
  { init = function() end, reset = function() end, tick = function() end }
)
CHECKSDROP.init({
  connect_gate = function()
    return connected and ap ~= nil and not checks_blocked
  end,
  log = DROP_LOG,
  on_send = function(ids)
    local okS, err = pcall(function()
      ap:LocationChecks(ids)
    end)
    if okS then
      for _, id in ipairs(ids) do
        log_info(sent_line(id))
      end
    else
      log_debug("LocationChecks via drop FAILED: " .. tostring(err) .. " (retry next tick)")
    end
    return okS
  end,
  id_to_name = id_to_name,
  sent_checks = sent_checks,
  check_path = CHECKS_DROP,
})

-- Level path -> region name, from the generated regions.lua. It is
-- generated by scripts/gen_locations.py from the apworld's Locations.py and
-- level_paths.py, so never hand-edit it (audit_locations.py guards drift).
-- It ships beside this file in Scripts/ and is already on package.path.
local MAP_PATH_TO_REGION = {}
do
  local okR, regions = pcall(require, "regions")
  if okR and type(regions) == "table" then
    MAP_PATH_TO_REGION = regions
    local n = 0
    for _ in pairs(regions) do
      n = n + 1
    end
    log_debug("region table: loaded " .. n .. " paths from regions.lua")
  else
    log_error(
      "FATAL region table: require('regions') failed ("
        .. tostring(regions)
        .. ") — dragon reconcile + gem region resolution will be inert"
    )
  end
end

-- Spyro 1 dragons (spyro1/dragons.lua): the dragon watcher (named checks from
-- Collectable_Dragon_C actors) and the signed debug_extra_dragons reconcile.
-- send_checks wraps the single AP connection; sent_checks is shared with
-- checks_drop above.
local DRAGONS =
  load_module("spyro1.dragons", "dragons: require('spyro1.dragons') failed", "dragon watcher + reconcile unavailable", {
    init = function() end,
    configure = function() end,
    note_item = function()
      return false
    end,
    is_dragon = function()
      return false
    end,
    received = function()
      return 0
    end,
    last_extra = function()
      return nil
    end,
    arm_backlog = function() end,
    reset_received = function() end,
    note_disconnected = function() end,
    tick = function() end,
    reset = function() end,
    status = function()
      return "unavailable"
    end,
  })
DRAGONS.init({
  log = DRAGONS_LOG,
  regions = MAP_PATH_TO_REGION,
  loc_id = loc_id,
  log_sent = function(id)
    log_info(sent_line(id))
  end,
  sent_checks = sent_checks,
  send_checks = function(ids)
    if not ap then
      return false, "not connected"
    end
    return pcall(function()
      ap:LocationChecks(ids)
    end)
  end,
})

-- Spyro 1 level locks (spyro1/level_locks.lua): portals stay locked until
-- their AP key item arrives.
local LOCKS =
  load_module("spyro1.level_locks", "level locks: require('spyro1.level_locks') failed", "portals stay vanilla", {
    init = function() end,
    configure = function() end,
    note_item = function() end,
    tick = function() end,
    status = function()
      return "unavailable"
    end,
  })
LOCKS.init({ log = LOCKS_LOG, regions = MAP_PATH_TO_REGION })

-- Spyro 1 balloonist gates (spyro1/balloonists.lua): Marco's GoalValue is
-- raised to the seed's gate_requirements.
local BALLOONS = load_module(
  "spyro1.balloonists",
  "balloonists: require('spyro1.balloonists') failed",
  "balloonist gates stay vanilla",
  {
    init = function() end,
    configure = function() end,
    tick = function() end,
    status = function()
      return "unavailable"
    end,
  }
)
BALLOONS.init({ log = BALLOONS_LOG, regions = MAP_PATH_TO_REGION })

-- Spyro 2 level locks (spyro2/level_locks.lua): portals stay locked until
-- their AP key item arrives.
local S2LOCKS =
  load_module("spyro2.level_locks", "level locks: require('spyro2.level_locks') failed", "portals stay vanilla", {
    init = function() end,
    configure = function() end,
    note_item = function() end,
    tick = function() end,
    status = function()
      return "unavailable"
    end,
  })
S2LOCKS.init({ log = S2LOCKS_LOG, regions = MAP_PATH_TO_REGION })

-- Spyro 3 level locks (spyro3/level_locks.lua): portals stay locked until
-- their AP key item arrives.
local S3LOCKS =
  load_module("spyro3.level_locks", "level locks: require('spyro3.level_locks') failed", "portals stay vanilla", {
    init = function() end,
    configure = function() end,
    note_item = function() end,
    tick = function() end,
    status = function()
      return "unavailable"
    end,
  })
S3LOCKS.init({ log = S3LOCKS_LOG, regions = MAP_PATH_TO_REGION })

-- Egg gates (spyro3/egg_gates.lua): Spyro 3's egg portals follow received
-- Dragon Egg items (the EggRequirement re-tune).
local EGGGATES =
  load_module("spyro3.egg_gates", "egg gates: require('spyro3.egg_gates') failed", "egg portals stay vanilla", {
    init = function() end,
    configure = function() end,
    note_item = function() end,
    tick = function() end,
    status = function()
      return "unavailable"
    end,
  })
EGGGATES.init({ log = EGGGATES_LOG, regions = MAP_PATH_TO_REGION })

-- Filler items (fillers.lua): Extra Life and Spyro looks.
local FILLERS = load_module("fillers", "fillers: require('fillers') failed", "filler items do nothing", {
  init = function() end,
  configure = function() end,
  note_item = function() end,
  tick = function() end,
  status = function()
    return "unavailable"
  end,
})
FILLERS.init({ log = FILLERS_LOG, regions = MAP_PATH_TO_REGION, dir = BRIDGE_DIR })

-- Ability items (spyro2/abilities.lua): Spyro 2 Money Bags abilities.
local ABILITIES =
  load_module("spyro2.abilities", "abilities: require('spyro2.abilities') failed", "ability items do nothing", {
    init = function() end,
    configure = function() end,
    note_item = function() end,
    tick = function() end,
    status = function()
      return "unavailable"
    end,
  })
ABILITIES.init({ log = ABILITIES_LOG, regions = MAP_PATH_TO_REGION })

-- Orb reconcile (spyro2/orbs.lua): the game's orb counter follows received
-- Orb items under spyro2_orb_shuffle (signed debug_extra_orbs drive).
local ORBS2 = load_module("spyro2.orbs", "orbs: require('spyro2.orbs') failed", "orb counter stays vanilla", {
  init = function() end,
  configure = function() end,
  note_item = function()
    return false
  end,
  is_orb = function()
    return false
  end,
  received = function()
    return 0
  end,
  last_extra = function()
    return nil
  end,
  arm_backlog = function() end,
  reset_received = function() end,
  note_disconnected = function() end,
  tick = function() end,
  reset = function() end,
  status = function()
    return "unavailable"
  end,
})
ORBS2.init({ log = ORBS2_LOG })

-- Egg HUD reconcile (spyro3/eggs_hud.lua): the S3 egg HUD/Guide Book count
-- follows received Dragon Egg items under spyro3_egg_shuffle (signed
-- debug_extra drive). Display only; it never opens a gate (egg_gates.lua's
-- EggRequirement re-tune does that independently).
local EGGHUD =
  load_module("spyro3.eggs_hud", "egg hud: require('spyro3.eggs_hud') failed", "egg HUD counter stays vanilla", {
    init = function() end,
    configure = function() end,
    note_item = function()
      return false
    end,
    is_egg = function()
      return false
    end,
    received = function()
      return 0
    end,
    last_extra = function()
      return nil
    end,
    arm_backlog = function() end,
    reset_received = function() end,
    note_disconnected = function() end,
    tick = function() end,
    reset = function() end,
    status = function()
      return "unavailable"
    end,
  })
EGGHUD.init({ log = EGGHUD_LOG })

-- Sparx power items (spyro3/sparx_powers.lua): Spyro 3 Sparx realm rewards.
local SPARX = load_module(
  "spyro3.sparx_powers",
  "sparx powers: require('spyro3.sparx_powers') failed",
  "Sparx power items do nothing",
  {
    init = function() end,
    configure = function() end,
    note_item = function() end,
    tick = function() end,
    status = function()
      return "unavailable"
    end,
  }
)
SPARX.init({ log = SPARX_LOG, regions = MAP_PATH_TO_REGION })

-- HUD banner (hud_banner.lua): shows each received item on the fanfare
-- banner ("Rescued {name}" window) as "You found: <item>". sent_line feeds
-- outgoing items ("To <player>: <item>") into the same banner, received-first.
BANNER = load_module(
  "hud_banner",
  "hud banner: require('hud_banner') failed",
  "received items will not show on the HUD banner",
  {
    init = function() end,
    note_item = function() end,
    note_sent = function() end,
    tick = function() end,
    status = function()
      return "unavailable"
    end,
  }
)
BANNER.init({ log = BANNER_LOG })

-- Level tracker (level_tracker.lua): bounces the current level (region) to
-- the room, targeted at this slot, so PopTracker follows the player.
local LEVELTAB = load_module(
  "level_tracker",
  "level tracker: require('level_tracker') failed",
  "PopTracker will not follow level changes",
  {
    init = function() end,
    configure = function() end,
    tick = function() end,
    status = function()
      return "unavailable"
    end,
  }
)
LEVELTAB.init({
  log = LEVELTAB_LOG,
  regions = MAP_PATH_TO_REGION,
  send = function(region)
    if not ap then
      return false, "not connected"
    end
    local okB, r = pcall(function()
      return ap:Bounce({ type = "SRTLevel", level = region }, nil, { ap:get_player_number() }, nil)
    end)
    return okB and r == true, r
  end,
})

-- Data-package backlog (data_pkg.lua): the first ReceivedItems batch arrives
-- before the AP data package has loaded, so its names resolve to "Unknown",
-- and the server never re-delivers it.
local DATAPKG = load_module(
  "data_pkg",
  "data pkg: require('data_pkg') failed",
  "first-batch items stay unprocessed",
  { init = function() end, reset = function() end, note = function() end, tick = function() end }
)

-- Goal reporting (goal_watch.lua): GOAL once every required game's goal
-- event item has been received.
local GOALWATCH =
  load_module("goal_watch", "goal watch: require('goal_watch') failed", "goal completion is not reported", {
    init = function() end,
    configure = function() end,
    note_batch = function()
      return false
    end,
    status = function()
      return "unavailable"
    end,
    sent = function()
      return false
    end,
  })
GOALWATCH.init({
  log = GOAL_LOG,
  send = function()
    if not ap then
      return false
    end
    return pcall(function()
      ap:StatusUpdate(AP.ClientStatus.GOAL)
    end)
  end,
})

-- DeathLink (death_link.lua): bounces Spyro's deaths and applies incoming
-- death bounces when the slot's death_link option is on.
local DEATHLINK = load_module("death_link", "death link: require('death_link') failed", "DeathLink inactive", {
  init = function() end,
  configure = function() end,
  on_bounced = function() end,
  tick = function() end,
  status = function()
    return "unavailable"
  end,
})
DEATHLINK.init({
  log = DEATHLINK_LOG,
  send = function(data)
    if not ap then
      return false
    end
    local okB, r = pcall(function()
      return ap:Bounce(data, nil, nil, { "DeathLink" })
    end)
    return okB and r == true
  end,
  now = function()
    return safe(function()
      return ap:get_server_time()
    end, 0)
  end,
  me = function()
    return safe(function()
      return ap:get_slot()
    end, "?")
  end,
})

-- Per-game logic runs only while the open session is that game's save.
--- Return whether the open session is a Spyro 1 save.
local function s1_session()
  return session_game ~= nil and session_game == SESSION.SPYRO1
end

--- Return whether the open session is a Spyro 2 save.
local function s2_session()
  return session_game ~= nil and session_game == SESSION.SPYRO2
end

--- Return whether the open session is a Spyro 3 save.
local function s3_session()
  return session_game ~= nil and session_game == SESSION.SPYRO3
end

-- Per-session-type watcher dispatch for the poll loop. One game_state()
-- fetch feeds the whole chain. Spyro 1 interleaves: each tick is followed
-- by its own heartbeat. Spyro 2 and Spyro 3 batch: every tick first, then
-- every heartbeat.
local WATCHERS = {
  [SESSION.SPYRO1] = {
    interleave = true,
    ticks = { DRAGONS, LOCKS, BALLOONS, FILLERS, DEATHLINK, LEVELTAB, BANNER },
    hbs = {
      { mod = DRAGONS, tag = "[DRAGONS] hb: " },
      { mod = LOCKS, tag = "[LOCKS] hb: " },
      { mod = BALLOONS, tag = "[BALLOON] hb: " },
      { mod = FILLERS, tag = "[FILLERS] hb: " },
      { mod = DEATHLINK, tag = "[DEATHLINK] hb: " },
      { mod = LEVELTAB, tag = "[LEVELTAB] hb: " },
      { mod = BANNER, tag = "[BANNER] hb: " },
    },
  },
  [SESSION.SPYRO2] = {
    ticks = { ABILITIES, ORBS2, FILLERS, S2LOCKS, DEATHLINK, LEVELTAB, BANNER },
    hbs = {
      { mod = ABILITIES, tag = "[ABILITIES] hb: " },
      { mod = ORBS2, tag = "[ORBS2] hb: " },
      { mod = FILLERS, tag = "[FILLERS] hb (spyro2): " },
      { mod = S2LOCKS, tag = "[LOCKS2] hb: " },
      { mod = DEATHLINK, tag = "[DEATHLINK] hb (spyro2): " },
      { mod = LEVELTAB, tag = "[LEVELTAB] hb (spyro2): " },
      { mod = BANNER, tag = "[BANNER] hb (spyro2): " },
    },
  },
  [SESSION.SPYRO3] = {
    ticks = { EGGGATES, EGGHUD, SPARX, FILLERS, S3LOCKS, DEATHLINK, LEVELTAB, BANNER },
    hbs = {
      { mod = EGGGATES, tag = "[EGGS3] hb: " },
      { mod = EGGHUD, tag = "[EGGHUD] hb: " },
      { mod = SPARX, tag = "[SPARX] hb: " },
      { mod = BANNER, tag = "[BANNER] hb: " },
      { mod = FILLERS, tag = "[FILLERS] hb (spyro3): " },
      { mod = S3LOCKS, tag = "[LOCKS3] hb: " },
      { mod = DEATHLINK, tag = "[DEATHLINK] hb (spyro3): " },
      { mod = LEVELTAB, tag = "[LEVELTAB] hb (spyro3): " },
    },
  },
}

-- ReceivedItems is cumulative: every packet re-delivers index 0..n, so
-- consumers are exact-once per AP item index.
local processed_indices = {}
-- process_item is the single fan-out for one item, inline or via the
-- data-package backlog replay.
--- Fan one received item out to every interested module, once per index.
--- @param name string
--- @param index number|nil
local function process_item(name, index)
  if index ~= nil then
    if processed_indices[index] then
      return
    end
    processed_indices[index] = true
  end
  LOCKS.note_item(name)
  S2LOCKS.note_item(name)
  S3LOCKS.note_item(name)
  EGGGATES.note_item(name)
  FILLERS.note_item(name, index)
  ABILITIES.note_item(name, index)
  ORBS2.note_item(name, index)
  EGGHUD.note_item(name, index)
  SPARX.note_item(name, index)
  DRAGONS.note_item(name, index)
  BANNER.note_item(name)
end

DATAPKG.init({
  log = DATAPKG_LOG,
  process = process_item,
  resolve = function(item_id)
    if not ap then
      return nil
    end
    return safe(function()
      return ap:get_item_name(item_id, CFG.game)
    end, nil)
  end,
})

-- ---------------------------------------------------------------------------
-- AP handlers
-- ---------------------------------------------------------------------------
-- NetworkItem on ReceivedItems: player is the slot whose world held the
-- item, and location is where in that world (<= 0 for server grants and
-- starting items).
--- Build the log line describing where a received item came from.
--- @param info table NetworkItem.
--- @param iname string Resolved item name.
--- @return string
local function received_line(info, iname)
  local line = "Received: " .. iname
  local p = info.player
  local me = safe(function()
    return ap:get_player_number()
  end, nil)
  local game = safe(function()
    return ap:get_player_game(p)
  end, nil)
  local where = (type(info.location) == "number" and info.location > 0)
      and safe(function()
        return ap:get_location_name(info.location, game)
      end, nil)
    or nil
  if p == me then
    return line .. (where and (" (found at " .. where .. ")") or "")
  end
  local from = (p == 0) and "the server"
    or safe(function()
      return ap:get_player_alias(p)
    end, "player " .. tostring(p))
  return line .. " from " .. from .. (where and (" at " .. where) or "")
end

-- NetworkItem on LocationInfo: player is the receiver of the item.
--- Cache the connect-time LocationScouts reply that names each check's item/receiver.
--- @param items table|nil
local function on_location_info(items)
  local me = safe(function()
    return ap:get_player_number()
  end, nil)
  local n = 0
  for _, info in ipairs(items or {}) do
    local game = safe(function()
      return ap:get_player_game(info.player)
    end, nil)
    scouted[info.location] = {
      item = safe(function()
        return ap:get_item_name(info.item, game)
      end, "?"),
      to = info.player ~= me and safe(function()
        return ap:get_player_alias(info.player)
      end, "player " .. tostring(info.player)) or nil,
    }
    n = n + 1
  end
  log_debug("location scouts: cached " .. n .. " locations")
end

--- Log a ReceivedItems batch, feed the data-package backlog, re-arm the
--- reconciles and hand the batch to goal watch.
--- @param received table|nil
local function on_items_received(received)
  local names = {}
  local dragons_this_batch = 0
  local orbs_this_batch = 0
  local eggs_this_batch = 0
  for _, info in ipairs(received or {}) do
    local iname = safe(function()
      return ap:get_item_name(info.item, CFG.game)
    end, "?")
    names[#names + 1] = iname
    log_info(received_line(info, iname))
    DATAPKG.note(iname, info.index, info.item)
    if DRAGONS.is_dragon(iname) then
      dragons_this_batch = dragons_this_batch + 1
    end
    if ORBS2.is_orb(iname) then
      orbs_this_batch = orbs_this_batch + 1
    end
    if EGGHUD.is_egg(iname) then
      eggs_this_batch = eggs_this_batch + 1
    end
  end
  log_debug("items received: " .. #names .. " (" .. table.concat(names, ", ") .. ")")
  -- Reconnect: the cumulative backlog recount re-arms the reconciles.
  DRAGONS.arm_backlog()
  ORBS2.arm_backlog()
  EGGHUD.arm_backlog()
  if dragons_this_batch > 0 then
    log_debug(
      string.format(
        "[RECONCILE] Dragon items this batch: %d (running received=%d, last_extra=%s)",
        dragons_this_batch,
        DRAGONS.received(),
        tostring(DRAGONS.last_extra())
      )
    )
  end
  if orbs_this_batch > 0 then
    log_debug(
      string.format(
        "[RECONCILE] Orb items this batch: %d (running received=%d, last_extra=%s)",
        orbs_this_batch,
        ORBS2.received(),
        tostring(ORBS2.last_extra())
      )
    )
  end
  if eggs_this_batch > 0 then
    log_debug(
      string.format(
        "[RECONCILE] Dragon Egg items this batch: %d (running received=%d, last_extra=%s)",
        eggs_this_batch,
        EGGHUD.received(),
        tostring(EGGHUD.last_extra())
      )
    )
  end
  GOALWATCH.note_batch(received)
end

--- Handle slot connect: reset stale per-seed state, load location names,
--- scout every location and configure every module with the slot data.
--- @param sd table Slot data.
local function on_slot_connected(sd)
  log_info("Connected to " .. CFG.host .. " as " .. CFG.slot)
  -- A reconnect to a different seed makes the session check state stale.
  for k in pairs(sent_checks) do
    sent_checks[k] = nil
  end
  -- Cumulative ReceivedItems re-uses indexes for different items on a new
  -- seed, so the per-index once-guard must reset with the check state.
  processed_indices = {}
  -- The dragon count must recount exactly once: a mid-session reconnect
  -- re-delivers the whole backlog, and without the reset every Dragon
  -- counts twice and the signed drive over-writes the counter.
  DRAGONS.reset_received()
  ORBS2.reset_received()
  EGGHUD.reset_received()
  local n2i = sd.locationNameToId or {}
  local n = 0
  for k, v in pairs(n2i) do
    name_to_id[k] = v
    id_to_name[v] = k
    n = n + 1
  end
  log_debug("locationNameToId loaded: " .. n .. " entries")
  -- Scout every location once so "Sent:" lines can name the item and receiver.
  scouted = {}
  local scout_ids = {}
  for id in pairs(id_to_name) do
    scout_ids[#scout_ids + 1] = id
  end
  if #scout_ids > 0 then
    local okSc, errSc = pcall(function()
      ap:LocationScouts(scout_ids, 0)
    end)
    log_debug("LocationScouts(" .. #scout_ids .. "): ok=" .. tostring(okSc) .. " err=" .. tostring(errSc))
  end
  local blocked = not SESSION.is_included(sd, session_game)
  if blocked and not checks_blocked then
    log_info(
      "This slot doesn't include " .. SESSION.game_name(session_game) .. " - checks from this save won't be sent"
    )
  end
  checks_blocked = blocked
  GOALWATCH.configure(sd)
  local opts = s1_slot_data(sd).options or {}
  log_debug(
    "spyro1 options: dragon_shuffle=" .. tostring(opts.dragon_shuffle) .. " egg_shuffle=" .. tostring(opts.egg_shuffle)
  )
  if session_game == SESSION.SPYRO3 then
    log_debug("spyro3 session: gem checks, fillers, S3 level locks, egg gates, Sparx powers")
  end
  DRAGONS.configure(sd, s1_session())
  LOCKS.configure(sd)
  BALLOONS.configure(sd)
  S2LOCKS.configure(sd)
  S3LOCKS.configure(sd)
  EGGGATES.configure(sd)
  FILLERS.configure(sd)
  ABILITIES.configure(sd)
  ORBS2.configure(sd, s2_session())
  EGGHUD.configure(sd, s3_session())
  SPARX.configure(sd)
  DEATHLINK.configure(sd)
  LEVELTAB.configure(sd)
  connected = true
end

--- Handle room info by connecting the slot.
local function on_room_info()
  log_debug("== room info ==")
  local okS, err = pcall(function()
    ap:ConnectSlot(CFG.slot, CFG.password, items_handling, { "Lua-APClientPP", "DeathLink" }, client_version)
  end)
  log_debug("ConnectSlot: ok=" .. tostring(okS) .. " err=" .. tostring(err))
  if not okS then
    log_error("could not connect slot " .. CFG.slot .. ": " .. tostring(err))
  end
end

-- The library retries a dead server every few seconds; only a drop from a
-- live session is worth showing the player.
--- Log a socket error at debug level.
local function on_socket_error(msg)
  log_debug("socket error: " .. tostring(msg))
end
--- Handle a socket drop, showing the player only a drop from a live session.
local function on_socket_disconnected()
  if connected then
    connected = false
    DRAGONS.note_disconnected()
    ORBS2.note_disconnected()
    EGGHUD.note_disconnected()
    log_error("Disconnected from " .. CFG.host .. " (reconnecting)")
  else
    log_debug("socket disconnected")
  end
end
--- Log a socket connect at debug level.
local function on_socket_connected()
  log_debug("socket connected")
end
--- Log the server's reason for refusing this slot.
local function on_slot_refused(reasons)
  local why = type(reasons) == "table" and table.concat(reasons, ", ") or tostring(reasons)
  log_error("Server refused slot " .. CFG.slot .. ": " .. why)
end
--- Log the number of acknowledged location checks.
local function on_location_checked(locs)
  log_debug("location checked ack: " .. #locs)
end
--- Log a server print message at debug level.
local function on_print(msg)
  log_debug("server print: " .. tostring(msg))
end

-- ---------------------------------------------------------------------------
-- AP session
-- ---------------------------------------------------------------------------
--- Construct the AP client and wire every handler. The client auto-connects.
local function connect_ap()
  local okC, inst = pcall(function()
    return AP("", CFG.game, CFG.host)
  end)
  if not okC then
    log_error("FATAL ctor: " .. tostring(inst))
    return
  end
  ap = inst
  log_debug("AP client constructed (async thread) -> " .. CFG.host)

  ap:set_socket_connected_handler(on_socket_connected)
  ap:set_socket_error_handler(on_socket_error)
  ap:set_socket_disconnected_handler(on_socket_disconnected)
  ap:set_room_info_handler(on_room_info)
  ap:set_slot_connected_handler(on_slot_connected)
  ap:set_slot_refused_handler(on_slot_refused)
  ap:set_location_checked_handler(on_location_checked)
  ap:set_location_info_handler(on_location_info)
  ap:set_items_received_handler(on_items_received)
  ap:set_print_handler(on_print)

  -- The shipped DLL may lack set_bounced_handler (same build gap as the
  -- data-package changed handler). Without it, incoming DeathLinks never
  -- arrive but our own deaths still bounce.
  if type(ap.set_bounced_handler) == "function" then
    ap:set_bounced_handler(function(cmd)
      safe(function()
        DEATHLINK.on_bounced(cmd)
      end)
    end)
    log_debug("bounced handler wired")
  else
    log_debug("bounced handler unavailable (DLL build); incoming DeathLinks inactive")
  end

  -- The backlog replay runs once the data package is valid. Prefer the
  -- library's changed handler; the shipped DLL may lack it, in which case
  -- the poll loop's tick is the fallback (at most one poll late).
  if type(ap.set_data_package_changed_handler) == "function" then
    ap:set_data_package_changed_handler(function()
      safe(function()
        DATAPKG.tick(safe(function()
          return ap:is_data_package_valid()
        end, false))
      end)
    end)
    log_debug("data package changed handler wired")
  else
    log_debug("data package changed handler unavailable (DLL build); poll fallback active")
  end

  log_debug("handlers wired; library auto-connects on ctor")
end

-- A fresh session starts from nothing the previous save taught us. Clear
-- these tables in place, not with reassignment: checks_drop.lua was handed
-- id_to_name by reference at boot, so a reassignment here would orphan its
-- copy and leave it forever empty.
--- Reset all per-session state and every module's session state.
local function reset_session_state()
  for k in pairs(name_to_id) do
    name_to_id[k] = nil
  end
  for k in pairs(id_to_name) do
    id_to_name[k] = nil
  end
  for k in pairs(scouted) do
    scouted[k] = nil
  end
  for k in pairs(sent_checks) do
    sent_checks[k] = nil
  end
  session_game, checks_blocked = nil, false
  processed_indices = {}
  CHECKSDROP.reset()
  DATAPKG.reset()
  DRAGONS.reset()
  ORBS2.reset()
  EGGHUD.reset()
  GOALWATCH.configure({})
  DEATHLINK.configure({})
  LEVELTAB.configure({})
end

--- Open a session for the picked save: reset state, write session.txt, spawn
--- checkd and connect AP.
--- @param slot number Zero-based save slot index.
--- @param game number Game index (SESSION.SPYRO1/2/3).
local function open_session(slot, game)
  reset_session_state()
  session_game = game
  -- A drop checkd wrote for the previous save must not reach this one.
  os.remove(CHECKS_DROP)
  local f = io.open(SESSION_FILE, "w")
  if f then
    f:write(string.format("slot=%d\ngame=%d\ntoken=%d\n", slot, game, os.time()))
    f:close()
  else
    log_error("could not write " .. SESSION_FILE .. " (collected checks will not be sent)")
  end
  log_info(
    string.format(
      "Save slot %d picked (%s): connecting to %s as %s",
      slot + 1,
      SESSION.game_name(game),
      CFG.host,
      CFG.slot
    )
  )
  spawn_checkd()
  connect_ap()
end

--- Close the session: tear down AP, reset state and log the return to menu.
local function close_session()
  os.remove(SESSION_FILE)
  if ap then
    pcall(function()
      ap:reset()
    end)
  end
  ap, connected = nil, false
  collectgarbage()
  reset_session_state()
  log_info("Back at the main menu: disconnected. Pick a save to reconnect.")
end

-- UE4SS can wrap out-params in a table; see rec_read_save_collected.
--- Unwrap a UE4SS out-param into a number, or nil when unreadable.
--- @param v any
--- @return number|nil
local function out_number(v)
  if type(v) == "number" then
    return v
  end
  if type(v) == "table" then
    local inner = safe(function()
      return v.value
    end, nil)
    if type(inner) == "number" then
      return inner
    end
  end
  return nil
end

-- The gamestate's own interface, int out-params only: the static function
-- library's CDO is unreachable from Lua, and string out-params crash.
--- Return the active save's slot and game indexes, or nil when unreadable.
--- @param gs userdata FalconGameState.
--- @return number|nil, number|nil
local function read_active_slot(gs)
  local so, go = {}, {}
  if not pcall(function()
    gs["get slot index"](so)
  end) then
    return nil
  end
  if not pcall(function()
    gs["get game index"](go)
  end) then
    return nil
  end
  return out_number(so["slot index"]), out_number(go["the game index"])
end

local last_game_state = nil
--- Poll the game state through the session gate and open/close as directed.
local function session_tick()
  local gs = game_state()
  if not gs then
    return
  end
  local state = out_number(safe(function()
    return gs["theCurrentGameState"]
  end, nil))
  if state ~= last_game_state then
    log_debug("[SESSION] game state " .. tostring(last_game_state) .. " -> " .. tostring(state))
    last_game_state = state
  end
  local action, slot, game = SESSION.tick(state, function()
    return read_active_slot(gs)
  end)
  if action == "open" then
    log_debug(string.format("[SESSION] open: slot index=%d game index=%d", slot, game))
    open_session(slot, game)
  elseif action == "close" then
    close_session()
  end
end

-- Poll loop (async thread) and game watchers.
local polls = 0
LoopAsync(250, function()
  safe(session_tick)

  -- AP poll.
  if ap then
    local okP, errP = pcall(function()
      ap:poll()
    end)
    -- Backlog replay fallback for DLL builds without the changed
    -- handler; must also run when poll() errored (one-shot inside).
    safe(function()
      DATAPKG.tick(safe(function()
        return ap:is_data_package_valid()
      end, false))
    end)
    if not okP then
      log_debug("poll() errored: " .. tostring(errP))
      -- LoopAsync stops on a true return, so one errored poll must not
      -- kill the session gate and watchers for the rest of the session.
    else
      polls = polls + 1
      if polls % 240 == 0 then
        log_debug("poll tick " .. polls)
      end
    end
  end

  -- Ingest save-watcher check drops (before the dragon watcher).
  if connected then
    safe(function()
      CHECKSDROP.tick()
    end)
  end

  -- Game watchers: only while connected and in play on this session's
  -- save; one game_state() fetch feeds every tick.
  if connected and session_game ~= nil then
    local gs = game_state()
    local w = gs and WATCHERS[session_game]
    if w then
      if w.interleave then
        for i, m in ipairs(w.ticks) do
          safe(function()
            m.tick(gs)
          end)
          if polls % 480 == 0 then
            log_debug(w.hbs[i].tag .. w.hbs[i].mod.status())
          end
        end
      else
        for _, m in ipairs(w.ticks) do
          safe(function()
            m.tick(gs)
          end)
        end
        if polls % 480 == 0 then
          for _, hb in ipairs(w.hbs) do
            log_debug(hb.tag .. hb.mod.status())
          end
        end
      end
    end
  end

  return false
end)

log_debug("srt_bridge armed (host=" .. CFG.host .. " slot=" .. CFG.slot .. ")")
log_info("Pick New Game or Continue to connect to " .. CFG.host)
