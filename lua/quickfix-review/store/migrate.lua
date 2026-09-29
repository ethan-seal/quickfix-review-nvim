-- Getting a review into its log when there is none yet: migrating the
-- project's comments.json (or loading it read-only when its dir is not
-- writable), or importing from the legacy global file; recovering a log whose
-- first write was torn; and noticing a comments.json that reappears next to
-- an existing log.
local M = {}

local config = require('quickfix-review.config')
local journal = require('quickfix-review.store.journal')
local location = require('quickfix-review.store.location')
local log = require('quickfix-review.log')
local notify = require('quickfix-review.notify')
local record = require('quickfix-review.store.record')
local reduce = require('quickfix-review.reduce')
local storage = require('quickfix-review.storage')
local utils = require('quickfix-review.utils')

local uv = vim.uv or vim.loop

-- Load the records of a comments.json (its raw bytes): upgraded, normalized,
-- hand-copied duplicate ids split, and records that can't be shown dropped
-- with a warning. `backup` is where the original is kept (the
-- comments.json.pre-log.bak of a migration), or nil when it is left in place
-- (loaded read-only).
-- Returns: records, or nil and an error
local function load_records(raw, path, backup)
  local list, err = storage.parse(raw, path)
  if not list then return nil, err end
  local loaded, seen, dropped = {}, {}, 0
  for _, item in ipairs(list) do
    local c = type(item) == 'table' and record.normalize(item) or nil
    if not c then
      dropped = dropped + 1
    else
      -- A hand-copied comment shares its id; give the copy its own, so
      -- remove(id) never deletes both
      if seen[c.id] then c.id = record.new_id() end
      seen[c.id] = true
      table.insert(loaded, c)
    end
  end
  if dropped > 0 then
    local kept = backup and ('original kept at ' .. backup)
      or 'storage is read-only; the file is unchanged'
    vim.notify(string.format('quickfix-review: dropped %d comment(s) with an invalid line number or no file in %s;'
      .. ' %s', dropped, path, kept), vim.log.levels.WARN)
  end
  return loaded
end

local function serialise_all(records)
  local out = {}
  for i, c in ipairs(records) do out[i] = storage.serialise(c) end
  return out
end

-- An explicit storage_file that is the legacy global file (the old
-- default): that file is also every project's legacy import source, so it
-- is never renamed away, or a later per-project review would import nothing
local function is_legacy_global(loc)
  return loc.explicit == true and utils.files_match(loc.path, config.legacy_storage_file())
end

-- Move comments.json into a new log: under the lock, write the header and an
-- import of its comments (with the sha256 of its bytes) in one fsync'ed
-- append, then rename it to comments.json.pre-log.bak, which keeps the
-- original bytes. A crash before the rename is finished by the next sync,
-- which finds the import's sha256 in the log. An unreadable comments.json
-- is refused: no log is written and the file is left alone.
-- Returns: ok (boolean), err (string or nil)
local function migrate(loc)
  local got, ok, err = journal.locked(loc, function()
    local st = uv.fs_stat(loc.log)
    if st and st.size > 0 then return true end -- another Neovim did it
    local src = uv.fs_stat(loc.path)
    if not src then return true end
    local raw = location.read_bytes(loc.path)
    if not raw then return nil, 'Could not read ' .. loc.path end
    local records, lerr = load_records(raw, loc.path, loc.path .. location.MIGRATED)
    if not records then return nil, lerr end
    local import = log.event('import', { source_sha256 = vim.fn.sha256(raw), comments = serialise_all(records) })
    local wrote, werr, landed = log.append(loc.log, { log.new_header(), import }, bit.band(src.mode, 511))
    if not wrote and landed ~= 2 then return nil, 'Could not write ' .. loc.log .. ': ' .. werr end
    if not wrote then
      vim.notify(string.format('quickfix-review: migrated %s into %s, but it may not be durable: %s',
        loc.path, loc.log, tostring(werr)), vim.log.levels.WARN)
    end
    -- The legacy global file stays in place: it is still the per-project
    -- import source (see import_legacy); the log's import sha256 marks it done
    if is_legacy_global(loc) then return true end
    local renamed, rerr = uv.fs_rename(loc.path, loc.path .. location.MIGRATED)
    if not renamed then
      vim.notify(string.format('quickfix-review: migrated %s into %s but could not rename it: %s',
        loc.path, loc.log, tostring(rerr)), vim.log.levels.WARN)
    end
    return true
  end)
  if not got then return false, ok end
  return ok == true, err
