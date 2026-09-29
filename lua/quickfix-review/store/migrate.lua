-- Getting a review into its journal (docs/journal.md) and opening it: which
-- storage the review is in (open), migrating a v2 log and its rotated logs
-- into a v3 journal (migrate_v2), starting a journal from the project's
-- comments.json (or loading it read-only when its dir is not writable) or
-- from the legacy global file, recovering a v2 log whose first write was
-- torn, and noticing a comments.json that reappears next to a journal.
local M = {}

local config = require('quickfix-review.config')
local journal = require('quickfix-review.store.journal')
local location = require('quickfix-review.store.location')
local log = require('quickfix-review.log')
local maintenance = require('quickfix-review.store.maintenance')
local notify = require('quickfix-review.notify')
local record = require('quickfix-review.store.record')
local reduce = require('quickfix-review.reduce')
local segment = require('quickfix-review.store.segment')
local checkpoint = require('quickfix-review.store.checkpoint')
local storage = require('quickfix-review.storage')
local utils = require('quickfix-review.utils')

local uv = vim.uv or vim.loop

-- Test hooks: crash_after = n stops migrate_v2 right after step n (as a
-- crash would, nothing cleaned up); mismatch = true fails its verification
M._test = { crash_after = nil, mismatch = false }

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

-- Move comments.json into a new journal: under the lock, create segment 1
-- holding the header and an import of its comments (with the sha256 of its
-- bytes), then rename it to comments.json.pre-log.bak, which keeps the
-- original bytes. A crash before the rename is finished by the next sync,
-- which finds the import's sha256 in the journal. An unreadable
-- comments.json is refused: nothing is written and the file is left alone.
-- Returns: ok (boolean), err (string or nil)
local function migrate_json(loc)
  local got, ok, err = journal.locked(loc, function()
    if has_journal(loc) then return true end -- another Neovim did it
    local src = uv.fs_stat(loc.path)
    if not src then return true end
    local raw = location.read_bytes(loc.path)
    if not raw then return nil, 'Could not read ' .. loc.path end
    local records, lerr = load_records(raw, loc.path, loc.path .. location.MIGRATED)
    if not records then return nil, lerr end
    local import = log.event('import', { source_sha256 = vim.fn.sha256(raw), comments = serialise_all(records) })
    local sok, serr = start_journal(loc, { import }, bit.band(src.mode, 511))
    if not sok then return nil, serr end
    -- The legacy global file stays in place: it is still the per-project
    -- import source (see import_legacy); the journal's import sha256 marks
    -- it done
    if is_legacy_global(loc) then return true end
    local renamed, rerr = uv.fs_rename(loc.path, loc.path .. location.MIGRATED)
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
-- it): its v3 journal (<legacy>.events/), else its v2 log
-- (<legacy>.log.jsonl, unless that is a tombstone), replayed read-only.
-- Returns: { state, imports, sha (of its bytes), source (a path) }, nil
-- when there is none, or false, an error and the path that failed
local function legacy_review(loc, legacy_path)
  local events = legacy_path .. '.events'
  if #segment.list(events) > 0 then
    if utils.files_match(events, loc.events) then return nil end
    local r, err = journal.replay(events, nil)
    if not r then return false, err, events end
    local parts = {}
    for i, n in ipairs(segment.list(events)) do parts[i] = location.read_bytes(segment.path(events, n)) or '' end
    return { state = r.state, imports = r.imports, sha = vim.fn.sha256(table.concat(parts)), source = events }
  end
  local legacy_log = legacy_path .. '.log.jsonl'
  local st = uv.fs_stat(legacy_log)
  if not st or st.size == 0 or utils.files_match(legacy_log, loc.log) then return nil end
  if log.is_tombstone(log.read_header(legacy_log)) then return nil end
  local res, err = journal.replay_v2(legacy_log)
  if not res then return false, err, legacy_log end
  local bytes = location.read_bytes(legacy_log)
  return { state = res.state, imports = res.imports, sha = bytes and vim.fn.sha256(bytes) or nil, source = legacy_log }
end

