-- The :ReviewHistory view: the event history rows of a comment or of the
-- last events, read from the review's log and its rotated logs.
local M = {}

local store = require('quickfix-review.store')

-- The unreadable lines of each log (by log_id, else path) already warned
-- about, so :ReviewHistory warns about each once rather than on every call
local history_seen = {}

-- The event history rows of comment `id`, or of the last 50 events. The
-- rotated logs are read too, newest first, back only as far as needed: for
-- the last 50, until there are 50 events; for a comment, until a log whose
-- checkpoint doesn't know it (it didn't exist before that log).
function M.history_rows(id)
  local log = require('quickfix-review.log')
  local history = require('quickfix-review.history')
  id = id ~= '' and id or nil
  local function read(path)
    local key = log.read_id(path) or path
    history_seen[key] = history_seen[key] or {}
    return log.read(path, 0, 0, history_seen[key])
  end
  local res, err = read(store.log_path())
  if not res then return nil, err end
  local events, count = res.events, 0
  local function counts(evs)
    for _, ev in ipairs(evs) do
      if ev.op ~= 'checkpoint' then count = count + 1 end
    end
  end
  counts(events)
  -- The logs read, by log_id: a rotation that crashed after linking the log
  -- to its rotated name leaves that log under two names (or more, once it is
  -- rotated again). The newest one read holds all of it, so the older copies
  -- are skipped.
  local ids = {}
  if res.log_id then ids[res.log_id] = true end
  local older = store.rotated_logs()
  for i = #older, 1, -1 do
    local first = events[1]
    if not (first and first.op == 'checkpoint') then break end
    if id == nil and count >= history.LIMIT then break end
    if id ~= nil and not history.checkpoint_knows(first, id) then break end
    local r = read(older[i])
    if not r then break end
    if not (r.log_id and ids[r.log_id]) then
      if r.log_id then ids[r.log_id] = true end
      counts(r.events)
      events = vim.list_extend(vim.list_extend({}, r.events), events)
    end
  end
  return history.rows(events, id)
end

-- Print the event history of comment `id`, or the last 50 events
function M.history(id)
  local rows, err = M.history_rows(id)
  if not rows then
    print((vim.uv or vim.loop).fs_stat(store.log_path()) and tostring(err) or 'No review history yet')
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
