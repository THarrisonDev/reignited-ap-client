-- Author: Tim Harrison
-- Created: 2026-09-26
-- Updated: 2026-10-11

-- checks_drop: ingest the Go checkd daemon's check drops.
--
-- Reads C:/srtap_bridge/checks.json (owned by checkd, client/checkd/main.go
-- sendDrop) with hand-rolled parsing for exactly its {"seq":N,"checks":[ids],
-- "names":[...]} shape, drops ids absent from this slot's locationNameToId
-- (checkd is option-blind, so option-disabled checks resolve here), dedups
-- against the ids already sent, and passes the rest to the host's send callback.

local logger = require("logger")

local DEFAULT_CHECKS_DROP = "C:/srtap_bridge/checks.json"

local drop_last_seq = nil    -- last checks.json seq ingested
local drop_errs = 0          -- consecutive parse errors
local drop_last_dedup_seq = nil -- seq whose all-already-sent we logged

local _gate, _log, _send, _id_to_name, _sent_checks, _check_path

local M = {}

--- Inject the host's callbacks and dependencies and reset ingest state.
--- @param opts table {connect_gate, log, on_send, id_to_name, sent_checks, check_path}
function M.init(opts)
    _gate = opts.connect_gate
    _log = logger.leveled("[DROP]", opts.log)
    _send = opts.on_send
    _id_to_name = opts.id_to_name
    _sent_checks = opts.sent_checks
    _check_path = opts.check_path or DEFAULT_CHECKS_DROP
    drop_last_seq, drop_errs, drop_last_dedup_seq = nil, 0, nil
end

--- Clear the ingested-seq and parse-error counters.
function M.reset()
    drop_last_seq = nil
    drop_errs = 0
    drop_last_dedup_seq = nil
end

-- Ingest semantics: a parse error (3 consecutive quarantines the file as .bad);
-- a valid empty batch, stale seq or all-already-sent batch is consumed silently;
-- ids absent from id_to_name never reach on_send.
--- Poll the drop file once and send any new in-slot checks.
function M.tick()
    if not _gate() then return end
    local f = io.open(_check_path, "r")
    if not f then return end
    local lines = {}
    for line in f:lines() do lines[#lines + 1] = line end
    f:close()
    local text = table.concat(lines, "\n")

    local seq = tonumber(text:match('"seq"%s*:%s*(-?%d+)'))
    local checks_inner = text:match('"checks"%s*:%s*%[(.-)%]')
    if seq == nil or checks_inner == nil then
        drop_errs = drop_errs + 1
        if drop_errs >= 3 then
            os.remove(_check_path .. ".bad")
            os.rename(_check_path, _check_path .. ".bad")
            drop_errs = 0
            _log.error("3 consecutive parse errors -> quarantined as checks.json.bad" ..
                " (head: " .. text:sub(1, 100) .. ")")
        else
            _log.warn("parse error #" .. drop_errs ..
                " (head: " .. text:sub(1, 100) .. ")")
        end
        return
    end
    local ids = {}
    for n in checks_inner:gmatch("(-?%d+)") do
        ids[#ids + 1] = tonumber(n)
    end
    -- names are best-effort, log-only; absent/mangled names degrade to nil
    local names
    local okN, names_inner = pcall(function()
        return text:match('"names"%s*:%s*%[(.-)%]')
    end)
    if okN and names_inner then
        names = {}
        for nm in names_inner:gmatch('"([^"]*)"') do
            names[#names + 1] = nm
        end
    end

    if #ids == 0 then
        -- valid empty batch: consume it, nothing to send
        drop_last_seq = seq
        drop_errs = 0
        os.remove(_check_path)
        return
    end
    if seq == drop_last_seq then
        -- stale duplicate from a previous session: consume silently
        os.remove(_check_path)
        return
    end

    local new_checks = {}
    local skipped = 0
    for _, id in ipairs(ids) do
        if _id_to_name[id] then
            if not _sent_checks[id] then new_checks[#new_checks + 1] = id end
        else
            skipped = skipped + 1
        end
    end
    if #new_checks == 0 then
        if skipped > 0 then
            _log.debug(skipped .. " id(s) not in this slot's locations -> dropped")
        end
        if drop_last_dedup_seq ~= seq then
            drop_last_dedup_seq = seq
            _log.debug("all checks already sent (seq=" .. seq .. ")")
        end
        drop_last_seq = seq
        drop_errs = 0
        os.remove(_check_path)
        return
    end

    _log.debug("ingested: seq=" .. seq .. " count=" .. #new_checks ..
        (skipped > 0 and (" (skipped " .. skipped .. " not in this slot)") or "") ..
        " (names: " .. (names and table.concat(names, ", ") or "") .. ")")
    local okS = _send(new_checks, names)
    if okS then
        for _, id in ipairs(new_checks) do
            _sent_checks[id] = true
        end
        drop_last_seq = seq
        drop_errs = 0
        os.remove(_check_path)
    else
        _log.error("send failed (retry next tick)")
    end
end

return M