-- The review's comments. The plugin owns them here rather than in the quickfix
-- list, so other tools that replace the quickfix list (LSP references, grep)
-- can't clobber the review. The source of truth is an append-only event log
-- (log.jsonl, see log.lua): every change is appended as an event, and the
-- comments are the log replayed through reduce.lua, so no change can lose
-- data. state.json is a cache of that replay, never needed for correctness.
-- Events another Neovim appends are picked up by reading the log's tail.
-- Comments are the storage schema's records (see storage.lua); the quickfix
-- list is only a view derived from them, which M.show() publishes.
--
-- This module is the store's public API; the work is done in store/:
-- record (a comment record), location (where the review is stored),
-- journal (the log read into memory, and its lock), migrate (getting a
-- review into a new log), maintenance (rotation, retention, snapshot GC),
-- view (the comments as shown, and the quickfix list) and sync (the order
-- those run in for a sync or a change).
local M = {}

local journal = require('quickfix-review.store.journal')
local location = require('quickfix-review.store.location')
local log = require('quickfix-review.log')
local maintenance = require('quickfix-review.store.maintenance')
local record = require('quickfix-review.store.record')
local reduce = require('quickfix-review.reduce')
local storage = require('quickfix-review.storage')
local sync = require('quickfix-review.store.sync')
local view = require('quickfix-review.store.view')

-- Where a comment is now, { sha, lnum, end_lnum, state } (see track.lua), or
-- nil for a record not read through the store (no id or anchor)
function M.pos(c)
  return record.pos(c)
end

-- Whether a comment's code changed since it was made (see track.lua)
function M.is_outdated(c)
  return record.is_outdated(c)
end

-- The lines a comment is displayed at (see record.range)
-- Returns: lnum, end_lnum
function M.range(c)
  return record.range(c)
end

-- A comment as displayed: "[KIND] body", or "[KIND:L1-5] body" for a range
function M.headline(c)
  return record.headline(c)
end

-- Test hook: how long a fallback root is kept before git is asked again
-- (a fallback memoized now is kept no longer than that either)
function M._set_retry_ns(ns)
  location._set_retry_ns(ns)
end

-- The comments.json of the review: the pre-log storage file, which is
-- migrated into the log (and renamed to comments.json.pre-log.bak) on first use
function M.path()
  return location.resolve().path
end

-- The review's event log, its source of truth
function M.log_path()
  return location.resolve().log
end

-- The cache of the replayed log
function M.state_path()
  return location.resolve().state
end

-- The directory of the review's file snapshots (see snapshots.lua):
-- `snapshots/` in the storage dir, or `<storage_file>.snapshots`
function M.snapshots_dir()
  return location.resolve().snapshots
end

-- The project's storage directory (for an explicit storage_file, its directory)
function M.dir()
  return location.resolve().dir
end

-- The project root the storage dir belongs to, or nil for an explicit storage_file
function M.root()
  return location.resolve().root
end

-- The rotated logs of the review, oldest first
function M.rotated_logs()
  return maintenance.rotated_logs()
end

-- Delete the review's unreferenced snapshots older than a day (see
-- maintenance.gc).
-- Returns: how many were deleted
function M.gc_snapshots()
  return maintenance.gc_snapshots()
end

-- Collect the snapshots of the review once this session, 5s after startup
-- (not in the test suite, which sets vim.g._quickfix_review_no_startup_gc)
function M.schedule_startup_gc()
  maintenance.schedule_startup_gc()
end

-- Call fn(loc, ...) with the location resolved once and pinned, so
-- everything it does (snapshots.put, syncs, a change) uses that location
-- even if a fallback root's retry window expires meanwhile. Nests; the
-- previous pin is restored even if fn errors.
-- Returns: what fn returns
function M.with_location(fn, ...)
  return location.with_location(fn, ...)
end

-- The whole change (see sync.mutate_at), with the location resolved once
-- and pinned (see with_location)
local function mutate(build, opts)
  return M.with_location(sync.mutate_at, build, opts)
end

-- Called after any change to the comments, including ones read from disk
function M.set_on_change(fn)
  view.set_on_change(fn)
