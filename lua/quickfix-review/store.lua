-- The review's comments. The plugin owns them here rather than in the quickfix
-- list, so other tools that replace the quickfix list (LSP references, grep)
-- can't clobber the review. The source of truth is an append-only event
-- journal (events/, numbered segments, see docs/journal.md and log.lua):
-- every change is appended as an event, and the comments are the journal
-- replayed through reduce.lua, so no change can lose data. Checkpoints
-- (checkpoints/) are disposable caches of that replay, never needed for
-- correctness. Events another Neovim appends are picked up by reading the
-- journal's tail.
-- Comments are the storage schema's records (see storage.lua); the quickfix
-- list is only a view derived from them, which M.show() publishes.
--
-- This module is the store's public API; the work is done in store/:
-- record (a comment record), location (where the review is stored),
-- journal (the journal read into memory, sealed and checkpointed),
-- segment and checkpoint (its files), lock, migrate (getting a review into
-- a journal, from comments.json or a v2 log), maintenance (snapshot GC),
-- view (the comments as shown, and the quickfix list) and sync (the order
-- those run in for a sync or a change).
local M = {}

local adopt = require('quickfix-review.store.adopt')
local journal = require('quickfix-review.store.journal')
local location = require('quickfix-review.store.location')
local log = require('quickfix-review.log')
local maintenance = require('quickfix-review.store.maintenance')
local record = require('quickfix-review.store.record')
local snapshots = require('quickfix-review.snapshots')
local storage = require('quickfix-review.storage')
local sync = require('quickfix-review.store.sync')
local utils = require('quickfix-review.utils')
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

-- Test hook: how close together debounced syncs (M.all with debounce) are
-- skipped
function M._set_sync_debounce_ns(ns)
  sync._set_debounce_ns(ns)
end

-- The comments.json of the review: the pre-log storage file, which is
-- migrated into the journal (and renamed to comments.json.pre-log.bak) on first use
function M.path()
  return location.resolve().path
end

