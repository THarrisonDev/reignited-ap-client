-- Author: Tim Harrison
-- Created: 2026-10-21
-- Updated: 2026-10-23

-- Fake PortalTransporter actors for the level-lock specs, with the behaviour
-- observed live:
--   setPortalEnabled(en): EnableTransport = PreloadEnabled = en; glyphs hidden = not en
--   REMAKE text: display text = text; old glyphs destroyed, new ones spawn hidden
--   refuse_enable: the game accepts the call but leaves the portal disabled
-- Every write asserts the harness game-thread flag: a write from the async
-- tick is the 2026-09-13 hardlock.

local P = {}

local next_addr = 100

--- Build one fake portal actor.
--- @param H table Harness (game-thread flag, fstring).
--- @param code string LS code the partner-portal name is derived from.
--- @param name string Display name the portal shows.
--- @return table
function P.new(H, code, name)
    next_addr = next_addr + 1
    local portal = { addr = next_addr, remakes = 0, glyphs = {} }
    portal.props = {
        PartnerPortalName = code .. "_LevelStart",
        EnableTransport = true,
        PreloadEnabled = true,
    }
    local function spawn(text)
        portal.glyphs = {}
        for ch in text:gmatch("%S") do
            portal.glyphs[#portal.glyphs + 1] = { ch = ch, hidden = true }
        end
    end
    spawn(name)
    for _, g in ipairs(portal.glyphs) do g.hidden = false end -- portal init revealed them

    local cprops = { ["display text"] = name, Scale = 1.0, ["default char width"] = 22.0 }
    local characters = {
        GetArrayNum = function() return #portal.glyphs end,
        ForEach = function(_, cb)
            for i, g in ipairs(portal.glyphs) do
                local glyph = setmetatable({}, { __index = function(_, k)
                    if k == "IsValid" then return function() return true end end
                    if k == "SetActorHiddenInGame" then return function(_, hidden)
                        assert(H.thread, "glyph visibility changed off the game thread")
                        g.hidden = hidden
                    end end
                end })
                cb(i, { get = function() return glyph end })
            end
        end,
    }
    local comp = setmetatable({}, { __index = function(_, k)
        if k == "IsValid" then return function() return true end end
        if k == "Characters" then return characters end
        if k == "REMAKE text" then return function(text, scale, width)
            assert(H.thread, "REMAKE text called off the game thread")
            assert(scale == 1.0 and width == 22.0, "REMAKE must reuse the component's scale/width")
            portal.remakes = portal.remakes + 1
            cprops["display text"] = text
            spawn(text)
        end end
        local v = cprops[k]
        if type(v) == "string" then return H.fstring(v) end
        return v
    end })
    portal.actor = setmetatable({}, { __index = function(_, k)
        if k == "IsValid" then return function() return true end end
        if k == "GetAddress" then return function() return portal.addr end end
        if k == "PortalNameComponent" then return comp end
        if k == "setPortalEnabled" then return function(_, en)
            assert(H.thread, "setPortalEnabled called off the game thread")
            if portal.explode then error("portal boom") end
            if en and portal.refuse_enable then return end
            portal.props.EnableTransport, portal.props.PreloadEnabled = en, en
            for _, g in ipairs(portal.glyphs) do g.hidden = not en end
        end end
        local v = portal.props[k]
        if type(v) == "string" then return H.fstring(v) end
        return v
    end })
    function portal.text() return cprops["display text"] end
    function portal.visible()
        local s = {}
        for _, g in ipairs(portal.glyphs) do if not g.hidden then s[#s + 1] = g.ch end end
        return table.concat(s)
    end
    return portal
end

return P