end

-- Called after every refill of the list view with (qf_id, idx before,
-- idx after), so a selection the refill moved isn't taken for navigation
function M.set_on_refill(fn)
  view.set_on_refill(fn)
end

-- Redraw the quickfix view and call on_change after comments moved (a
-- relocation), without reading or writing the log: positions are never logged.
-- opts.defer_view refills the view after the current event (as for M.all).
function M.refresh(opts)
  view.render(opts and opts.defer_view)
end

-- All comments, in creation order. Treat as read-only.
-- opts.defer_view: for callers inside a buffer read or enter, where a
-- quickfix jump may be running: a change another Neovim logged refills the
-- list after the event, as refilling during the jump would abort it (E925).
function M.all(opts)
  sync.sync(opts and { defer_view = opts.defer_view } or nil)
  return view.comments()
end

-- Add a comment
-- Returns: true if it was added, false if it has no file or the change was refused
function M.add(item)
  return mutate(function()
    local c = record.normalize(item)
    if not c then return {}, false end
    return { log.event('add', { comment = storage.serialise(c) }) }, true
  end) == true
end

-- The comment with this id, or nil. Treat as read-only.
function M.get(id)
  sync.sync()
  for _, c in ipairs(view.comments()) do
    if c.id == id then return c end
  end
  return nil
end

-- The deleted comments, by id (kept in the log, so they can be restored).
-- Treat as read-only.
function M.trash()
  sync.sync()
  local reduced = journal.reduced()
  local out = {}
  for id, r in pairs(reduced.trash) do
    out[id] = view.view_of(r) or r
  end
  return out
end

-- The deleted comments, newest removal first: { id, op ('delete' or
-- 'clear'), ts (unix ms, or nil), comment (its view, or the raw record) }
function M.trash_list()
  sync.sync()
  local reduced = journal.reduced()
  local out = {}
  for i = #reduced.removed, 1, -1 do
    local e = reduced.removed[i]
    local r = reduced.trash[e.id]
    if r then
      table.insert(out, { id = e.id, op = e.op, ts = e.ts, comment = view.view_of(r) or r })
    end
  end
  return out
end

