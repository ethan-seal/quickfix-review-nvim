-- Bringing the comments up to date with the journal (sync_data, sync) and
-- making a change (mutate_at): the order in which journal, migrate and view
-- are called, under the lock or after it.
local M = {}

local journal = require('quickfix-review.store.journal')
local location = require('quickfix-review.store.location')
local migrate = require('quickfix-review.store.migrate')
local view = require('quickfix-review.store.view')

-- Bumped by every sync_data, so a debounced sync can tell whether any other
-- sync (or change) ran since the last one
local generation = 0
-- The last debounced sync that read the journal: { ns, gen, key }
local last_debounced = nil
local DEBOUNCE_NS = 200e6

-- Test hook: how close together debounced syncs are skipped
function M._set_debounce_ns(ns)
  DEBOUNCE_NS = ns
  last_debounced = nil
end

-- Whether a debounced sync can be skipped: the previous one ran less than
-- DEBOUNCE_NS ago, no other sync ran since, and the review is the same
local function recently_synced()
  local last = last_debounced
  if not last or last.gen ~= generation then return false end
  if vim.uv.hrtime() - last.ns >= DEBOUNCE_NS then return false end
  return journal.key() == last.key and location.resolve().events == last.key
end

-- Bring the comments up to date with the journal (opening it first when it
-- is not loaded, or was replaced), without rendering them: safe to run
-- under the lock. opts.full replays every event, ignoring checkpoints.
-- Returns: ok (boolean), err (string or nil), changed (whether comments
-- changed and the view needs rendering, even when not ok)
function M.sync_data(opts)
  opts = opts or {}
  generation = generation + 1
  local loc = location.resolve()
  local changed = false
  -- A review that can't be read after a switch (or once its journal is
  -- gone) shows nothing, rather than the previous review's comments
  local function fail(err)
    if changed then view.set_comments({}) end
    local ok, e = journal.refuse(err)
    return ok, e, changed
  end
  if journal.key() ~= loc.events then
    journal.switch(loc)
    changed = true
  end
  local stale = true
  if not opts.full then
    local ok, err, read_changed
    ok, err, read_changed, stale = journal.read_tail(loc)
    changed = changed or read_changed
    if not ok then return fail(err) end
  end
  if stale then
    local ok, err, replaced = migrate.open(loc, opts)
    changed = changed or replaced
    if not ok then return fail(err) end
  end
  if changed or stale then
    -- comments.json is looked at again only once the journal changed: a
    -- sync with nothing new costs no stat for it
    if journal.mode() == 'v3' then migrate.check_reappeared(loc) end
  end
  journal.clear_refusal()
  if changed then
    local list = {}
    local rebases = journal.rebases()
    for _, r in ipairs(journal.comments()) do
      local c = view.view_of(r, loc.root, rebases)
      if c then table.insert(list, c) end
    end
    view.set_comments(list)
  end
  return true, nil, changed
end

-- sync_data, then render if the comments changed. opts.defer_view: as for
-- render. opts.debounce (for BufEnter and CursorHold, which may fire in
-- bursts): skip the sync when the last debounced one ran less than 200 ms
-- ago with no other sync since, in the same review. Not for use under the
-- lock (mutate_at renders after it instead).
-- Returns: ok (boolean), err (string or nil)
function M.sync(opts)
  local debounce = opts and opts.debounce
  if debounce and recently_synced() then return true, nil end
  local ok, err, changed = M.sync_data(opts)
  if changed then view.render((opts or {}).defer_view) end
  if debounce then
    last_debounced = { ns = vim.uv.hrtime(), gen = generation, key = journal.key() }
  end
  return ok, err
end

-- Append the events build() returns to the journal, built against its
-- latest state, all with the journal locked; then seal the segment if it is
-- full, and (after the lock) write a checkpoint if one is due. Memory changes
-- only by reading back what was appended, so it never holds a change that
-- isn't on disk. Refuses to change anything if the journal (or a
-- comments.json to migrate) is unusable (sync() reports that once) or the
-- lock can't be taken.
-- build() returns: events (a list, possibly empty), result
-- Returns: result, or nil if the change was refused or failed, and then
-- 'partial' as a second value when some, but not all, of it was written, and
-- the reason (a string, when one is known) as a third
-- opts.defer_view: as for store.all, for every sync the change makes
function M.mutate_at(loc, build, opts)
  -- Before locking: the lock can't be taken in a dir that is not writable
  if journal.readonly_error(loc) then M.sync(opts) end
  local ro_err = journal.readonly_error(loc)
  if ro_err then
    vim.notify('quickfix-review: ' .. ro_err, vim.log.levels.ERROR)
    return nil, nil, ro_err
  end
  local partial = false
  -- Only the journal is read and written under the lock: the render any
  -- sync inside it needs happens once, after the lock is released
  local dirty = false
  -- Why a sync under the lock failed: returned, not notified (sync() reports
  -- an unusable journal once)
  local sync_err
  local function data()
    local ok, serr, changed = M.sync_data(opts)
    dirty = dirty or changed
    if not ok then sync_err = serr end
    return ok
  end
  -- An error inside the lock still renders what was synced before it (its
  -- sync already advanced, so no later one would), then is re-raised
  local pok, got, result, err = pcall(journal.locked, loc, function()
    if not data() then return nil end
    local events, res = build()
    if #events == 0 then return res end
    if journal.mode() == nil then
      -- The legacy import (retried by the sync above) failed: a journal
      -- started by this change would mark the project imported without it
      if migrate.import_failed(loc) then
        return nil, 'Not changing the review: the import of legacy comments into ' .. loc.events
          .. ' failed, and the review can\'t be started without it'
      end
      local created, cerr = journal.create(loc, {})
      if not created then return nil, 'Could not start the review in ' .. loc.events .. ': ' .. tostring(cerr) end
      if not data() or journal.mode() ~= 'v3' then return nil, 'Could not start the review in ' .. loc.events end
    end
    local where = journal.position().path
    local wrote, werr, landed = journal.append(loc, events)
    -- Read back what was written: all of it, some or none
    data()
    if wrote then journal.seal_if_due(loc) end
    if wrote then return res end
    landed = landed or 0
    if landed >= #events then
      -- In the journal, which is the review: only its fsync (or close) failed
      vim.notify(string.format('quickfix-review: the change was written to %s but may not be durable: %s',
        where, tostring(werr)), vim.log.levels.WARN)
      return res
    end
    if landed > 0 then
      partial = true
      return nil, string.format('Could not write all of the change to %s: %s; the change may be incomplete',
        where, tostring(werr))
    end
    return nil, 'Could not write ' .. tostring(where) .. ': ' .. tostring(werr)
  end)
  if dirty then view.render(opts and opts.defer_view) end
  if not pok then error(got, 0) end
  if not got then result, err = nil, result end
  if err then vim.notify('quickfix-review: ' .. err, vim.log.levels.ERROR) end
  -- Outside the lock: the state is encoded before it is taken
  if journal.checkpoint_due() then journal.write_checkpoint(loc) end
  if result == nil and partial then return nil, 'partial', err end
  if result == nil then return nil, nil, err or sync_err end
  return result
end

return M