-- The review's v2 log.jsonl: once migrated, the tombstone pointing at
-- events/ (docs/journal.md#migration)
function M.log_path()
  return location.resolve().log
end

-- The review's journal: its directory of event segments, the source of truth
function M.events_dir()
  return location.resolve().events
end

-- The review's checkpoints (disposable caches of the replayed journal)
function M.checkpoints_dir()
  return location.resolve().checkpoints
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

-- Delete the review's unreferenced snapshots older than a day, at most once
-- a day unless `opts.force` (see maintenance.gc).
-- Returns: how many were deleted
function M.gc_snapshots(opts)
  return maintenance.gc_snapshots(opts)
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
-- opts.debounce: for autocmds that fire in bursts (BufEnter, CursorHold):
-- skip the sync when the last such one ran under 200 ms ago with no other
-- sync since, in the same review (see sync.sync).
function M.all(opts)
  sync.sync(opts and { defer_view = opts.defer_view, debounce = opts.debounce } or nil)
  return view.comments()
end

-- The comments on the file whose utils.path_key is `key`, as of the last
-- sync (none is run: call all() first to sync), in creation order. Treat
-- as read-only.
function M.in_file(key)
  return view.in_file(key)
end

-- Add a comment
-- Returns: true if it was added, or false if it has no file or the change was
-- refused, and then the reason (a string, when one is known)
function M.add(item)
  local res, _, err = mutate(function()
    local c = record.normalize(item)
    if not c then return {}, false end
    -- Written root-relative in a per-project dir (see record.relativize);
    -- resolve() returns the location the change pinned
    local stored = record.relativize(storage.serialise(c), location.resolve())
    return { log.event('add', { comment = stored }) }, true
  end)
  if res == true then return true end
  return false, err
end

-- The comment with this id, or nil. Treat as read-only.
function M.get(id)
  sync.sync()
  return view.get(id)
end

-- The deleted comments, by id (kept in the log, so they can be restored).
-- Treat as read-only.
function M.trash()
  sync.sync()
  local root = location.resolve().root
  local out = {}
  for id, r in pairs(journal.trash()) do
    out[id] = view.view_of(r, root, journal.rebases()) or r
  end
  return out
end

-- The deleted comments, newest removal first: { id, op ('delete' or
-- 'clear'), ts (unix ms, or nil), comment (its view, or the raw record) }
function M.trash_list()
  sync.sync()
  local root = location.resolve().root
  local removed = journal.removed()
  local out = {}
  for i = #removed, 1, -1 do
    local e = removed[i]
    local r = journal.trashed(e.id)
    if r then
      table.insert(out, { id = e.id, op = e.op, ts = e.ts, comment = view.view_of(r, root, journal.rebases()) or r })
    end
  end
  return out
end

-- The most recent removal: { op = 'delete', ids = { id } } for a delete, or
-- { op = 'clear', ids = {...} } holding every comment of the last clear still
-- in the trash; nil when the trash is empty
function M.last_removal()
  sync.sync()
  local removed = journal.removed()
  local last = removed[#removed]
  if not last then return nil end
  if last.op ~= 'clear' or last.eid == nil then return { op = last.op, ids = { last.id } } end
  local ids = {}
  for _, e in ipairs(removed) do
    if e.eid == last.eid and journal.trashed(e.id) then table.insert(ids, e.id) end
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
    local events, res, seen = {}, { restored = 0, live = {}, unknown = {} }, {}
    for _, id in ipairs(ids) do
      local r = journal.trashed(id)
      if seen[id] then
        -- listed twice: restored (or reported) once
      elseif journal.get(id) then
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
    local events = {}
    for _, ch in ipairs(changes) do
      local a = record.parse_anchor(ch.anchor)
      local r = journal.get(ch.id)
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

-- The events key of the review now (location.resolve().events): pass it to
-- set_context so a context found later is logged only in that review
function M.review_key()
  return location.resolve().events
end

-- A fresh comment id, for a caller that needs it before add (see set_context)
function M.new_id()
  return record.new_id()
end

-- Set the git context of comment `id`, found after it was added: one update
-- event setting `context`, with the previous one in `prev`. Nothing is
-- logged when the review is no longer the one whose key (review_key()) is
-- `key`, the comment is gone, or the context is unchanged.
-- Returns: true if it was logged, false if not (or nil if refused)
function M.set_context(key, id, ctx)
  if location.resolve().events ~= key then return false end
  return mutate(function()
    -- The location is pinned; the sync inside the lock may still have found
    -- the journal switched, so compare against what it now holds
    if location.resolve().events ~= key or journal.key() ~= key then return {}, false end
    local r = journal.get(id)
    if not r or vim.deep_equal(r.context, ctx) then return {}, false end
    return { log.event('update', { id = id, set = { context = ctx }, prev = { context = r.context } }) }, true
  end)
end

-- Change a comment's text: one update event setting its body, with the
-- previous body (as shown, so a legacy record's `text`) in `prev`. Nothing is
-- logged when the comment is gone or the body is unchanged.
-- Returns: 'edited', 'unchanged', 'missing' (no live comment with this id),
-- or nil if the body isn't a non-empty string or the change was refused, and
-- then the reason (a string, when one is known)
function M.edit(id, body)
  if type(body) ~= 'string' or body == '' then return nil end
  local res, _, err = mutate(function()
    local r = journal.get(id)
    local c = r and view.view_of(r, location.resolve().root, journal.rebases())
    if not c then return {}, 'missing' end
    if c.body == body then return {}, 'unchanged' end
    return { log.event('update', { id = id, set = { body = body }, prev = { body = c.body } }) }, 'edited'
  end)
  if res == nil then return nil, err end
  return res
end

-- Remove every comment for which pred(comment) is true: one delete event,
-- holding the comment, per match
-- Returns: number removed, or nil if the change was refused (unreadable file)
-- or failed, and then 'partial' when some of the deletes may have landed
function M.remove_if(pred)
  return mutate(function()
    local root = location.resolve().root
    local events = {}
    for _, r in ipairs(journal.comments()) do
      local c = view.view_of(r, root, journal.rebases())
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
    local comments = journal.comments()
    if #comments == 0 then return {}, true end
    return { log.event('clear', { comments = comments }) }, true
  end)
end

-- Replay the whole journal, ignoring its checkpoints
-- Returns: ok (boolean), message (string)
function M.reload()
  local ok, err = sync.sync({ full = true })
  if not ok then return false, err end
  return true, string.format('Review loaded: %d comments', #view.comments())
end

-- Copy the review in storage dir `dir` (an orphaned one: the dir of the
-- project before it was moved, see store/adopt.lua) into the current
-- project's storage dir, which must hold no review, then load it.
-- Returns: ok (boolean), message (string)
function M.adopt(dir)
  local ok, res = adopt.adopt(dir)
  if not ok then return false, 'Not adopting ' .. tostring(dir) .. ': ' .. tostring(res) end
  local sok, serr = sync.sync({ full = true })
  if not sok then return false, 'Adopted ' .. dir .. ', but could not load it: ' .. tostring(serr) end
  return true, string.format('Adopted the review in %s: %d comments (%d segments copied to %s)', dir,
    #view.comments(), res, location.resolve().events)
end

-- Write a checkpoint at the end of the journal now. Every change is
-- already in the journal, so this is never needed for the review to be
-- saved: it only makes the next load quicker.
-- Returns: ok (boolean), message (string)
function M.save()
  local ok, err = sync.sync()
  if not ok then return false, err end
  local loc = location.resolve()
  local mode = journal.mode()
  if mode == 'readonly' then
    return false, string.format('%s is not writable: %s is shown read-only', loc.dir, loc.path)
  end
  if mode == nil then return true, 'Review saved (no comments yet)' end
  if mode == 'v2' then
    return true, string.format('Review saved to %s (%d comments; not migrated, so no checkpoint)', loc.log,
      #view.comments())
  end
  local wrote, werr = journal.flush(true)
  if not wrote then
    return false, 'Could not write a checkpoint in ' .. loc.checkpoints .. ': ' .. tostring(werr)
  end
  return true, string.format('Review saved to %s (%d comments; checkpoint written)', loc.events, #view.comments())
end

-- Write a checkpoint if events were read past the newest one (on exit)
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

-- utils (a leaf) reaches the store and snapshots through these
utils.bind_store({
  range = function(c) return M.range(c) end,
  is_outdated = function(c) return M.is_outdated(c) end,
  hash = function(lines) return snapshots.hash(lines) end,
})

return M