-- The most recent removal: { op = 'delete', ids = { id } } for a delete, or
-- { op = 'clear', ids = {...} } holding every comment of the last clear still
-- in the trash; nil when the trash is empty
function M.last_removal()
  sync.sync()
  local reduced = journal.reduced()
  local last = reduced.removed[#reduced.removed]
  if not last then return nil end
  if last.op ~= 'clear' or last.eid == nil then return { op = last.op, ids = { last.id } } end
  local ids = {}
  for _, e in ipairs(reduced.removed) do
    if e.eid == last.eid and reduced.trash[e.id] then table.insert(ids, e.id) end
  end
  return { op = 'clear', ids = ids }
end

-- Make deleted comments live again: one restore event, holding the logged
-- record, per id in the trash, all in one append. An id that is live, or
-- in neither the review nor the trash, is skipped (nothing is logged for it).
-- Returns: { restored = n, live = { id... }, unknown = { id... } }, or nil
-- if the change was refused
function M.restore(ids)
  return mutate(function()
    local reduced = journal.reduced()
    local events, res, seen = {}, { restored = 0, live = {}, unknown = {} }, {}
    for _, id in ipairs(ids) do
      local r = reduced.trash[id]
      if seen[id] then
        -- listed twice: restored (or reported) once
      elseif reduce.get(reduced, id) then
        table.insert(res.live, id)
      elseif not r then
        table.insert(res.unknown, id)
      else
        table.insert(events, log.event('restore', { id = id, comment = r }))
      end
      seen[id] = true
    end
    res.restored = #events
    return events, res
  end)
end

-- Whether two anchors name different lines of different content
local function anchor_changed(old, new)
  old = old or {}
  return old.sha ~= new.sha or old.lnum ~= new.lnum or old.end_lnum ~= new.end_lnum
end

-- Re-anchor comments: `changes` is a list of { id = ..., anchor = { sha,
-- lnum, end_lnum, lines, before, after } }. One update event per comment
-- whose anchor actually changes, setting the anchor and the record's
-- top-level lnum/end_lnum to match (never pos, which is derived and kept in
-- memory only), with the previous values in `prev`. A comment that is gone,
-- or an anchor with no snapshot sha, is skipped.
-- opts.defer_view: as for M.all.
-- Returns: number of comments updated, or nil if the change was refused
function M.update(changes, opts)
  return mutate(function()
    local reduced = journal.reduced()
    local events = {}
    for _, ch in ipairs(changes) do
      local a = record.parse_anchor(ch.anchor)
      local r = reduce.get(reduced, ch.id)
      if r and a and a.sha and anchor_changed(r.anchor, a) then
        table.insert(events, log.event('update', {
          id = ch.id,
          set = { anchor = a, lnum = a.lnum, end_lnum = a.end_lnum },
          prev = { anchor = r.anchor, lnum = r.lnum, end_lnum = r.end_lnum },
        }))
      end
    end
    return events, #events
  end, opts)
end

-- Change a comment's text: one update event setting its body, with the
-- previous body (as shown, so a legacy record's `text`) in `prev`. Nothing is
-- logged when the comment is gone or the body is unchanged.
-- Returns: 'edited', 'unchanged', 'missing' (no live comment with this id),
-- or nil if the body isn't a non-empty string or the change was refused
function M.edit(id, body)
  if type(body) ~= 'string' or body == '' then return nil end
  return mutate(function()
    local r = reduce.get(journal.reduced(), id)
    local c = r and view.view_of(r)
    if not c then return {}, 'missing' end
    if c.body == body then return {}, 'unchanged' end
    return { log.event('update', { id = id, set = { body = body }, prev = { body = c.body } }) }, 'edited'
  end)
end

-- Remove every comment for which pred(comment) is true: one delete event,
-- holding the comment, per match
-- Returns: number removed, or nil if the change was refused (unreadable file)
-- or failed, and then 'partial' when some of the deletes may have landed
function M.remove_if(pred)
  return mutate(function()
    local events = {}
    for _, r in ipairs(journal.reduced().comments) do
      local c = view.view_of(r)
      if c and pred(c) then
        table.insert(events, log.event('delete', { id = r.id, comment = r }))
      end
    end
    return events, #events
  end)
end

-- Remove the comment with this id
-- Returns: number removed (0 if there is none), or nil if the change was
-- refused or failed (and 'partial', as for remove_if)
function M.remove(id)
  return M.remove_if(function(c) return c.id == id end)
end

-- Remove every comment (one clear event holding them all)
-- Returns: true, or nil if the change was refused
function M.clear()
  return mutate(function()
    local reduced = journal.reduced()
    if #reduced.comments == 0 then return {}, true end
    return { log.event('clear', { comments = reduced.comments }) }, true
  end)
end

-- Replay the whole log, ignoring the cache
-- Returns: ok (boolean), message (string)
function M.reload()
  local ok, err = sync.sync({ full = true })
  if not ok then return false, err end
  return true, string.format('Review loaded: %d comments', #view.comments())
end

-- Write the cache (state.json) now. Every change is already in the log, so
-- this is never needed for the review to be saved.
-- Returns: ok (boolean), message (string)
function M.save()
  local ok, err = sync.sync()
  if not ok then return false, err end
  if journal.readonly() then
    local loc = location.resolve()
    return false, string.format('%s is not writable: %s is shown read-only', loc.dir, loc.path)
  end
  local synced = journal.synced()
  if not synced.log_id then
    return true, 'Review saved (no comments yet)'
  end
  local wrote, werr = journal.flush(true)
  if not wrote then
    return false, 'Could not write ' .. synced.state .. ': ' .. tostring(werr)
  end
  return true, string.format('Review saved to %s (%d comments)', synced.log, #view.comments())
end

-- Write the cache if events were applied since it was last written (on exit)
function M.flush()
  journal.flush()
end

-- Publish the comments as a quickfix list and make it the current one
function M.show()
  M.all()
  view.show()
end

-- Whether the current quickfix list is the review view
function M.is_current_view()
  return view.is_current_view()
end

return M
