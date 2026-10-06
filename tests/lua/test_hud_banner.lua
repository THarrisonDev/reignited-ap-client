-- Spec for client/ue4ss_mod/srt_bridge/Scripts/hud_banner.lua. Fakes the
-- UE4SS surface (FindFirstOf, StaticFindObject, timers, game thread) and
-- verifies the proven recipe: fanfare -> +100ms write -> convergence check.
-- Run from the client repo root: lua tests/lua/test_hud_banner.lua

local here = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./"
package.path = here .. "../../ue4ss_mod/srt_bridge/Scripts/?.lua;" .. package.path

local failures = 0
local function check(name, cond, extra)
    if not cond then
        print("FAIL: " .. name .. (extra and (" (" .. extra .. ")") or ""))
        failures = failures + 1
    end
end

-- fake UE4SS globals
local game_thread_jobs, timers = {}, {}
-- controllable clock: the job runner backoff and the banner window are
-- os.time-based. Declared before the runners so they can advance it.
local fake_now = os.time()
ExecuteInGameThread = function(fn) game_thread_jobs[#game_thread_jobs + 1] = fn end
ExecuteWithDelay = function(ms, fn) timers[#timers + 1] = {ms = ms, fn = fn} end

local function run_game_thread()
    for _ = 1, 20 do
        if #game_thread_jobs == 0 then break end
        local fns = game_thread_jobs
        game_thread_jobs = {}
        for _, fn in ipairs(fns) do fn() end
    end
end

local function run_timers()
    local ts = timers
    timers = {}
    for _, t in ipairs(ts) do
        fake_now = fake_now + (t.ms or 0) / 1000   -- ExecuteWithDelay advances time
        t.fn()
    end
end

local find_of = {}                  -- class -> table (per scenario)
local find_first_calls = {}         -- class -> count (for the cache spec)
FindFirstOf = function(class)
    find_first_calls[class] = (find_first_calls[class] or 0) + 1
    return find_of[class]
end

local static_objects = {}
StaticFindObject = function(path) return static_objects[path] end

-- fake fanfare widget: a proxy where fmw["message text"] (write) sets
-- _written and fmw["message text"]:ToString() (read) returns it — mirroring
-- how UE4SS routes property reads/writes to the same backing field.
-- one stable fake lib (the module caches StaticFindObject results — in the
-- game it never changes); recorders reset per scenario
local ftexts = {}
-- the HUD is cached by the module; bump the generation each scenario so any
-- previously cached HUD reports invalid, forcing a re-fetch (as a level
-- transition would in the game)
local hud_gen = 0

local function setup()
    ftexts = {}
    find_first_calls = {}
    hud_gen = hud_gen + 1
    local my_gen = hud_gen
    widget = setmetatable({}, {
        __index = function(_, k)
            if k == "message text" then
                -- the property we wrote. _prop_sticky=false simulates the game
                -- rewriting the property; the displayed Base is separate.
                local t = widget._prop_sticky and widget._prop_text or "Rescued "
                return {ToString = function() return t end,
                        IsValid = function() return true end}
            end
            if k == "State" then
                return (fake_now < (widget._window_until or 0)) and 1 or 0
            end
            return rawget(widget, k)
        end,
        __newindex = function(_, k, v)
            if k == "message text" then
                widget._prop_text = type(v) == "table" and v.text or v
                widget._writes = (widget._writes or 0) + 1
                return
            end
            rawset(widget, k, v)
        end,
    })
    widget._prop_sticky = true
    widget._base_sticky = true
    widget._window_open = false
    -- State is what the module gates on. It reads like a plain field
    -- (widget.State), so expose it via the metatable's __index fallback.
    widget._state = 0
    widget.IsValid = function() return true end
    -- Base is the TextBlock the player sees. GetText reflects our SetText only
    -- while _base_sticky; a game repaint reverts it to "Rescued ".
    widget.Base = {
        SetText = function(_, ft)
            widget._base_text = type(ft) == "table" and ft.text or ft
            widget._base_ftext = ft
        end,
        GetText = function()
            local t = widget._base_sticky and widget._base_text or "Rescued "
            return {ToString = function() return t end, text = t}
        end,
    }
    find_of = {
        PlayerController = {
            GetHUD = function()
                return {
                    IsValid = function() return hud_gen == my_gen end,
                    -- the game's fanfare path opens the widget for ~3s
                    ShowFanfare = function()
                        widget._window_until = fake_now + 3
                        widget._fanfares = (widget._fanfares or 0) + 1
                    end,
                }
            end,
        },
        UI_FanFareMessage_C = widget,
    }
    static_objects["/Script/Engine.Default__KismetTextLibrary"] = {
        IsValid = function() return true end,
        Conv_StringToText = function(_, s)
            ftexts[#ftexts + 1] = s
            return {text = s, ToString = function() return s end, IsValid = function() return true end}
        end,
    }
    return widget, ftexts
end

-- controllable clock: the job runner backoff is os.time-based (fake_now is
-- declared above setup and os.time is overridden just below)
os.time = function() return fake_now end

local banner = require("hud_banner")

-- scenario 1: happy path — fanfare, +100ms write, convergence no-op
do
    local widget = setup()
    local lines = {}
    banner.init({log = function(l) lines[#lines + 1] = l end})

    banner.note_item("Nestor's Key")
    run_game_thread()               -- submit job
    run_game_thread()               -- execute job: fanfare + arm timer
    check("s1 ftext not written before timer", #ftexts == 0)
    local timer_count = #timers
    check("s1 write timer armed", timer_count >= 1)
    run_timers()                    -- +100ms
    run_game_thread()               -- write job
    check("s1 Conv_StringToText with our text", ftexts[1] == "Nestor's Key",
        tostring(ftexts[1]))
    check("s1 property written", widget._prop_text == "Nestor's Key",
        tostring(widget._prop_text))
    check("s1 Base textblock written",
        widget._base_ftext and widget._base_ftext.text == "Nestor's Key")
    check("s1 shown log",
        table.concat(lines, "\n"):find("banner: Nestor's Key", 1, true) ~= nil)
    -- +2s convergence: property already ours -> no new conversion... (the
    -- readback equals text only via holder; ftext re-write is skipped by
    -- the cur == text check)
    local before = #ftexts
    run_timers()
    run_game_thread()
    check("s1 convergence no-op when stuck", #ftexts == before)
end

-- scenario 2: backlog — tick-driven drain shows both, one at a time
do
    local widget = setup()
    local lines = {}
    banner.init({log = function(l) lines[#lines + 1] = l end})
    banner.note_item("Item A")
    banner.note_item("Item B")
    for _ = 1, 30 do fake_now = fake_now + 1
        banner.tick()
        run_game_thread()
        run_timers()
    end
    check("s2 both eventually written", #ftexts >= 2, tostring(#ftexts))
    check("s2 order kept (A first)", ftexts[1] == "Item A", tostring(ftexts[1]))
end

-- scenario 3: no widget — item dropped with a WARN, no crash
do
    local widget = setup()
    local lines = {}
    banner.init({log = function(l) lines[#lines + 1] = l end})
    find_of["UI_FanFareMessage_C"] = nil
    banner.note_item("Item C")
    for _ = 1, 6 do run_game_thread(); run_timers() end
    check("s3 no writes", #ftexts == 0)
    check("s3 drop warned", table.concat(lines, "\n"):find("no fanfare widget", 1, true) ~= nil,
        table.concat(lines, "\n"))
end

-- scenario 4: status sanity after a shown item
do
    local widget = setup()
    local lines = {}
    banner.init({log = function(l) lines[#lines + 1] = l end})
    banner.note_item("Item S")
    for _ = 1, 30 do fake_now = fake_now + 1
        banner.tick()
        run_game_thread()
        run_timers()
    end
    check("s4 status counts this run", banner.status():find("shown=1") ~= nil or
        banner.status():find("shown=") ~= nil, banner.status())
    check("s4 no backlog left", banner.status():find("waiting=0") ~= nil,
        banner.status())
end

-- scenario 5: a sent line shows on the banner
do
    local widget = setup()
    local lines = {}
    banner.init({log = function(l) lines[#lines + 1] = l end})
    banner.note_sent("To Bob: Nestor's Key")
    for _ = 1, 30 do fake_now = fake_now + 1
        banner.tick()
        run_game_thread()
        run_timers()
    end
    check("s5 sent text written", ftexts[#ftexts] == "To Bob: Nestor's Key",
        tostring(ftexts[#ftexts]))
    check("s5 sent counted", banner.status():find("sent=1") ~= nil, banner.status())
end

-- scenario 6: a received item outranks a sent line queued before it
do
    local widget = setup()
    local lines = {}
    banner.init({log = function(l) lines[#lines + 1] = l end})
    banner.note_sent("To Bob: Orb")
    banner.note_item("You found: Dragon")
    for _ = 1, 30 do fake_now = fake_now + 1
        banner.tick()
        run_game_thread()
        run_timers()
    end
    check("s6 received shows first", ftexts[1] == "You found: Dragon", tostring(ftexts[1]))
    check("s6 sent follows", ftexts[#ftexts] == "To Bob: Orb", tostring(ftexts[#ftexts]))
end

-- scenario 7: a sent backlog collapses to its newest line
do
    local widget = setup()
    local lines = {}
    banner.init({log = function(l) lines[#lines + 1] = l end})
    for i = 1, 5 do banner.note_sent("To Bob: Item " .. i) end
    for _ = 1, 30 do fake_now = fake_now + 1
        banner.tick()
        run_game_thread()
        run_timers()
    end
    check("s7 first shown", ftexts[1] == "To Bob: Item 1", tostring(ftexts[1]))
    check("s7 newest collapsed in", ftexts[#ftexts] == "To Bob: Item 5", tostring(ftexts[#ftexts]))
    check("s7 collapse logged",
        table.concat(lines, "\n"):find("backlog collapsed", 1, true) ~= nil,
        table.concat(lines, "\n"))
    check("s7 sent backlog empty", banner.status():find("sent_waiting=0") ~= nil,
        banner.status())
end

-- scenario 8: the game wipes the `message text` property, so the write is
-- unconfirmed: it is counted failed and the re-asserts rewrite until it holds.
do
    local widget = setup()
    local lines = {}
    banner.init({log = function(l) lines[#lines + 1] = l end})
    widget._prop_sticky = false        -- game repaint wipes the property
    banner.note_item("Wiped Item")
    run_game_thread()
    run_game_thread()
    run_timers()
    run_game_thread()
    check("s8 first write attempted", widget._writes == 1, tostring(widget._writes))
    run_timers()                       -- run the re-assert timers
    run_game_thread()
    check("s8 re-assert retried the write", widget._writes >= 3, tostring(widget._writes))
    local joined = table.concat(lines, "\n")
    check("s8 unconfirmed logged", joined:find("not confirmed", 1, true) ~= nil, joined)
    check("s8 status failed", banner.status():find("failed=1") ~= nil, banner.status())
end

-- scenario 8b: property-vs-display divergence. The property holds our text but
-- the Base the player sees is canned (Base is bound and a direct SetText is
-- overridden). Judging on the property means success, no re-assert, and no
-- extra writes — chasing Base is what closed the window (regression guard).
do
    local widget = setup()
    local lines = {}
    banner.init({log = function(l) lines[#lines + 1] = l end})
    fake_now = fake_now + 10           -- clear scenario 8's backoff
    widget._prop_sticky = true         -- property holds our text
    widget._base_sticky = false        -- but the displayed Base is canned
    banner.note_item("Divergent Item")
    run_game_thread()
    run_game_thread()
    run_timers()
    run_game_thread()
    local writes_after_first = widget._writes
    run_timers()                       -- run the re-assert timers
    run_game_thread()
    local joined = table.concat(lines, "\n")
    check("s8b judged on property, not Base",
        joined:find("banner: Divergent Item", 1, true) ~= nil
            and joined:find("not confirmed", 1, true) == nil, joined)
    check("s8b no re-assert when property holds",
        widget._writes == writes_after_first, tostring(widget._writes))
end

-- scenario 9: a stale widget pointer is rejected, item dropped with a WARN
do
    local widget = setup()
    local lines = {}
    banner.init({log = function(l) lines[#lines + 1] = l end})
    widget.IsValid = function() return false end
    banner.note_item("Stale Item")
    for _ = 1, 6 do fake_now = fake_now + 1; banner.tick(); run_game_thread(); run_timers() end
    check("s9 no writes", #ftexts == 0)
    check("s9 drop warned", table.concat(lines, "\n"):find("no fanfare widget", 1, true) ~= nil,
        table.concat(lines, "\n"))
end

-- scenario 10: the HUD is cached across banners
do
    local widget = setup()
    local lines = {}
    banner.init({log = function(l) lines[#lines + 1] = l end})
    banner.note_item("Cache A")
    for _ = 1, 30 do fake_now = fake_now + 1
        banner.tick()
        run_game_thread()
        run_timers()
    end
    banner.note_item("Cache B")
    for _ = 1, 30 do fake_now = fake_now + 1
        banner.tick()
        run_game_thread()
        run_timers()
    end
    check("s10 two banners shown", #ftexts >= 2, tostring(#ftexts))
    check("s10 PlayerController fetched once", find_first_calls["PlayerController"] == 1,
        tostring(find_first_calls["PlayerController"]))
end

-- scenario 11: the widget is mid-game-fanfare (State=1) when our banner is
-- due. We must NOT inject yet; we wait for idle, then fire our own fanfare.
do
    local widget = setup()
    local lines = {}
    banner.init({log = function(l) lines[#lines + 1] = l end})
    widget._window_until = fake_now + 3    -- the game's own fanfare is showing
    banner.note_item("Waits For Idle")
    run_game_thread()                      -- submit + run show()
    check("s11 no fanfare while game window up", (widget._fanfares or 0) == 0,
        tostring(widget._fanfares))
    -- let the game's window lapse, then tick so the idle wait proceeds
    for _ = 1, 20 do
        fake_now = fake_now + 0.5
        banner.tick()
        run_game_thread()
        run_timers()
        run_game_thread()
    end
    check("s11 our fanfare fired after idle", (widget._fanfares or 0) >= 1,
        tostring(widget._fanfares))
    check("s11 text eventually shown", (widget._base_text == "Waits For Idle")
        or table.concat(lines, "\n"):find("banner: Waits For Idle", 1, true) ~= nil,
        table.concat(lines, "\n"))
end

print(failures == 0 and "hud_banner spec: OK" or ("hud_banner spec: " .. failures .. " failures"))
os.exit(failures == 0 and 0 or 1)