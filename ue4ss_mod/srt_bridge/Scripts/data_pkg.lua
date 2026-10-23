-- Author: Tim Harrison
-- Created: 2026-09-26
-- Updated: 2026-10-11

-- data_pkg: replays the connect-time item backlog whose names resolved before
-- the AP data package loaded. AP's ReceivedItems is cumulative, so the AP item
-- index is the identity; items that stay unresolvable belong to another game
-- and are dropped.

local logger = require("logger")

local M = {}

local TAG = "[DATAPKG]"

local log = logger.tagged(TAG)
local process = function() end
local resolve = function() return nil end
local pending = {}   -- AP item index -> item id (parked until the package is valid)
local loaded = false -- one-shot: the package-valid replay has already run

--- Return whether name resolved to a usable item name.
local function usable(name)
    return type(name) == "string" and name ~= "?" and name ~= "Unknown"
end

--- Install the injected log/process/resolve callbacks and clear parked state.
function M.init(opts)
    log = logger.leveled(TAG, opts and opts.log)
    process = (opts and opts.process) or process
    resolve = (opts and opts.resolve) or resolve
    pending = {}
    loaded = false
end

--- Clear parked items and the loaded flag on session change.
function M.reset()
    pending = {}
    loaded = false
end

--- Process a received item, or park it by AP index when its name is unresolved.
function M.note(iname, index, item_id)
    if usable(iname) then
        if index ~= nil then pending[index] = nil end
        process(iname, index)
        return
    end
    if index ~= nil and item_id ~= nil then
        pending[index] = item_id
    end
end

--- Apply the parked backlog once the data package is valid.
function M.tick(is_valid)
    if loaded or not is_valid then return end
    loaded = true
    local applied = 0
    for index, item_id in pairs(pending) do
        local name = resolve(item_id)
        pending[index] = nil
        if usable(name) then
            applied = applied + 1
            local ok, err = pcall(process, name, index)
            if not ok then
                log.error("backlog replay failed for index " ..
                    tostring(index) .. ": " .. tostring(err))
            end
        end
    end
    if applied > 0 then
        log.info(string.format("data package loaded: applied %d backlog item(s)", applied))
    end
end
M.tag = TAG

return M