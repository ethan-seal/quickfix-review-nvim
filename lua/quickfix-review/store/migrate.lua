-- Getting a review into its journal (docs/journal.md) and opening it (open):
-- starting a journal from the project's comments.json (or loading it
-- read-only when its dir is not writable) or from the legacy global file,
-- and noticing a comments.json that reappears next to a journal.
local M = {}

local config = require('quickfix-review.config')
local journal = require('quickfix-review.store.journal')
local location = require('quickfix-review.store.location')
local log = require('quickfix-review.log')
local notify = require('quickfix-review.notify')
local record = require('quickfix-review.store.record')
local segment = require('quickfix-review.store.segment')
local storage = require('quickfix-review.storage')
local utils = require('quickfix-review.utils')

local uv = vim.uv or vim.loop

-- Load the records of a comments.json (its raw bytes): upgraded, normalized,
-- hand-copied duplicate ids split, and records that can't be shown dropped
-- with a warning. `backup` is where the original is kept (the
-- comments.json.pre-log.bak of a migration), or nil when it is left in place
-- (loaded read-only). A relative filename resolves against `root` (the
-- project root; nil for an explicit storage_file).
-- Returns: records, or nil and an error
local function load_records(raw, path, backup, root)
  local list, err = storage.parse(raw, path)
  if not list then return nil, err end
  local loaded, seen, dropped = {}, {}, 0
  for _, item in ipairs(list) do
    local c = type(item) == 'table' and record.normalize(item, root) or nil
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

-- The records as written to the journal at `loc` (see record.relativize)
local function serialise_all(records, loc)
  local out = {}
  for i, c in ipairs(records) do out[i] = record.relativize(storage.serialise(c), loc) end
  return out
end

-- An explicit storage_file that is the legacy global file (the old
-- default): that file is also every project's legacy import source, so it
-- is never renamed away, or a later per-project review would import nothing
local function is_legacy_global(loc)
  return loc.explicit == true and utils.files_match(loc.path, config.legacy_storage_file())
end

-- Whether the review at `loc` has a journal (any segment)
local function has_journal(loc)
  return #segment.list(loc.events) > 0
end

-- Start the journal from `events` (an import): segment 1, created complete
-- with its header, with `mode`. Call with the lock held.
-- Returns: ok, err
local function start_journal(loc, events, mode)
  local created, err = journal.create(loc, events, mode)
  if not created then return false, 'Could not write ' .. segment.path(loc.events, 1) .. ': ' .. tostring(err) end
  return true, nil
end

-- Where to keep comments.json (at `path`) when it is moved aside:
-- comments.json.pre-log.bak, or, when an earlier migration's backup already
-- has that name, comments.json.pre-log.<unix ms>.bak (never overwritten).
-- Call with the lock held.
local function backup_name(path)
  local plain = path .. location.MIGRATED
  if not uv.fs_stat(plain) then return plain end
  local sec, usec = uv.gettimeofday()
  local stem = path .. '.pre-log.' .. string.format('%d', sec * 1000 + math.floor(usec / 1000))
  local bak, n = stem .. '.bak', 1
  while uv.fs_stat(bak) do
    bak, n = stem .. '-' .. n .. '.bak', n + 1
  end
  return bak
end

-- Move comments.json into a new journal: under the lock, create segment 1
-- holding the header and an import of its comments (with the sha256 of its
-- bytes), then rename it to comments.json.pre-log.bak (see backup_name),
-- which keeps the original bytes. A crash before the rename is finished by
-- the next sync, which finds the import's sha256 in the journal. An unreadable
-- comments.json is refused: nothing is written and the file is left alone.
-- Returns: ok (boolean), err (string or nil)
local function migrate_json(loc)
  local got, ok, err = journal.locked(loc, function()
    if has_journal(loc) then return true end -- another Neovim did it
    local src = uv.fs_stat(loc.path)
    if not src then return true end
    local raw = location.read_bytes(loc.path)
    if not raw then return nil, 'Could not read ' .. loc.path end
    local bak = backup_name(loc.path)
    local records, lerr = load_records(raw, loc.path, bak, loc.root)
    if not records then return nil, lerr end
    local import = log.event('import', { source_sha256 = vim.fn.sha256(raw), comments = serialise_all(records, loc) })
    local sok, serr = start_journal(loc, { import }, bit.band(src.mode, 511))
    if not sok then return nil, serr end
    -- The legacy global file stays in place: it is still the per-project
    -- import source (see import_legacy); the journal's import sha256 marks
    -- it done
    if is_legacy_global(loc) then return true end
    local renamed, rerr = uv.fs_rename(loc.path, bak)
    if not renamed then
      vim.notify(string.format('quickfix-review: migrated %s into %s but could not rename it: %s',
        loc.path, loc.events, tostring(rerr)), vim.log.levels.WARN)
    end
    return true
  end)
  if not got then return false, ok end
  return ok == true, err
