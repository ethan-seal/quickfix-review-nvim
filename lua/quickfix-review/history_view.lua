-- The :ReviewHistory view: the event history rows of a comment or of the
-- last events, read from the review's journal segments (or, for a review
-- whose v2 log could not be migrated, from that log).
local M = {}

local store = require('quickfix-review.store')

-- The unreadable lines of each file (by path) already warned about, so
-- :ReviewHistory warns about each once rather than on every call
local history_seen = {}

-- The event history rows of comment `id`, or of the last 50 events. The
-- segments are read newest first, back only as far as needed: for the last
-- 50, until there are 50 events; for a comment, until a segment that starts
-- with a checkpoint (a migrated v2 log) that doesn't know it (it didn't
-- exist before that log).
function M.history_rows(id)
  local log = require('quickfix-review.log')
  local history = require('quickfix-review.history')
  local segment = require('quickfix-review.store.segment')
  id = id ~= '' and id or nil
  local function read(path)
    history_seen[path] = history_seen[path] or {}
    return log.read(path, 0, 0, history_seen[path])
  end
  local dir = store.events_dir()
  local segs = segment.list(dir)
  if #segs == 0 then
    -- A v2 log not migrated (its tombstone has no events)
    local res, err = read(store.log_path())
    if not res then return nil, err end
    return history.rows(res.events, id)
  end
  local events, count = {}, 0
  for i = #segs, 1, -1 do
    local r, err = read(segment.path(dir, segs[i]))
    if not r then
      if i == #segs then return nil, err end
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
    local uv = vim.uv or vim.loop
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
