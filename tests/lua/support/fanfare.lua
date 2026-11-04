-- Author: Tim Harrison
-- Created: 2026-10-21
-- Updated: 2026-11-02

-- The fake fanfare widget's UE4SS property plumbing and its own Intro ->
-- Delay -> Outro -> state chain, used by the hud_banner specs. "message text"
-- is the lever, "State" is a live engine field a write pins, and the widget
-- counts as showing while its Intro is paused, its chain is armed or the
-- window the game set is still running. F.resume models the module handing the
-- window back, F.refuse_chain the chain that never runs (the 2026-11-02
-- wedge), and F.refuse a legacy close the game ignores.

local F = {}

local pending = {} -- widgets whose resumed Intro chain is still running

F.CHAIN_TICKS = 2 -- stub ticks from a resumed Intro to state = 0

--- Attach the property aliases to a fake widget.
--- @param w table Widget with _prop, _paused, _hold, _window_until, _state_written.
--- @param now function Returns the fake clock in seconds.
--- @param on_text function|nil Called with each message-text write.
--- @return table The widget.
function F.attach(w, now, on_text)
    return setmetatable(w, {
        __index = function(t, k)
            if k == "message text" then
                return { ToString = function() return t._prop end }
            end
            if k == "State" then
                if t._state_written ~= nil then return t._state_written end
                return (t._paused or t._hold or now() < t._window_until) and 1 or 0
            end
            return rawget(t, k)
        end,
        __newindex = function(t, k, v)
            if k == "message text" then
                t._prop = v and v.text or "?"
                if on_text then on_text(t._prop) end
                return
            end
            if k == "State" then -- live engine field: a write pins it, no rawset
                if t._ignoring then -- the release in flight is being ignored
                    t._ignoring = false
                    return
                end
                t._state_written = v
                return
            end
            rawset(t, k, v)
        end,
    })
end

--- Model the module resuming the paused Intro: the widget plays it out and its
--- own chain clears state after F.CHAIN_TICKS stub ticks. A widget whose chain
--- is refused still records the resume but keeps the window open.
--- @param w table Widget.
--- @return boolean whether the chain runs.
function F.resume(w)
    w.resumed = (w.resumed or 0) + 1
    w._paused = false
    w._hold = true -- the window is the widget's until its chain finishes
    if w._chain_dead then return false end
    w._chain = F.CHAIN_TICKS
    pending[w] = true
    return true
end

--- Advance the widgets' own chains one stub tick: Intro finished, the Delay
--- elapsed, the Outro played, state = 0.
function F.tick()
    local live = pending
    pending = {}
    for w in pairs(live) do
        w._chain = w._chain - 1
        if w._chain <= 0 then
            w._hold = false
            w._window_until = 0
            w.outros = w.outros + 1
            w.closed = (w.closed or 0) + 1
        else
            pending[w] = true
        end
    end
end

--- Make a widget's resumed chain never run: state stays 1, as the 2026-11-02
--- wedge left it.
--- @param w table Widget.
function F.refuse_chain(w)
    w._chain_dead = true
end

--- Make the next n legacy closes land nowhere, as when the game ignores them.
--- @param w table Widget.
--- @param n number Release attempts to ignore.
function F.refuse(w, n)
    w._refuse = n
end

--- Close the window under the module, as the widget's own chain does when a game
--- message finishes or any other reason takes it: State reads 0 while the module
--- still holds the lease.
--- @param w table Widget.
function F.close(w)
    w._paused, w._hold, w._window_until = false, false, 0
    w.closed = (w.closed or 0) + 1
end

--- Consume one refusal for the release starting now, arming its State write to
--- be ignored too.
--- @param w table Widget.
--- @return boolean Whether this release is ignored.
function F.release_ignored(w)
    if (w._refuse or 0) <= 0 then return false end
    w._refuse = w._refuse - 1
    w._ignoring = true
    return true
end

return F