end

-- Log paths whose legacy import is settled this session: done, or nothing
-- (readable) to import
local import_tried = {}
-- Log paths whose legacy import failed (a source to import, the log not
-- written) and has not succeeded since: the first change must not create the
-- log without it (see mutate_at), or the project would count as imported
local import_failed = {}

-- Whether the legacy import into the log at `path` failed and has not
-- succeeded since
function M.import_failed(path)
  return import_failed[path]
end

-- An import warning, shown once per log path and message: a failing import
-- is retried at every sync
local function warn_once(loc, msg)
  notify.once('import-warn:' .. loc.log .. '\0' .. msg, msg, vim.log.levels.WARN)
end

-- First use of a project with neither a log nor a comments.json: copy the
-- comments under the project root out of the legacy global file (old default
-- storage_file) into a new log, as an import event. The legacy file is only
-- read, never upgraded, backed up or rewritten. The log is written even when
-- nothing matches, so the import happens once per project, across restarts:
-- a log is the "already imported" marker. When the legacy file is missing,
-- its .pre-log.bak is read instead: older versions renamed the legacy file
-- away when storage_file pointed at it, leaving only that copy.
-- Comments made while storage_file pointed at the legacy file live in its
-- log (<legacy>.log.jsonl); that log's reduced state is imported too. It
-- already holds an import of the legacy file, so while the file is
-- unchanged since (its sha256 is among the log's imports) the log alone is
-- the source; otherwise the file's records whose ids the log doesn't know
-- are added. The legacy log is only read: never locked, synced, rotated or
-- given a state.json.
local function import_legacy(loc)
  if import_tried[loc.log] then return end
  -- Tried again (at the next sync) until the outcome is definitive: nothing
  -- to import, a source that can't be read, or the log written
  local function done()
    import_tried[loc.log] = true
    import_failed[loc.log] = nil
  end

  local legacy_path = config.legacy_storage_file()
  local legacy_log = legacy_path .. '.log.jsonl'
  local log_st = uv.fs_stat(legacy_log)
  if not log_st or log_st.size == 0 or utils.files_match(legacy_log, loc.log) then legacy_log = nil end

  local legacy = legacy_path
  if vim.fn.filereadable(legacy) == 0 then
    legacy = legacy .. location.MIGRATED
    if vim.fn.filereadable(legacy) == 0 then legacy = nil end
  end
  if legacy and (utils.files_match(legacy, loc.path) or utils.files_match(legacy, loc.log)) then return done() end
  if not legacy and not legacy_log then return done() end

  -- The legacy log's state and the shas of the files it imported
  local state, imports, log_raw_sha
  if legacy_log then
    local res, lerr = log.read(legacy_log, 0, 0, {})
    if res then
      state, imports = reduce.new(), {}
      for _, ev in ipairs(res.events) do
        if ev.op == 'import' and type(ev.source_sha256) == 'string' then imports[ev.source_sha256] = true end
        if ev.op == 'checkpoint' and type(ev.imports) == 'table' then
          for _, sha in ipairs(ev.imports) do
            if type(sha) == 'string' then imports[sha] = true end
          end
        end
        reduce.apply(state, ev)
      end
      local bytes = location.read_bytes(legacy_log)
      log_raw_sha = bytes and vim.fn.sha256(bytes) or nil
    else
      warn_once(loc, 'not importing from ' .. legacy_log .. ': ' .. tostring(lerr))
      if not legacy then return done() end
    end
  end

  local raw, file_list
  if legacy then
    raw = location.read_bytes(legacy)
    local err
    file_list, err = storage.parse(raw, legacy)
    if not file_list then
      warn_once(loc, 'not importing from ' .. legacy .. ': ' .. err)
      if not state then return done() end
      legacy, raw = nil, nil
    end
  end

  local list, source
  if state then
    list, source = vim.list_extend({}, state.comments), legacy_log
    -- The file changed after the log imported it: add what the log lacks
    if file_list and not imports[vim.fn.sha256(raw)] then
      local known = {}
      for _, c in ipairs(state.comments) do known[c.id] = true end
      for id, _ in pairs(state.trash) do known[id] = true end
      for _, r in ipairs(state.removed) do known[r.id] = true end
      -- An id-less record gets a fresh id each time it is normalized, so it
      -- is matched by place and body instead
      local function loc_key(c) return table.concat({ c.filename, tostring(c.lnum), c.body }, '\0') end
      local known_loc = {}
      for _, c in ipairs(state.comments) do
        local n = record.normalize(c)
        if n then known_loc[loc_key(n)] = true end
      end
      for _, item in ipairs(file_list) do
        local c = type(item) == 'table' and record.normalize(item) or nil
        local dup = c and (known[c.id] or (not record.has_id(item) and known_loc[loc_key(c)]))
        if not dup then table.insert(list, c and storage.serialise(c) or item) end
      end
      source = legacy_log .. ' and ' .. legacy
    end
  else
    list, source = file_list, legacy
  end

  local imported, seen, dropped = {}, {}, 0
  for _, item in ipairs(list) do
    local c = type(item) == 'table' and record.normalize(item) or nil
    if not c then dropped = dropped + 1 end
    -- A shared dir is every project's review: import everything
    if c and (loc.shared or utils.is_under(c.filename, loc.root)) then
      if seen[c.id] then c.id = record.new_id() end
      seen[c.id] = true
      table.insert(imported, storage.serialise(c))
    end
  end
  if dropped > 0 then
    warn_once(loc, string.format('not importing %d comment(s) from %s: invalid line number'
      .. ' or no file name (the file is unchanged)', dropped, source))
  end

  local got, ok, werr = journal.locked(loc, function()
    local st = uv.fs_stat(loc.log)
    if st and st.size > 0 then return 'exists' end -- another Neovim did it
    local import = log.event('import', { source_sha256 = raw and vim.fn.sha256(raw) or log_raw_sha,
      comments = imported })
    return log.append(loc.log, { log.new_header(), import })
  end)
  if not got or not ok then
    import_failed[loc.log] = true
    -- Retried at every sync, the error shown once per log
    notify.once('import-failed:' .. loc.log,
      'import from ' .. source .. ' failed: ' .. tostring(got and werr or ok), vim.log.levels.ERROR)
    return
  end
  done()
  if ok == true and #imported > 0 then
    vim.notify(string.format('quickfix-review: imported %d comments from %s', #imported, source))
  end
end

-- comments.json in a storage dir that is not writable, so it can't be
-- migrated: load it read-only into `reduced` (as if imported, but nothing is
-- written), again only when it changes. Changes are refused (see mutate).
-- Returns: ok (boolean), err (string or nil), changed (boolean)
local function load_readonly(loc, src)
  local key = string.format('%d:%d.%d', src.size, src.mtime.sec, src.mtime.nsec)
  local readonly = journal.readonly()
  if readonly and readonly.log == loc.log and readonly.key == key then return true, nil, false end
  local raw = location.read_bytes(loc.path)
  if not raw then return false, 'Could not read ' .. loc.path end
  local records, err = load_records(raw, loc.path, nil)
  if not records then return false, err end
  journal.reset(loc)
  reduce.apply(journal.reduced(), { op = 'import', comments = serialise_all(records) })
  journal.set_readonly({ log = loc.log, key = key })
  return true, nil, true
end

-- The log is missing (or empty): migrate comments.json into it (or load it
-- read-only if its dir is not writable), or import from the legacy global
-- file, or leave it to the first change to create
-- Returns: ok (boolean), err (string or nil), changed (boolean: `reduced`
-- was replaced)
function M.init_storage(loc)
  local src = uv.fs_stat(loc.path)
  if src and not uv.fs_access(loc.dir, 'W') then return load_readonly(loc, src) end
  -- No longer read-only: what was shown is migrated now, or gone
  local was_readonly = journal.readonly() ~= nil
  if was_readonly then journal.reset(loc) end
  local ok, err = true, nil
  if src then
    ok, err = migrate(loc)
  elseif not loc.explicit then
    import_legacy(loc)
  end
  return ok, err, was_readonly
end

-- The first line of the log at `path` is incomplete (no \n at all), or the
-- log is only a header: the header and import of a migration or legacy
-- import (or the header and first event of a change) were torn by a short
-- write, so nothing but a partial header or event is lost. Each of those
-- writes the header with an event in one append, and rotation links or
-- renames a complete log into place, so a header-only log is never a
-- finished one.
local function is_torn(loc)
  local fd = uv.fs_open(loc.log, 'r', 0)
  if not fd then return false end
  local head = uv.fs_read(fd, 4096, 0)
  uv.fs_close(fd)
  if not head then return false end
  if not head:find('\n', 1, true) then return #head > 0 end
  local res = log.read(loc.log, 0, 0, journal.seen_lines(loc))
  return res ~= nil and #res.events == 0
end

-- A torn log (see is_torn) is moved aside, to log.jsonl.torn-<unix time>,
-- and the migration or legacy import retried
-- Returns: ok (boolean), err (string or nil)
function M.recover_torn(loc)
  -- Checked again under the lock, where no write is in flight
  if not is_torn(loc) then return true, nil end
  local got, moved = journal.locked(loc, function()
    if not is_torn(loc) then return nil end
    local aside, n = loc.log .. '.torn-' .. os.time(), 1
    while uv.fs_stat(aside) do
      aside, n = loc.log .. '.torn-' .. os.time() .. '-' .. n, n + 1
    end
    local renamed, rerr = uv.fs_rename(loc.log, aside)
    if not renamed then
      vim.notify(string.format('quickfix-review: %s is incomplete, but could not be moved aside: %s',
        loc.log, tostring(rerr)), vim.log.levels.WARN)
      return nil
    end
    vim.notify(string.format('quickfix-review: %s was incomplete (an interrupted write); moved it to %s',
      loc.log, aside), vim.log.levels.WARN)
    return aside
  end)
  if not got or not moved then return true, nil end
  local ok, err = M.init_storage(loc)
  return ok, err
end

-- comments.json versions (path:size:mtime) already looked at
local reappeared_seen = {}

-- comments.json next to an existing log: either a migration that crashed
-- before its rename (the log holds an import with its sha256), which is
-- finished now, or something wrote it after the migration (an external tool,
-- an older plugin). That one is not read, and not deleted: warn once.
function M.check_reappeared(loc)
  -- The legacy global file is left in place by design (see migrate)
  if is_legacy_global(loc) then return end
  local st = uv.fs_stat(loc.path)
  if not st then return end
  local key = string.format('%s:%d:%d.%d', loc.path, st.size, st.mtime.sec, st.mtime.nsec)
  if reappeared_seen[key] then return end
  reappeared_seen[key] = true
  local raw = location.read_bytes(loc.path)
  if raw and journal.synced().imports[vim.fn.sha256(raw)] then
    journal.locked(loc, function()
      if uv.fs_stat(loc.path) then uv.fs_rename(loc.path, loc.path .. location.MIGRATED) end
    end)
    return
  end
  vim.notify(string.format('quickfix-review: %s reappeared next to the review log %s; it is not read'
    .. ' (the log is the review) and is left alone', loc.path, loc.log), vim.log.levels.WARN)
end

return M
