-- The reducer of the event log (see log.lua): folds events, in file order,
-- into the review's state. No I/O and no notifications, so replaying a log
-- always gives the same state.
--
-- State: { comments = { record... }, trash = { [id] = record },
-- removed = { { id, op, eid, ts }... }, rebases = { from_root... } }. `comments` are the live comments in
-- the order they were added; `trash` holds the deleted comments, so they can
-- be restored. `removed` lists the trashed ids in the (file) order they were
-- removed, with the removing event's op ('delete' or 'clear'), eid and ts:
-- the comments of one clear share its eid. Both are bounded: after each
-- delete, clear or checkpoint only the newest M.TRASH_KEEP removals are kept,
-- plus every removal of the newest removing event (a clear is never cut in
-- half); older ones are dropped from both (see prune). The events stay in
-- the journal. `rebases` lists the old project
-- roots of the review (rebase events, written by store/adopt.lua), in the
-- order they were logged: an absolute filename under one of them is shown
-- under the current root (record.resolve_filename). Records are comment records in
-- the storage format (storage.serialise), as they appear in the log.
--
-- `index` = { by_id = { [id] = record } } maps each live comment's id to its
-- record in `comments`. It lives in memory only: every function here that
-- changes `comments` keeps it current, M.reindex rebuilds it, and it is never
-- serialised (encode M.persisted(state), not the state itself).
--
-- Rules:
-- - add (and each comment of an import) of an id that is live or still in
--   the trash is ignored, so appending the same event twice changes nothing.
--   An id pruned from the trash is no longer known: an add of it is applied.
-- - update and delete of an unknown or deleted id are ignored: nothing is
--   ever resurrected by them.
-- - delete and clear move comments to the trash; restore makes a trashed (or
--   unknown) comment live again with the logged content, and is ignored for a
--   live one.
-- - checkpoint (the first event of a rotated v2 log) replaces the whole
--   state with its `state` ({ comments, trash, removed }; any `index` there
--   is ignored and rebuilt); a malformed one is ignored. Replaying a journal,
--   it applies only in segment 1 (see apply_in_segment). Its `rebases` is
--   optional (v2 rotation checkpoints have none): when absent, the state's
--   rebases are kept.
-- - rebase adds its from_root to `rebases`; one already there is ignored
--   silently (never 'duplicate': it is not a comment).
local M = {}

