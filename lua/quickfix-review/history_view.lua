-- The :ReviewHistory view: the event history rows of a comment or of the
-- last events, read from the review's journal segments.
local M = {}

local history = require('quickfix-review.history')
local journal = require('quickfix-review.store.journal')
local location = require('quickfix-review.store.location')
local log = require('quickfix-review.log')
local record = require('quickfix-review.store.record')
local segment = require('quickfix-review.store.segment')
local store = require('quickfix-review.store')
local sync = require('quickfix-review.store.sync')

local uv = vim.uv or vim.loop

-- The unreadable lines of each file (by path) already warned about, so
-- :ReviewHistory warns about each once rather than on every call
local history_seen = {}

-- The event history rows of comment `id`, or of the last 50 events. The
-- journal's segments are read newest first: for the last 50, only back
-- until there are 50 events; for a comment, all of them.
function M.history_rows(id)
  id = id ~= '' and id or nil
  local function read(path)
    history_seen[path] = history_seen[path] or {}
    return log.read(path, 0, 0, history_seen[path])
  end
  local loc = location.resolve()
  -- This project's journal, for its rebases (see below): loaded if another
  -- project's is (e.g. after a :cd with no sync since); a sync otherwise
  -- would read (and warn about) what is read below
  if journal.key() ~= loc.events then
    sync.sync()
    loc = location.resolve()
  end
  local segs = segment.list(loc.events)
  if #segs == 0 then return nil, 'no segments in ' .. loc.events end
  local events = {}
  for i = #segs, 1, -1 do
    local r, err = read(segment.path(loc.events, segs[i]))
    if not r then
      if i == #segs then return nil, err end
      break
    end
    events = vim.list_extend(vim.list_extend({}, r.events), events)
    if id == nil and #events >= history.LIMIT then break end
  end
  -- Logged filenames resolved as the store does: a relative one against the
  -- project root (not the cwd), an absolute one under an old root (from
  -- before an adopt) under the current root
  local root, rebases = loc.root, journal.rebases()
  return history.rows(events, id, nil, function(f) return record.resolve_filename(f, root, rebases) end)
end

-- Print the event history of comment `id`, or the last 50 events
function M.history(id)
  local rows, err = M.history_rows(id)
  if not rows then
    local exists = uv.fs_stat(store.events_dir())
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