end

-- Reviews (by loc.events) whose legacy import is settled this session:
-- done, or nothing (readable) to import
local import_tried = {}
-- Reviews whose legacy import failed (a source to import, the journal not
-- written) and has not succeeded since: the first change must not start the
-- journal without it (see mutate_at), or the project would count as imported
local import_failed = {}

-- Whether the legacy import into the review at `loc` failed and has not
-- succeeded since
function M.import_failed(loc)
  return import_failed[loc.events]
end

-- An import warning, shown once per review and message: a failing import
-- is retried at every sync
local function warn_once(loc, msg)
  notify.once('import-warn:' .. loc.events .. '\0' .. msg, msg, vim.log.levels.WARN)
end

-- The legacy global file's own review (made while storage_file pointed at
-- it): its journal (<legacy>.events/), replayed read-only.
-- Returns: { state, imports, ids (every comment id its events ever
-- mentioned, deleted and pruned ones too), records (every comment record
-- its events carried, raw), sha (of its bytes), source (a path) }, nil
-- when there is none, or false, an error and the path that failed
local function legacy_review(loc, legacy_path)
  local events = legacy_path .. '.events'
  if #segment.list(events) == 0 or utils.files_match(events, loc.events) then return nil end
  local r, err = journal.replay(events, nil, {}, {})
  if not r then return false, err, events end
  local parts = {}
  for i, n in ipairs(segment.list(events)) do parts[i] = location.read_bytes(segment.path(events, n)) or '' end
  return { state = r.state, imports = r.imports, ids = r.ids, records = r.records, sha = vim.fn.sha256(table.concat(parts)), source = events }
end

-- Whether `root` is $HOME or / (symlinks resolved, trailing slashes ignored)
local function is_broad_root(root)
  local r = root:gsub('/+$', '')
  if r == '' then return true end
  local home = vim.env.HOME
  if not home or home == '' then return false end
  home = utils.realpath(home):gsub('/+$', '')
  return home ~= '' and r == home
end

