-- Author: Tim Harrison
-- Created: 2026-10-21
-- Updated: 2026-10-23

-- Fake GAS health actors shared by the specs that write Spyro's health: the
-- pawn's own attribute set (found through an Outer chain) and an enemy's set,
-- which must never be mistaken for the pawn's. Every write asserts the
-- harness game-thread flag.

local A = {}

--- Build a pawn's health attribute set, owned through its Outer chain.
--- @param H table Harness (game-thread flag).
--- @param P table The owning pawn: addr, hp, actor, optional health_outer.
--- @return table
function A.health_set(H, P)
    return setmetatable({}, {
        __index = function(_, k)
            if k == "IsValid" then return function() return true end end
            if k == "GetAddress" then return function() return P.addr + 0x100 end end
            if k == "GetOuter" then return function()
                assert(H.thread, "GetOuter off the game thread")
                return P.health_outer or P.actor
            end end
            if k == "HealthCurrent" then return P.hp end
            return nil
        end,
        __newindex = function(_, k, v)
            if k ~= "HealthCurrent" then return end
            assert(H.thread, "HealthCurrent written off the game thread")
            if P.reject_write then P.hp = 2 return end
            P.hp = v
        end,
    })
end

--- Build an enemy's health set: its Outer chain never reaches the pawn.
--- @param addr number
--- @return table
function A.enemy_set(addr)
    local E = { hp = 5 }
    local enemy = setmetatable({}, { __index = function(_, k)
        if k == "IsValid" then return function() return true end end
        if k == "GetAddress" then return function() return addr end end
        if k == "GetOuter" then return function() return nil end end
    end })
    E.set = setmetatable({}, {
        __index = function(_, k)
            if k == "IsValid" then return function() return true end end
            if k == "GetAddress" then return function() return addr + 0x100 end end
            if k == "GetOuter" then return function() return enemy end end
            if k == "HealthCurrent" then return E.hp end
        end,
        __newindex = function(_, k, v) if k == "HealthCurrent" then E.hp = v end end,
    })
    return E
end

--- Point the UE4SS actor lookups at world.pawn and world.enemy_sets.
--- UE4SS lookups take the short class name: the U-prefixed name, and
--- FindFirstOf for the health-set class at all, answer nil so a regression to
--- either fails the trap specs. FindAllOf lists the enemy sets first (they
--- usually precede Spyro's), then the pawn's, and nil when empty.
--- @param world table The fake world to read.
function A.install(world)
    FindFirstOf = function(cls)
        if cls ~= "BP_CPS1999_Playable_C" then return nil end
        return world.pawn and world.pawn.actor or nil
    end
    FindAllOf = function(cls)
        if cls ~= "PhasmidHealthSystemAttributeSet" then return nil end
        local all = {}
        for _, e in ipairs(world.enemy_sets or {}) do all[#all + 1] = e.set end
        if world.pawn and world.pawn.health then all[#all + 1] = world.pawn.health end
        if #all == 0 then return nil end
        return all
    end
end

return A
