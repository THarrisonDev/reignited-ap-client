-- data_pkg: replays the connect-time item backlog that arrived before the
-- AP data package loaded. The very first ReceivedItems batch (level keys,
-- Dragons, Extra Lives) is named "Unknown"/"?" until the package arrives,
-- and the server never re-delivers it, so every consumer silently ignored
-- it (live-observed Sept 2026). Unresolvable items park here as
-- (AP item index -> item id); once the package is valid (changed-handler
-- when the DLL has one, else the poll loop's tick) each parked item is
-- resolved and applied exactly once through the caller's process().
--
-- AP's ReceivedItems is CUMULATIVE — every packet re-delivers index 0..n —
-- so the AP item index is the identity, and a later usable name for an
-- index clears anything parked for it (the backlog and the live stream can
-- both carry the same index).
--
-- Items that still fail to resolve after the package is valid belong to
-- another game; our consumers wouldn't act on them, so they are dropped.
--
-- API (main.lua): init{log, process, resolve}, reset() on session change,
-- note(iname, index, item_id) per received item, tick(is_valid) from the
-- data-package handler and the poll loop. log is a leveled logger (tagged
-- [DATAPKG]) or the spec's collector function.

local logger = require("logger")

local M = {}

local log = logger.tagged("[DATAPKG]")
local process = function() end
local resolve = function() return nil end
local pending = {}   -- AP item index -> item id (parked until the package is valid)
local loaded = false -- one-shot: the package-valid replay has already run

local function usable(name)
    return type(name) == "string" and name ~= "?" and name ~= "Unknown"
end

function M.init(opts)
    log = logger.leveled("[DATAPKG]", opts and opts.log)
    process = (opts and opts.process) or process
    resolve = (opts and opts.resolve) or resolve
    pending = {}
    loaded = false
end

function M.reset()
    pending = {}
    loaded = false
end

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

return M