-- First use of a project with neither a journal nor a comments.json: copy
-- the comments under the project root out of the legacy global file (old
-- default storage_file) into a new journal, as an import event. The legacy
-- file is only read, never upgraded, backed up or rewritten. The journal is
-- started even when nothing matches, so the import happens once per
-- project, across restarts: a journal is the "already imported" marker.
-- When the legacy file is missing, its .pre-log.bak is read instead: older
-- versions renamed the legacy file away when storage_file pointed at it,
-- leaving only that copy.
-- Comments made while storage_file pointed at the legacy file live in its
-- own review (<legacy>.events/, or the v2 <legacy>.log.jsonl); that
-- review's state is imported too. It already holds an import of the legacy
-- file, so while the file is unchanged since (its sha256 is among the
-- review's imports) the review alone is the source; otherwise the file's
-- records whose ids the review doesn't know are added. That review is only
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
      source = lr.source .. ' and ' .. legacy
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
  if ok == true and #imported > 0 then
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
  local records, err = load_records(raw, loc.path, nil)
  if not records then return false, err end
  journal.load_readonly(loc, serialise_all(records), key)
  return true, nil, true
end

-- There is no journal (nor a v2 log): migrate comments.json into a new one
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

-- Defined below, with the migration
local half_built, remove_half_built

-- The first line of the v2 log is incomplete (no \n at all), or the log is
-- only a header: the header and import of a migration or legacy import (or
-- the header and first event of a change) were torn by a short write, so
-- nothing but a partial header or event is lost. v2 wrote the header with
-- an event in one append, and rotation linked or renamed a complete log
-- into place, so a header-only v2 log is never a finished one.
local function is_torn(loc)
  local fd = uv.fs_open(loc.log, 'r', 0)
  if not fd then return false end
  local head = uv.fs_read(fd, 4096, 0)
  uv.fs_close(fd)
  if not head then return false end
  if not head:find('\n', 1, true) then return #head > 0 end
  local res = log.read(loc.log, 0, 0, {})
  return res ~= nil and #res.events == 0 and not log.is_tombstone(res.header)
end

-- A torn v2 log (see is_torn) is moved aside, to log.jsonl.torn-<unix
-- time> (never migrated), and the review started again (init_storage)
-- Returns: ok (boolean), err (string or nil), moved (boolean)
local function recover_torn(loc)
  local got, moved = journal.locked(loc, function()
    if not is_torn(loc) then return nil end
    if has_journal(loc) and half_built(loc) then remove_half_built(loc) end
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
  end, true)
  return true, nil, got and moved ~= nil
end

-- Whether `events/` is a migration that never finished: v2 logs linked in
-- (1..N), and at most segment N+1 with a header naming migrated_from and
-- nothing after it. A journal holding anything else (a native one, a v3
-- event, a segment of a newer version) is never taken for one.
half_built = function(loc)
  local segs = segment.list(loc.events)
  for i, n in ipairs(segs) do
    local path = segment.path(loc.events, n)
    local h = log.read_header(path)
    if h and log.too_new(h) then return false end
    if h and h.v == 3 then
      if type(h.migrated_from) ~= 'table' or i ~= #segs then return false end
      local res = log.read(path, 0, 0, {})
      return res ~= nil and #res.events == 0
    end
  end
  return true
end

-- Remove a half-built migration: `events/` and `checkpoints/`. Only while
-- log.jsonl is a v2 log (so the journal is not the review yet), under both
-- locks. The v2 files were only linked into `events/`, so nothing is lost.
remove_half_built = function(loc)
  for _, n in ipairs(segment.list(loc.events)) do
    os.remove(segment.path(loc.events, n))
    os.remove(segment.refs_path(loc.events, n))
  end
  vim.fn.delete(loc.events, 'rf')
  vim.fn.delete(loc.checkpoints, 'rf')
end

-- The v2 files of the review, oldest first: its rotated logs by their ms,
-- then log.jsonl; a name hard-linked to the same inode as a later one (a v2
-- rotation that crashed after its link) only once, at its latest position.
-- `.torn-*` logs are never included: they hold no finished event.
-- Returns: { { path, ino }... }
local function v2_files(loc)
  local out, at = {}, {}
  local all = maintenance.list_rotated(loc)
  table.insert(all, { path = loc.log })
  for _, f in ipairs(all) do
    local st = uv.fs_stat(f.path)
    if st then
      if at[st.ino] then table.remove(out, at[st.ino]) end
      table.insert(out, { path = f.path, ino = st.ino })
      at = {}
      for i, g in ipairs(out) do at[g.ino] = i end
    end
  end
  return out
end

-- Delete what a finished migration leaves behind (step 7): the rotated
-- names (their inodes live on in `events/`), state.json, and .rotating-*
-- strays. Idempotent.
local function cleanup(loc)
  for _, r in ipairs(maintenance.list_rotated(loc)) do os.remove(r.path) end
  os.remove(loc.state)
  local dir = vim.fn.fnamemodify(loc.log, ':h')
  local pattern = '^' .. vim.pesc(vim.fn.fnamemodify(loc.log, ':t')) .. '%.rotating%-%d+'
  local handle = uv.fs_scandir(dir)
  while handle do
    local name = uv.fs_scandir_next(handle)
    if not name then break end
    if name:match(pattern) then os.remove(dir .. '/' .. name) end
  end
end

-- Reviews whose v2 migration was tried (and did not finish) this session:
-- it is retried at the next session, the review read as v2 meanwhile
local v2_tried = {}
-- Reviews whose step-7 cleanup ran this session
local cleaned = {}

-- Migrate the v2 review at `loc` (log.jsonl and its rotated logs) into a v3
-- journal, under both locks (docs/journal.md#migration):
-- 1. list the v2 files, oldest first (v2_files)
-- 2. hard-link each into `events/` as segment 1..N (bytes unchanged)
-- 3. create segment N+1, a v3 header with a new journal_id and
--    migrated_from = { segments = N }
-- 4. verify: the journal replayed equals log.jsonl replayed; if not, remove
--    `events/` and `checkpoints/` and stay on v2 (warned once)
-- 5. write the .refs of segments 1..N and the first checkpoint
-- 6. rename the tombstone over log.jsonl: from here the journal is the
--    review, and v2 code refuses the log
-- 7. cleanup
-- A crash before 6 leaves v2 authoritative: the next load removes the
-- half-built journal and migrates again. After 6, only cleanup is left.
-- Returns: 'migrated', 'v2' (not migrated: read log.jsonl as v2), or nil
-- and an error
local function migrate_v2(loc)
  local got, res, err = journal.locked(loc, function()
    local h = log.read_header(loc.log)
    if log.is_tombstone(h) then return 'migrated' end -- another Neovim did it
    if not h then return 'v2' end
    if has_journal(loc) then
      if not half_built(loc) then return 'migrated' end -- a journal appeared: open it
      remove_half_built(loc)
    end
    local hooks = M._test
    local function abort(msg)
      remove_half_built(loc)
      notify.once('v2-migration:' .. loc.events, string.format('could not migrate %s to a v3 journal (%s); it'
        .. ' is still read and written as it was, and the migration is tried again next session',
        loc.log, msg), vim.log.levels.WARN)
      return 'v2'
    end

    -- 1.
    local files = v2_files(loc)
    for _, f in ipairs(files) do
      local fh = log.read_header(f.path)
      if not fh or log.too_new(fh) or log.is_tombstone(fh) then return abort(f.path .. ' has no v2 header') end
    end
    local st = uv.fs_stat(loc.log)
    local mode = bit.band(st.mode, 511)
    -- 2.
    local ok = pcall(vim.fn.mkdir, loc.events, 'p')
    if not ok or vim.fn.isdirectory(loc.events) == 0 then return abort('could not create ' .. loc.events) end
    for i, f in ipairs(files) do
      local linked, lerr = uv.fs_link(f.path, segment.path(loc.events, i))
      if not linked then return abort('could not link ' .. f.path .. ': ' .. tostring(lerr)) end
    end
    segment.fsync_dir(loc.events)
    if hooks.crash_after == 2 then return nil, 'crashed (test)' end
    -- 3.
    local n = #files
    local jid = log.new_journal_id()
    local created, cerr = segment.create(loc.events, n + 1,
      { log.segment_header(jid, n + 1, { migrated_from = { segments = n } }) }, mode)
    if created ~= 'created' then return abort(tostring(cerr or 'segment ' .. (n + 1) .. ' exists')) end
    if hooks.crash_after == 3 then return nil, 'crashed (test)' end
    -- 4.
    local v2, verr = journal.replay_v2(loc.log)
    if not v2 then return abort(verr) end
    local v3, rerr = journal.replay(loc.events, nil)
    if not v3 then return abort(rerr) end
    if hooks.mismatch or not vim.deep_equal(reduce.persisted(v2.state), reduce.persisted(v3.state)) then
      return abort('the migrated journal does not replay to the same comments')
    end
    if hooks.crash_after == 4 then return nil, 'crashed (test)' end
    -- 5.
    for i = 1, n do segment.write_refs(loc.events, i, mode) end
    local v3_data = location.read_bytes(v3.path)
    local encoded = checkpoint.encode(jid, v3.seg, v3.offset, v3.lines, v3.state, v3.imports,
      v3_data and segment.refs_of(v3_data, v3.offset) or nil)
    if encoded then
      checkpoint.write(loc.checkpoints, { events = loc.events, journal_id = jid }, v3.seg, v3.offset, encoded,
        mode, math.max(1, tonumber(config.options.checkpoint_keep) or 2))
    end
    if hooks.crash_after == 5 then return nil, 'crashed (test)' end
    -- 6.
    local tomb = vim.json.encode({ op = 'header', v = log.VERSION, log_id = h.log_id, moved_to = 'events/' })
    local wrote, werr = segment.durable_write(loc.log, tomb .. '\n', mode)
    if not wrote then return abort('could not write the tombstone: ' .. tostring(werr)) end
    if hooks.crash_after == 6 then return nil, 'crashed (test)' end
    -- 7.
    cleanup(loc)
    cleaned[loc.events] = true
    return 'migrated'
  end, true)
  if not got then return nil, res end
  return res, err
end

-- Open the review at `loc`: work out which storage it is in, migrating or
-- starting it first where that is due, and load it into the journal
-- (opts.full: replay every event, ignoring checkpoints):
-- - log.jsonl is the tombstone: the v3 journal (cleaned up once a session);
--   with no journal beside it, refused
-- - a v2 log.jsonl: migrated (a torn one moved aside first); one that could
--   not be migrated is read as v2. Beside a native v3 journal (not a
--   migration's), it is ignored with a warning
-- - a journal: loaded; any state.json beside it is deleted
-- - neither: init_storage (comments.json, the legacy import, or nothing)
-- Returns: ok, err, changed (what is shown was replaced)
function M.open(loc, opts)
  local was = journal.mode()
  local h = log.read_header(loc.log)
  local lst = uv.fs_stat(loc.log)
  local segs = segment.list(loc.events)

  -- `migrated`: log.jsonl is the tombstone, so the step-7 cleanup is due
  -- (idempotent: once a session); otherwise only a stray state.json goes
  local function load_v3(migrated)
    local ok, err = journal.load(loc, opts)
    if not ok then return false, err, was ~= nil end
    if migrated and not cleaned[loc.events] then
      cleaned[loc.events] = true
      journal.locked(loc, function() cleanup(loc) end)
    elseif uv.fs_stat(loc.state) then
      journal.locked(loc, function() os.remove(loc.state) end)
    end
    return true, nil, true
  end

  if log.is_tombstone(h) then
    if #segs == 0 then
      return false, string.format('%s says the review was moved to %s, which is missing', loc.log, loc.events), false
    end
    return load_v3(true)
  end

  if lst and lst.size > 0 then
    if #segs > 0 and not half_built(loc) then
      notify.once('stray-v2:' .. loc.log, string.format('%s is a v2 log beside the v3 journal %s; it is not read'
        .. ' (the journal is the review) and is left alone', loc.log, loc.events), vim.log.levels.WARN)
      return load_v3(false)
    end
    if is_torn(loc) then
      local _, _, moved = recover_torn(loc)
      if moved then return M.open(loc, opts) end
    end
    if not v2_tried[loc.events] then
      local res, err = migrate_v2(loc)
      if res == 'migrated' then return M.open(loc, opts) end
      v2_tried[loc.events] = true
      if not res then
        vim.notify('quickfix-review: migrating ' .. loc.log .. ' stopped: ' .. tostring(err), vim.log.levels.WARN)
      end
    end
    local ok, err = journal.load_v2(loc)
    if not ok then return false, err, was ~= nil end
    return true, nil, true
  end

  if #segs > 0 then return load_v3(false) end

  -- Neither: nothing is shown until something starts the journal
  local ok, err, replaced = M.init_storage(loc)
  if not ok then return false, err, replaced or (was ~= nil and was ~= 'readonly') end
  if has_journal(loc) then
    local lok, lerr = load_v3(false)
    return lok, lerr, true
  end
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
      if uv.fs_stat(loc.path) then uv.fs_rename(loc.path, loc.path .. location.MIGRATED) end
    end)
    return
  end
  vim.notify(string.format('quickfix-review: %s reappeared next to the review journal %s; it is not read'
    .. ' (the journal is the review) and is left alone', loc.path, loc.events), vim.log.levels.WARN)
end

return M
