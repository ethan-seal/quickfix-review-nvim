-- The event history of a review, for :ReviewHistory: its log's events (see
-- log.lua) as display rows. Pure: no I/O, so it is tested on plain events.
local M = {}

M.LIMIT = 50

-- The comment records an event touches: its `comment`, or the `comments`
-- of a clear or an import
local function records_of(ev)
  if type(ev.comment) == 'table' then return { ev.comment } end
  if type(ev.comments) == 'table' then return ev.comments end
  return {}
end

-- Whether the event concerns the comment `id`
local function touches(ev, id)
  if ev.id == id then return true end
  for _, r in ipairs(records_of(ev)) do
    if type(r) == 'table' and r.id == id then return true end
  end
  return false
end

-- A value on one line, cut to `max` characters
local function short(v, max)
  local s = type(v) == 'string' and v or vim.inspect(v, { newline = ' ', indent = '' })
  s = s:gsub('%s*\n%s*', ' ')
  if #s > max then s = s:sub(1, max - 3) .. '...' end
  return s
end

local function where(r)
  if type(r) ~= 'table' or type(r.filename) ~= 'string' then return '?' end
  local lnum = type(r.anchor) == 'table' and r.anchor.lnum or r.lnum
  return vim.fn.fnamemodify(r.filename, ':.') .. ':' .. tostring(lnum or '?')
end

-- "key: prev -> new" for each key an update sets (keys sorted), and
-- "key: prev -> (unset)" for each it unsets; prev is shown when logged
local function changes(ev)
  local out, prev = {}, type(ev.prev) == 'table' and ev.prev or {}
  local function change(k, v)
    local old = prev[k] ~= nil and (short(prev[k], 30) .. ' -> ') or ''
    table.insert(out, string.format('%s: %s%s', k, old, v))
  end
  local keys = type(ev.set) == 'table' and vim.tbl_keys(ev.set) or {}
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  for _, k in ipairs(keys) do change(k, short(ev.set[k], 30)) end
  for _, k in ipairs(type(ev.unset) == 'table' and ev.unset or {}) do change(k, '(unset)') end
  return table.concat(out, ', ')
end

-- The rows for `events` (in log order): every event about comment `id`, or,
-- without an id, the last `limit` (default M.LIMIT) events. Each row is
-- { ts, op, id, kind, where, changes, text }, `text` being the line shown.
function M.rows(events, id, limit)
  limit = limit or M.LIMIT
  -- The latest record seen for each id, so an update (which carries no
  -- record) can be shown with its comment's kind and place
  local known = {}
  local rows = {}
  for _, ev in ipairs(events) do
    if type(ev) == 'table' and ev.op ~= 'header' then
      for _, r in ipairs(records_of(ev)) do
        if type(r) == 'table' and type(r.id) == 'string' then known[r.id] = r end
      end
      if id == nil or touches(ev, id) then
        local recs = records_of(ev)
        local subject_id = id or ev.id or (#recs == 1 and recs[1].id or nil)
        local r = subject_id and known[subject_id]
        local row = {
          ts = ev.ts, op = tostring(ev.op), id = subject_id,
          kind = type(r) == 'table' and r.kind or nil,
          where = r and where(r) or (#recs > 1 and (#recs .. ' comments') or '?'),
          changes = ev.op == 'update' and changes(ev) or '',
        }
        local time = type(ev.ts) == 'number' and os.date('%Y-%m-%d %H:%M:%S', math.floor(ev.ts / 1000)) or '?'
        row.text = string.format('%s  %-7s %-10s %s%s%s', time, row.op,
          row.kind and row.kind:upper() or '-', row.where,
          row.id and (' [' .. row.id .. ']') or '',
          row.changes ~= '' and ('  ' .. row.changes) or '')
        table.insert(rows, row)
      end
      if ev.op == 'update' and type(ev.set) == 'table' and type(known[ev.id]) == 'table' then
        known[ev.id] = vim.tbl_extend('force', known[ev.id], ev.set)
      end
    end
  end
  if id == nil and #rows > limit then
    rows = vim.list_slice(rows, #rows - limit + 1, #rows)
  end
  return rows
end

return M
