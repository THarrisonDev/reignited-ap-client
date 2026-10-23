-- Author: Tim Harrison
-- Created: 2026-10-21
-- Updated: 2026-10-21

-- The fake fanfare widget's UE4SS property plumbing, shared by test_hud_banner
-- and test_banner_probe: "message text" is the lever, "State" is a live engine
-- field a write pins, and the widget counts as showing while it is paused or
-- inside the window the game set.

local F = {}

--- Attach the property aliases to a fake widget.
--- @param w table Widget with _prop, _paused, _window_until, _state_written.
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
                return (t._paused or now() < t._window_until) and 1 or 0
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
                t._state_written = v
                return
            end
            rawset(t, k, v)
        end,
    })
end

return F
