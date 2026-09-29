-- Bringing the comments up to date with the log (sync_data, sync) and
-- making a change (mutate_at): the order in which journal, migrate,
-- maintenance and view are called, under the lock or after it.
local M = {}

local journal = require('quickfix-review.store.journal')
local location = require('quickfix-review.store.location')
local log = require('quickfix-review.log')
local maintenance = require('quickfix-review.store.maintenance')
local migrate = require('quickfix-review.store.migrate')
local view = require('quickfix-review.store.view')

local uv = vim.uv or vim.loop

-- Bring the comments up to date with the log (migrating or importing first
-- when there is none), without rendering them: safe to run under the lock.
-- opts.full replays the whole log, ignoring the cache.
-- Returns: ok (boolean), err (string or nil), changed (whether comments
-- changed and the view needs rendering, even when not ok)
function M.sync_data(opts)
  opts = opts or {}
  local loc = location.resolve()
  local changed = false
  -- A review that can't be read after a switch (or once its log is gone)
  -- shows nothing, rather than the previous review's comments
  local function fail(err)
    if changed then view.set_comments({}) end
    local ok, e = journal.refuse(err)
    return ok, e, changed
  end
  if journal.synced().log ~= loc.log then
    journal.flush()
    journal.reset(loc)
    changed = true
  end
  local stat = uv.fs_stat(loc.log)
  if not stat or stat.size == 0 then
    -- The log was removed: so is the review
    if journal.synced().log_id then
      journal.reset(loc)
      changed = true
    end
    local ok, err, replaced = migrate.init_storage(loc)
    changed = changed or replaced
    if not ok then return fail(err) end
    stat = uv.fs_stat(loc.log)
  elseif journal.readonly() then
    -- A log appeared (another Neovim migrated): it is the review now
    journal.reset(loc)
    changed = true
  end
  -- A log not read yet may be one whose first write was torn
  if stat and stat.size > 0 and not journal.synced().log_id then
    local ok, err = migrate.recover_torn(loc)
    if not ok then return fail(err) end
    stat = uv.fs_stat(loc.log)
  end
  if stat and stat.size > 0 then
    local ok, err, read_changed = journal.read_log(loc, stat, opts)
    if not ok then return fail(err) end
    changed = changed or read_changed
    -- comments.json is looked at again only once the log changed (or after
    -- a reset): a sync with nothing new costs no stat for it. One that
    -- reappears while the log is idle is noticed at its next change.
    local key = string.format('%s:%d:%d:%d.%d', loc.log, stat.ino, stat.size,
      stat.mtime.sec, stat.mtime.nsec)
    if key ~= journal.reappeared_key() then
      migrate.check_reappeared(loc)
      journal.set_reappeared_key(key)
    end
    maintenance.apply_retention(loc)
  end
  journal.clear_refusal()
  if changed then
    local list = {}
    for _, r in ipairs(journal.reduced().comments) do
      local c = view.view_of(r)
      if c then table.insert(list, c) end
    end
    view.set_comments(list)
  end
  if journal.unsaved() >= journal.FLUSH_EVERY then journal.flush() end
  return true, nil, changed
end

-- sync_data, then render if the comments changed. opts.defer_view: as for
-- render. Not for use under the lock (mutate_at renders after it instead).
-- Returns: ok (boolean), err (string or nil)
function M.sync(opts)
  local ok, err, changed = M.sync_data(opts)
  if changed then view.render((opts or {}).defer_view) end
  return ok, err
end

-- Append the events build() returns to the log, built against its latest
-- state, all with the log locked. Memory changes only by reading back what
-- was appended, so it never holds a change that isn't on disk. Refuses to
-- change anything if the log (or a comments.json to migrate) is unusable
-- (sync() reports that once) or the lock can't be taken.
-- build() returns: events (a list, possibly empty), result
-- Returns: result, or nil if the change was refused or failed, and then
-- 'partial' as a second value when some, but not all, of it was written
-- opts.defer_view: as for store.all, for every sync the change makes
function M.mutate_at(loc, build, opts)
  -- Before locking: the lock can't be taken in a dir that is not writable
  if journal.readonly_error(loc) then M.sync(opts) end
  local ro_err = journal.readonly_error(loc)
  if ro_err then
    vim.notify('quickfix-review: ' .. ro_err, vim.log.levels.ERROR)
    return nil
  end
  local partial = false
  -- Only the log is read and written under the lock: the render any sync
  -- inside it needs happens once, after the lock is released
  local dirty = false
  local function data()
    local ok, _, changed = M.sync_data(opts)
    dirty = dirty or changed
    return ok
  end
  -- An error inside the lock still renders what was synced before it (its
  -- sync already advanced, so no later one would), then is re-raised
  local pok, got, result, err = pcall(journal.locked, loc, function()
    if not data() then return nil end
    local events, res = build()
    if #events == 0 then return res end
    local stat = uv.fs_stat(loc.log)
    local header = (not stat or stat.size == 0) and 1 or 0
    -- The legacy import (retried by the sync above) failed: a log started
    -- by this change would mark the project imported without it
    if header == 1 and migrate.import_failed(loc.log) then
      return nil, 'Not changing the review: the import of legacy comments into ' .. loc.log
        .. ' failed, and the review can\'t be started without it'
    end
    if header == 1 then table.insert(events, 1, log.new_header()) end
    local wrote, werr, landed = log.append(loc.log, events)
    -- Read back what was written: all of it, some or none
    data()
    local grown = uv.fs_stat(loc.log)
    if wrote and grown and grown.size > maintenance.rotate_limit(loc, grown) and maintenance.rotate(loc) then
      -- The new log (another inode) is replayed from its checkpoint, and
      -- the cache keyed to it
      data()
      journal.flush(true)
      -- Outside this change: it reads every retained log, and takes the lock
      vim.schedule(function() maintenance.gc(loc) end)
    end
    if wrote then return res end
    landed = (landed or 0) - header
    if landed >= #events - header then
      -- In the log, which is the review: only its fsync (or close) failed
      vim.notify(string.format('quickfix-review: the change was written to %s but may not be durable: %s',
        loc.log, tostring(werr)), vim.log.levels.WARN)
      return res
    end
    if landed > 0 then
      partial = true
      return nil, string.format('Could not write all of the change to %s: %s; the change may be incomplete',
        loc.log, tostring(werr))
    end
    return nil, 'Could not write ' .. loc.log .. ': ' .. tostring(werr)
  end)
  if dirty then view.render(opts and opts.defer_view) end
  if not pok then error(got, 0) end
  if not got then result, err = nil, result end
  if err then vim.notify('quickfix-review: ' .. err, vim.log.levels.ERROR) end
  if result == nil and partial then return nil, 'partial' end
  return result
end

return M