-- First use of a project with neither a journal nor a comments.json: copy
-- the comments under the project root out of the legacy global file (old
-- default storage_file) into a new journal, as an import event. The legacy
-- file is only read, never upgraded, backed up or rewritten. A journal is
-- the "already imported" marker, so a non-empty import happens once per
-- project, across restarts. When nothing matches, no journal is started
-- (the dir stays empty, so e.g. :ReviewAdopt can still fill it): the scan
-- is repeated once per session until the project's first change starts
-- the journal, and then never again.
-- When the legacy file is missing, its .pre-log.bak is read instead: older
-- versions renamed the legacy file away when storage_file pointed at it,
-- leaving only that copy.
-- Comments made while storage_file pointed at the legacy file live in its
-- own review (<legacy>.events/); that
-- review's state is imported too. It already holds an import of the legacy
-- file, so while the file is unchanged since (its sha256 is among the
-- review's imports) the review alone is the source; otherwise the file's
-- records whose ids the review never mentioned are added: ids are checked
-- against every id in the review's raw events, not its reduced state, so a
-- comment deleted there stays deleted even once pruned from its trash (an
-- id-less record is matched by file name, line and body against every record
-- those events carried, likewise). That review is only
-- read: never locked, synced or migrated from here.
local function import_legacy(loc)
  if import_tried[loc.events] then return end
  -- Tried again (at the next sync) until the outcome is definitive: nothing
  -- to import, a source that can't be read, or the journal written
  local function done()
    import_tried[loc.events] = true
    import_failed[loc.events] = nil
  end

  local legacy_path = config.legacy_storage_file()
  local lr, lerr, lsource = legacy_review(loc, legacy_path)

  local legacy = legacy_path
  if vim.fn.filereadable(legacy) == 0 then
    legacy = legacy .. location.MIGRATED
    if vim.fn.filereadable(legacy) == 0 then legacy = nil end
  end
  if legacy and utils.files_match(legacy, loc.path) then return done() end
  if lr == false then
    warn_once(loc, 'not importing from ' .. tostring(lsource) .. ': ' .. tostring(lerr))
    lr = nil
    if not legacy then return done() end
  end
  if not legacy and not lr then return done() end

  local raw, file_list
  if legacy then
    raw = location.read_bytes(legacy)
    local err
    file_list, err = storage.parse(raw, legacy)
    if not file_list then
      warn_once(loc, 'not importing from ' .. legacy .. ': ' .. err)
      if not lr then return done() end
      legacy, raw = nil, nil
    end
  end

  local list, source
  if lr then
    local state = lr.state
    list, source = vim.list_extend({}, state.comments), lr.source
    -- The file changed after the review imported it: add what it lacks
    if file_list and not lr.imports[vim.fn.sha256(raw)] then
      -- Every id the review's events mention (live, deleted, pruned)
      local known = lr.ids
      -- An id-less record gets a fresh id each time it is normalized, so it
      -- is matched by place and body instead: against every record the
      -- review's events carried (so a deleted, even pruned, one stays
      -- deleted) and its live comments (as edited since)
      local function loc_key(c) return table.concat({ c.filename, tostring(c.lnum), c.body }, '\0') end
      local known_loc = {}
      for _, c in ipairs(vim.list_extend(vim.list_extend({}, lr.records), state.comments)) do
        local n = record.normalize(c, loc.root)
        if n then known_loc[loc_key(n)] = true end
      end
      for _, item in ipairs(file_list) do
        local c = type(item) == 'table' and record.normalize(item, loc.root) or nil
        local dup = c and (known[c.id] or (not record.has_id(item) and known_loc[loc_key(c)]))
        if not dup then table.insert(list, c and storage.serialise(c) or item) end
      end
      source = lr.source .. ' and ' .. legacy
    end
  else
    list, source = file_list, legacy
  end

  -- Records that can't be imported: `dropped` are this project's (by their
  -- file name; in a shared dir, all of them), `unplaced` have no file name,
  -- so they are no project's and are warned about only beside an import
  local imported, seen, dropped, unplaced = {}, {}, 0, 0
  for _, item in ipairs(list) do
    local c = type(item) == 'table' and record.normalize(item, loc.root) or nil
    if not c then
      local name = type(item) == 'table' and item.filename or nil
      if loc.shared then
        dropped = dropped + 1
      elseif type(name) == 'string' and name ~= '' then
        if utils.is_under(record.resolve_filename(name, loc.root), loc.root) then dropped = dropped + 1 end
      else
        unplaced = unplaced + 1
      end
    end
    -- A shared dir is every project's review: import everything
    if c and (loc.shared or utils.is_under(c.filename, loc.root)) then
      if seen[c.id] then c.id = record.new_id() end
      seen[c.id] = true
      table.insert(imported, record.relativize(storage.serialise(c), loc))
    end
  end
  -- Nothing for this project: leave the dir empty (see above)
  if #imported == 0 then return done() end
  -- A review rooted at $HOME or / (Neovim started outside any project)
  -- would take nearly every comment: skip it, with a warning. It is settled
  -- (done), not failed, so the review is usable; its first change starts
  -- the journal, which marks it imported. A shared dir still imports
  -- everything (it is every project's review).
  if not loc.shared and is_broad_root(loc.root) then
    warn_once(loc, string.format('not importing comments from %s into the review at %s (your home directory'
      .. ' or /, which would take nearly every comment): open Neovim inside a project to import its comments',
      source, loc.root))
    return done()
  end
  if dropped + unplaced > 0 then
    warn_once(loc, string.format('not importing %d comment(s) from %s: invalid line number'
      .. ' or no file name (the file is unchanged)', dropped + unplaced, source))
  end

  local got, ok, werr = journal.locked(loc, function()
    if has_journal(loc) then return 'exists' end -- another Neovim did it
    local import = log.event('import', { source_sha256 = raw and vim.fn.sha256(raw) or lr.sha,
      comments = imported })
    return start_journal(loc, { import })
  end)
  if not got or not ok then
    import_failed[loc.events] = true
    -- Retried at every sync, the error shown once per review
    notify.once('import-failed:' .. loc.events,
      'import from ' .. source .. ' failed: ' .. tostring(got and werr or ok), vim.log.levels.ERROR)
    return
  end
  done()
  if ok == true then
    vim.notify(string.format('quickfix-review: imported %d comments from %s', #imported, source))
  end
end

-- comments.json in a storage dir that is not writable, so it can't be
-- migrated: load it read-only (as if imported, but nothing is written),
-- again only when it changes. Changes are refused (see mutate_at).
-- Returns: ok (boolean), err (string or nil), changed (boolean)
local function load_readonly(loc, src)
  local key = string.format('%d:%d.%d', src.size, src.mtime.sec, src.mtime.nsec)
  if journal.key() == loc.events and journal.readonly_key() == key then return true, nil, false end
  local raw = location.read_bytes(loc.path)
  if not raw then return false, 'Could not read ' .. loc.path end
  local records, err = load_records(raw, loc.path, nil, loc.root)
  if not records then return false, err end
  journal.load_readonly(loc, serialise_all(records, loc), key)
  return true, nil, true
end

-- There is no journal: migrate comments.json into a new one
-- (or load it read-only if its dir is not writable), or import from the
-- legacy global file, or leave it to the first change to start
-- Returns: ok (boolean), err (string or nil), changed (boolean: what is
-- shown was replaced)
function M.init_storage(loc)
  local src = uv.fs_stat(loc.path)
  if src and not uv.fs_access(loc.dir, 'W') then return load_readonly(loc, src) end
  -- No longer read-only: what was shown is migrated now, or gone
  local was_readonly = journal.mode() == 'readonly'
  if was_readonly then journal.switch(loc) end
  local ok, err = true, nil
  if src then
    ok, err = migrate_json(loc)
  elseif not loc.explicit then
    import_legacy(loc)
  end
  return ok, err, was_readonly
end
-- Open the review at `loc`: load its journal (opts.full: replay every
-- event, ignoring checkpoints), or, with none yet, init_storage
-- (comments.json, the legacy import, or nothing) and then load it
-- Returns: ok, err, changed (what is shown was replaced)
function M.open(loc, opts)
  local was = journal.mode()
  local function load()
    local ok, err = journal.load(loc, opts)
    if not ok then return false, err, was ~= nil end
    return true, nil, true
  end

  if has_journal(loc) then return load() end

  -- None yet: nothing is shown until something starts the journal
  local ok, err, replaced = M.init_storage(loc)
  if not ok then return false, err, replaced or (was ~= nil and was ~= 'readonly') end
  if has_journal(loc) then return load() end
  if journal.mode() ~= 'readonly' and was ~= nil then
    journal.switch(loc)
    return true, nil, true
  end
  return true, nil, replaced or false
end

-- comments.json versions (path:size:mtime) already looked at
local reappeared_seen = {}

-- comments.json next to an existing journal: either a migration that
-- crashed before its rename (the journal holds an import with its sha256),
-- which is finished now, or something wrote it after the migration (an
-- external tool, an older plugin). That one is not read, and not deleted:
-- warn once.
function M.check_reappeared(loc)
  -- The legacy global file is left in place by design (see migrate_json)
  if is_legacy_global(loc) then return end
  local st = uv.fs_stat(loc.path)
  if not st then return end
  local key = string.format('%s:%d:%d.%d', loc.path, st.size, st.mtime.sec, st.mtime.nsec)
  if reappeared_seen[key] then return end
  reappeared_seen[key] = true
  local raw = location.read_bytes(loc.path)
  if raw and journal.has_import(vim.fn.sha256(raw)) then
    journal.locked(loc, function()
      if uv.fs_stat(loc.path) then uv.fs_rename(loc.path, backup_name(loc.path)) end
    end)
    return
  end
  vim.notify(string.format('quickfix-review: %s reappeared next to the review journal %s; it is not read'
    .. ' (the journal is the review) and is left alone', loc.path, loc.events), vim.log.levels.WARN)
end

return M
