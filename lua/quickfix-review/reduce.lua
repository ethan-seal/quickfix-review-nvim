-- The reducer of the event log (see log.lua): folds events, in file order,
-- into the review's state. No I/O and no notifications, so replaying a log
-- always gives the same state.
--
-- State: { comments = { record... }, trash = { [id] = record },
-- removed = { { id, op, eid, ts }... } }. `comments` are the live comments in
-- the order they were added; `trash` holds every deleted comment, so it can
-- be restored. `removed` lists the trashed ids in the (file) order they were
-- removed, with the removing event's op ('delete' or 'clear'), eid and ts:
-- the comments of one clear share its eid. Records are comment records in
-- the storage format (storage.serialise), as they appear in the log.
--
-- Rules:
-- - add (and each comment of an import) of an id that is live or in the
--   trash is ignored, so appending the same event twice changes nothing.
-- - update and delete of an unknown or deleted id are ignored: nothing is
--   ever resurrected by them.
-- - delete and clear move comments to the trash; restore makes a trashed (or
--   unknown) comment live again with the logged content, and is ignored for a
--   live one.
local M = {}

function M.new()
  return { comments = {}, trash = {}, removed = {} }
end

local function valid(record)
  return type(record) == 'table' and type(record.id) == 'string' and record.id ~= ''
end

local function find(state, id)
  for i, c in ipairs(state.comments) do
    if c.id == id then return i, c end
  end
  return nil
end

local function add(state, record)
  if not valid(record) then return 'invalid' end
  if state.trash[record.id] or find(state, record.id) then return 'duplicate' end
  table.insert(state.comments, record)
  return nil
end

-- Drop id's entry from state.removed
local function unremove(state, id)
  for i = #state.removed, 1, -1 do
    if state.removed[i].id == id then table.remove(state.removed, i) end
  end
end

-- Move a live comment to the trash, recording the removing event `ev`
local function trash(state, id, ev)
  local i, c = find(state, id)
  if not i then return 'unknown' end
  table.remove(state.comments, i)
  state.trash[id] = c
  table.insert(state.removed, { id = id, op = ev.op, eid = ev.eid, ts = ev.ts })
  return nil
end

local handlers = {}

function handlers.header() return nil end

function handlers.add(state, ev)
  return add(state, ev.comment)
end

function handlers.import(state, ev)
  if type(ev.comments) ~= 'table' then return 'invalid' end
  local ignored
  for _, record in ipairs(ev.comments) do
    ignored = add(state, record) or ignored
  end
  return ignored
end

-- set is applied before unset; the record is replaced, not changed in place,
-- so a record held by an earlier state (or the caller) is never modified
function handlers.update(state, ev)
  if type(ev.id) ~= 'string' then return 'invalid' end
  local i, c = find(state, ev.id)
  if not i then return 'unknown' end
  local new = {}
  for k, v in pairs(c) do new[k] = v end
  if type(ev.set) == 'table' then
    for k, v in pairs(ev.set) do
      if k ~= 'id' then new[k] = v end
    end
  end
  if type(ev.unset) == 'table' then
    for _, k in ipairs(ev.unset) do
      if k ~= 'id' then new[k] = nil end
    end
  end
  state.comments[i] = new
  return nil
end

function handlers.delete(state, ev)
  if type(ev.id) ~= 'string' then return 'invalid' end
  return trash(state, ev.id, ev)
end

-- Only the comments the clear lists are trashed, so a comment added by
-- another instance that the clearing one had not seen survives
function handlers.clear(state, ev)
  if type(ev.comments) ~= 'table' then return 'invalid' end
  for _, record in ipairs(ev.comments) do
    if valid(record) then trash(state, record.id, ev) end
  end
  return nil
end

function handlers.restore(state, ev)
  if not valid(ev.comment) or (ev.id ~= nil and ev.id ~= ev.comment.id) then return 'invalid' end
  local id = ev.comment.id
  if find(state, id) then return 'live' end
  state.trash[id] = nil
  unremove(state, id)
  table.insert(state.comments, ev.comment)
  return nil
end

-- Apply one event to `state` (updated in place and returned)
-- Returns: state, and why the event was ignored ('duplicate', 'unknown',
-- 'live', 'invalid', 'unknown op'), or nil if it was applied
function M.apply(state, ev)
  local handler = type(ev) == 'table' and handlers[ev.op]
  if not handler then return state, 'unknown op' end
  return state, handler(state, ev)
end

-- The live record with this id, or nil
function M.get(state, id)
  local _, c = find(state, id)
  return c
end

return M