-- The shape of the state a checkpoint (store/checkpoint.lua) holds. Bump it
-- when that shape changes: checkpoints of another STATE_VERSION are ignored
-- and rebuilt by replaying the events (docs/journal.md#checkpoints).
M.STATE_VERSION = 3

-- How many removals `trash`/`removed` keep (see prune). A module constant,
-- never a user option: replay and checkpoints must agree for every config.
M.TRASH_KEEP = 1000

function M.new()
  return { comments = {}, trash = {}, removed = {}, rebases = {}, index = { by_id = {} } }
end

-- Rebuild state.index from state.comments (O(n)); returns state. The first
-- record of an id wins, as a lookup by scanning `comments` would give.
function M.reindex(state)
  local by_id = {}
  for _, c in ipairs(state.comments) do
    if by_id[c.id] == nil then by_id[c.id] = c end
  end
  state.index = { by_id = by_id }
  return state
end

-- The serialisable part of state: everything but the in-memory index
function M.persisted(state)
  return { comments = state.comments, trash = state.trash, removed = state.removed, rebases = state.rebases }
end

-- A comment record: a table with a non-empty string id
local function valid(record)
  return type(record) == 'table' and type(record.id) == 'string' and record.id ~= ''
end
M.valid = valid

-- The position of record c in state.comments (O(n), by identity)
local function position(state, c)
  for i, x in ipairs(state.comments) do
    if x == c then return i end
  end
  return nil
end

local function add(state, record)
  if not valid(record) then return 'invalid' end
  if state.trash[record.id] or state.index.by_id[record.id] then return 'duplicate' end
  table.insert(state.comments, record)
  state.index.by_id[record.id] = record
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
  local c = state.index.by_id[id]
  if not c then return 'unknown' end
  table.remove(state.comments, position(state, c))
  -- A malformed checkpoint or cache may hold another record of this id: it
  -- becomes the one found, as the first-wins reindex would give (O(n); rare)
  local next_c
  for _, x in ipairs(state.comments) do
    if x.id == id then
      next_c = x
      break
    end
  end
  state.index.by_id[id] = next_c
  state.trash[id] = c
  -- ts is informational: a hand-edited or foreign log may hold anything there
  table.insert(state.removed, { id = id, op = ev.op, eid = ev.eid, ts = type(ev.ts) == 'number' and ev.ts or nil })
  return nil
end

-- Drop the oldest removals from state.removed, and their records from
-- state.trash, until at most M.TRASH_KEEP are left. The removals of the
-- newest removing event (those sharing the last entry's non-nil eid, which
-- are contiguous at the end) are never dropped, so undo of the last delete
-- or clear stays complete. Call once per event, never per comment of a clear.
local function prune(state)
  local removed = state.removed
  local n = #removed
  local drop = n - M.TRASH_KEEP
  if drop <= 0 then return end
  local eid = removed[n].eid
  if eid ~= nil then
    local first = n
    while first > 1 and removed[first - 1].eid == eid do first = first - 1 end
    drop = math.min(drop, first - 1)
  end
  if drop <= 0 then return end
  for i = 1, drop do state.trash[removed[i].id] = nil end
  local kept = {}
  for i = drop + 1, n do kept[i - drop] = removed[i] end
  state.removed = kept
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
  local c = state.index.by_id[ev.id]
  if not c then return 'unknown' end
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
  -- The position scan is O(n): records are replaced, so it cannot be cached
  state.comments[position(state, c)] = new
  state.index.by_id[ev.id] = new
  return nil
end

function handlers.delete(state, ev)
  if type(ev.id) ~= 'string' then return 'invalid' end
  local why = trash(state, ev.id, ev)
  if not why then prune(state) end
  return why
end

-- Only the comments the clear lists are trashed, so a comment added by
-- another instance that the clearing one had not seen survives
function handlers.clear(state, ev)
  if type(ev.comments) ~= 'table' then return 'invalid' end
  for _, record in ipairs(ev.comments) do
    if valid(record) then trash(state, record.id, ev) end
  end
  prune(state)
  return nil
end

function handlers.restore(state, ev)
  if not valid(ev.comment) or (ev.id ~= nil and ev.id ~= ev.comment.id) then return 'invalid' end
  local id = ev.comment.id
  if state.index.by_id[id] then return 'live' end
  state.trash[id] = nil
  unremove(state, id)
  table.insert(state.comments, ev.comment)
  state.index.by_id[id] = ev.comment
  return nil
end

-- The state of a v2 log up to a rotation, which the rotated-to log started
-- with: replaces the whole state. Records are kept as logged.
function handlers.checkpoint(state, ev)
  local s = ev.state
  if type(s) ~= 'table' or type(s.comments) ~= 'table' or type(s.trash) ~= 'table'
      or type(s.removed) ~= 'table' then
    return 'invalid'
  end
  for _, record in ipairs(s.comments) do
    if not valid(record) then return 'invalid' end
  end
  for id, record in pairs(s.trash) do
    if type(id) ~= 'string' or not valid(record) or record.id ~= id then return 'invalid' end
  end
  for _, e in ipairs(s.removed) do
    if type(e) ~= 'table' or type(e.id) ~= 'string' then return 'invalid' end
  end
  if s.rebases ~= nil then
    if type(s.rebases) ~= 'table' then return 'invalid' end
    for _, root in ipairs(s.rebases) do
      if type(root) ~= 'string' then return 'invalid' end
    end
  end
  local comments, trashed, removed = {}, {}, {}
  for i, record in ipairs(s.comments) do comments[i] = record end
  for id, record in pairs(s.trash) do trashed[id] = record end
  for i, e in ipairs(s.removed) do
    removed[i] = { id = e.id, op = e.op, eid = e.eid, ts = type(e.ts) == 'number' and e.ts or nil }
  end
  state.comments, state.trash, state.removed = comments, trashed, removed
  prune(state)
  if s.rebases ~= nil then
    local rebases = {}
    for i, root in ipairs(s.rebases) do rebases[i] = root end
    state.rebases = rebases
  end
  M.reindex(state)
  return nil
end

-- The review was adopted from a project whose root was `from_root` (an
-- absolute path, no trailing '/'): its absolute filenames under that root
-- are shown under the current one. Permanent, so replay is deterministic.
function handlers.rebase(state, ev)
  local root = ev.from_root
  if type(root) ~= 'string' or root:sub(1, 1) ~= '/' or root:sub(-1) == '/' then return 'invalid' end
  state.rebases = state.rebases or {}
  for _, r in ipairs(state.rebases) do
    if r == root then return nil end
  end
  table.insert(state.rebases, root)
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

-- Apply event `ev` read from journal segment `seg` (1 = the first). A
-- checkpoint event (only migrated v2 segments hold them) replaces the state
-- only in segment 1, where it is the base the events after it build on (the
-- logs before it were deleted by v2 retention). In a later segment it is
-- skipped: the segments before it hold every event it summarises.
-- Returns: as apply
function M.apply_in_segment(state, seg, ev)
  if type(ev) == 'table' and ev.op == 'checkpoint' and seg ~= 1 then return state, 'superseded' end
  return M.apply(state, ev)
end

-- Set into[id] = true for every comment id raw event `ev` mentions: added,
-- imported, restored, updated, deleted or cleared ones, and every id in a
-- checkpoint event's state (live, trashed or removed), read before any
-- pruning. Tolerates malformed events (they add nothing).
-- Returns: into
function M.event_ids(ev, into)
  if type(ev) ~= 'table' then return into end
  local function note(id)
    if type(id) == 'string' then into[id] = true end
  end
  local function note_records(list)
    if type(list) ~= 'table' then return end
    for _, r in ipairs(list) do
      if type(r) == 'table' then note(r.id) end
    end
  end
  local op = ev.op
  if op == 'add' or op == 'restore' then
    if type(ev.comment) == 'table' then note(ev.comment.id) end
  elseif op == 'import' or op == 'clear' then
    note_records(ev.comments)
  elseif op == 'delete' or op == 'update' then
    note(ev.id)
  elseif op == 'checkpoint' and type(ev.state) == 'table' then
    local s = ev.state
    note_records(s.comments)
    if type(s.trash) == 'table' then
      for id in pairs(s.trash) do note(id) end
    end
    note_records(s.removed)
  end
  return into
end

-- The live record with this id, or nil
function M.get(state, id)
  return state.index.by_id[id]
end

return M
