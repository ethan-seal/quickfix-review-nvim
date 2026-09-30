-- The :ReviewHistory view: the event history rows of a comment or of the
-- last events, read from the review's journal segments (or, for a review
-- whose v2 log could not be migrated, from that log and its rotated logs).
local M = {}

local history = require('quickfix-review.history')
local location = require('quickfix-review.store.location')
local log = require('quickfix-review.log')
local maintenance = require('quickfix-review.store.maintenance')
local segment = require('quickfix-review.store.segment')
local store = require('quickfix-review.store')

local uv = vim.uv or vim.loop

-- The unreadable lines of each file (by path) already warned about, so
-- :ReviewHistory warns about each once rather than on every call
local history_seen = {}

-- The event history rows of comment `id`, or of the last 50 events. The
-- journal's segments (or, for a v2 review, its rotated logs and then
-- log.jsonl) are read newest first, back only as far as needed: for the
-- last 50, until there are 50 events; for a comment, until a file that
-- starts with a checkpoint (a migrated v2 log, or a v2 rotated log) that
-- doesn't know it (it didn't exist before that file).
function M.history_rows(id)
  id = id ~= '' and id or nil
  local function read(path)
    history_seen[path] = history_seen[path] or {}
    return log.read(path, 0, 0, history_seen[path])
  end
  local loc = location.resolve()
  local segs = segment.list(loc.events)
  -- The files to read, oldest first
  local paths = {}
  if #segs == 0 then
    -- A v2 log not migrated (a tombstone has no events): its rotated logs,
    -- then log.jsonl. A rotated name hard-linked to the same inode as a
    -- later one (a v2 rotation that crashed after its link) is read once,
    -- at its latest position.
    local files = log.is_tombstone(log.read_header(loc.log)) and {} or maintenance.list_rotated(loc)
    table.insert(files, { path = loc.log })
    local seen = {}
    for i = #files, 1, -1 do
      local st = uv.fs_stat(files[i].path)
      if not (st and seen[st.ino]) then
        if st then seen[st.ino] = true end
        table.insert(paths, 1, files[i].path)
      end
    end
  else
    for i, n in ipairs(segs) do paths[i] = segment.path(loc.events, n) end
  end
  local events, count = {}, 0
  for i = #paths, 1, -1 do
    local r, err = read(paths[i])
    if not r then
      if i == #paths then return nil, err end
      break
    end
    for _, ev in ipairs(r.events) do
      if ev.op ~= 'checkpoint' then count = count + 1 end
    end
    events = vim.list_extend(vim.list_extend({}, r.events), events)
    if id == nil and count >= history.LIMIT then break end
    local first = r.events[1]
    if id ~= nil and first and first.op == 'checkpoint' and not history.checkpoint_knows(first, id) then break end
  end
  return history.rows(events, id)
end

-- Print the event history of comment `id`, or the last 50 events
function M.history(id)
  local rows, err = M.history_rows(id)
  if not rows then
    local exists = uv.fs_stat(store.log_path()) or uv.fs_stat(store.events_dir())
    print(exists and tostring(err) or 'No review history yet')
    return
  end
  if #rows == 0 then
    print(id and id ~= '' and ('No history for ' .. id) or 'No review history yet')
    return
  end
  local chunks = {}
  for i, row in ipairs(rows) do
    chunks[i] = { row.text .. (i < #rows and '\n' or '') }
  end
  vim.api.nvim_echo(chunks, true, {})
end

return M
