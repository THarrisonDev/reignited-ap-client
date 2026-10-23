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

local TAG = "[DROP]"

local _gate, _log, _send, _id_to_name, _sent_checks, _check_path

local M = {}

--- Inject the host's callbacks and dependencies and reset ingest state.
--- @param opts table {connect_gate, log, on_send, id_to_name, sent_checks, check_path}
function M.init(opts)
    _gate = opts.connect_gate
    _log = logger.leveled(TAG, opts.log)
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

--- Read the drop file's text, or nil when it is absent.
local function read_drop()
    local f = io.open(_check_path, "r")
    if not f then return nil end
    local lines = {}
    for line in f:lines() do lines[#lines + 1] = line end
    f:close()
    return table.concat(lines, "\n")
end

--- Count a parse error, quarantining the file after three in a row.
local function parse_error(text)
    drop_errs = drop_errs + 1
    if drop_errs < 3 then
        _log.warn("parse error #" .. drop_errs .. " (head: " .. text:sub(1, 100) .. ")")
        return
    end
    os.remove(_check_path .. ".bad")
    os.rename(_check_path, _check_path .. ".bad")
    drop_errs = 0
    _log.error("3 consecutive parse errors -> quarantined as checks.json.bad" ..
        " (head: " .. text:sub(1, 100) .. ")")
end

--- Parse a batch into {seq, ids, names}, or nil when the shape is malformed.
local function parse_drop(text)
    local seq = tonumber(text:match('"seq"%s*:%s*(-?%d+)'))
    local checks_inner = text:match('"checks"%s*:%s*%[(.-)%]')
    if seq == nil or checks_inner == nil then return nil end
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
    return {seq = seq, ids = ids, names = names}
end

--- Return the ids this slot knows and has not sent, plus the unknown count.
local function filter_new(ids)
    local new_checks, skipped = {}, 0
    for _, id in ipairs(ids) do
        if not _id_to_name[id] then
            skipped = skipped + 1
        elseif not _sent_checks[id] then
            new_checks[#new_checks + 1] = id
        end
    end
    return new_checks, skipped
end

--- Consume a batch: remember its seq, clear the error streak, delete the file.
local function consume(seq)
    drop_last_seq, drop_errs = seq, 0
    os.remove(_check_path)
end

--- Log that a batch held nothing new, once per seq for the already-sent case.
local function log_nothing_new(seq, skipped)
    if skipped > 0 then
        _log.debug(skipped .. " id(s) not in this slot's locations -> dropped")
    end
    if drop_last_dedup_seq ~= seq then
        drop_last_dedup_seq = seq
        _log.debug("all checks already sent (seq=" .. seq .. ")")
    end
end

--- Send a batch's new checks and consume it; a failed send retries next tick.
local function send_batch(batch, new_checks, skipped)
    _log.debug("ingested: seq=" .. batch.seq .. " count=" .. #new_checks ..
        (skipped > 0 and (" (skipped " .. skipped .. " not in this slot)") or "") ..
        " (names: " .. (batch.names and table.concat(batch.names, ", ") or "") .. ")")
    if not _send(new_checks, batch.names) then
        _log.error("send failed (retry next tick)")
        return
    end
    for _, id in ipairs(new_checks) do
        _sent_checks[id] = true
    end
    consume(batch.seq)
end

--- Poll the drop file once and send any new in-slot checks.
function M.tick()
    if not _gate() then return end
    local text = read_drop()
    if not text then return end
    local batch = parse_drop(text)
    if not batch then
        parse_error(text)
        return
    end
    if #batch.ids == 0 then           -- valid empty batch: consume it
        consume(batch.seq)
        return
    end
    if batch.seq == drop_last_seq then -- stale duplicate: consume silently
        os.remove(_check_path)
        return
    end
    local new_checks, skipped = filter_new(batch.ids)
    if #new_checks == 0 then
        log_nothing_new(batch.seq, skipped)
        consume(batch.seq)
        return
    end
    send_batch(batch, new_checks, skipped)
end
M.tag = TAG

return M