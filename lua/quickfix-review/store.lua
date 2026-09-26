-- The review's comments. The plugin owns them here rather than in the quickfix
-- list, so other tools that replace the quickfix list (LSP references, grep)
-- can't clobber the review. The source of truth is an append-only event log
-- (log.jsonl, see log.lua): every change is appended as an event, and the
-- comments are the log replayed through reduce.lua, so no change can lose
-- data. state.json is a cache of that replay, never needed for correctness.
-- Events another Neovim appends are picked up by reading the log's tail.
-- Comments are the storage schema's records (see storage.lua); the quickfix
-- list is only a view derived from them, which M.show() publishes.
local M = {}

local config = require('quickfix-review.config')
local log = require('quickfix-review.log')
local reduce = require('quickfix-review.reduce')
local storage = require('quickfix-review.storage')
local utils = require('quickfix-review.utils')

local uv = vim.uv or vim.loop

local QF_TITLE = 'Code Review Comments'

-- The live comments, normalized: the view of `reduced.comments`
local comments = {}
-- The log replayed: records as logged, and the trash
local reduced = reduce.new()
-- Id of the quickfix list showing the review, if one has been published
local qf_id = nil
local on_change = function(_) end


-- A stable identity for a comment: 16 hex chars from the OS RNG. Not
-- math.random, which LuaJIT leaves unseeded, so every Neovim would produce
-- the same sequence.
local function new_id()
  local bytes = assert((vim.uv or vim.loop).random(8))
  return (bytes:gsub('.', function(b) return string.format('%02x', b:byte()) end))
end

local function has_id(item)
  return type(item.id) == 'string' and item.id ~= ''
end

-- The fields normalize() understands; any other field of a record is kept in
-- its `extra` table. `text` is a legacy field that is parsed, then dropped.
local KNOWN = {
  id = true, filename = true, kind = true, body = true, response = true, lnum = true,
  end_lnum = true, context = true, created_at = true, text = true, anchor = true,
}

-- A line number (1 or more), or nil. A numeric string ("12", as an external
-- tool may write) is accepted.
local function to_line(v)
  if type(v) == 'string' then v = tonumber(v) end
  if type(v) ~= 'number' or v ~= math.floor(v) or v < 1 then return nil end
  return v
end

local function nonempty(s)
  return type(s) == 'string' and s ~= '' and s or nil
end

local function string_list(t)
  if type(t) ~= 'table' then return nil end
  local out = {}
  for i = 1, #t do
    if type(t[i]) ~= 'string' then return nil end
    out[i] = t[i]
  end
  return out
end

-- A comment's anchor, { sha, lnum, end_lnum, lines, before, after }, as
-- written when it was made: lnum/end_lnum are relative to the snapshot
-- `sha`. nil when `a` has no valid line number; a bad field is dropped.
local function parse_anchor(a)
  if type(a) ~= 'table' then return nil end
  local lnum = to_line(a.lnum)
  if not lnum then return nil end
  local end_lnum = to_line(a.end_lnum)
  if not end_lnum or end_lnum < lnum then end_lnum = lnum end
  return {
    sha = nonempty(a.sha),
    lnum = lnum,
    end_lnum = end_lnum,
    lines = string_list(a.lines),
    before = string_list(a.before),
    after = string_list(a.after),
  }
end

-- Keep only the fields of a comment record, giving it an id if it has none
-- (comments saved before ids existed). Returns nil for a record that has no
-- file or no valid line number.
local function normalize(item)
  local filename = item.filename
  if type(filename) ~= 'string' or filename == '' then return nil end
  local lnum = to_line(item.lnum)
  if not lnum then return nil end
  -- Older saves were raw getqflist() items, where end_lnum 0 means "unset";
  -- an end before the start is never valid, so treat it as a single line.
  local end_lnum = to_line(item.end_lnum)
  if not end_lnum or end_lnum < lnum then end_lnum = lnum end

  local kind, body = nonempty(item.kind), nonempty(item.body)
  local response = nonempty(item.response)
  -- An external tool (or an older one) may write the v1 text into a v2
  -- record, e.g. appending " | Response: ..." to it; merge it in
  if type(item.text) == 'string' then
    local t_kind, t_body, t_response = storage.parse_text(item.text)
    kind = kind or t_kind
    body = body or nonempty(t_body)
    if t_response then response = t_response end
  end

  local extra = {}
  for k, v in pairs(item) do
    if not KNOWN[k] then extra[k] = v end
  end

  return {
    id = has_id(item) and item.id or new_id(),
    filename = vim.fn.fnamemodify(filename, ':p'),
    kind = kind and kind:lower() or 'note',
    body = body or '',
    response = response,
    lnum = lnum,
    end_lnum = end_lnum,
    context = type(item.context) == 'table' and item.context or nil,
    anchor = parse_anchor(item.anchor),
    created_at = type(item.created_at) == 'number' and item.created_at or os.time(),
    extra = next(extra) ~= nil and extra or nil,
  }
end

local function view_exists()
  return qf_id ~= nil and vim.fn.getqflist({ id = qf_id }).id == qf_id
end

-- Where a comment is now, { sha, lnum, end_lnum, state } (see track.lua), or
-- nil for a record not read through the store (no id or anchor)
function M.pos(c)
  if type(c.id) ~= 'string' or type(c.filename) ~= 'string' or type(c.anchor) ~= 'table' then
    return nil
  end
  -- Required here: track requires snapshots, which requires the store
  return require('quickfix-review.track').pos(c)
end

-- Whether a comment's code changed since it was made (see track.lua)
function M.is_outdated(c)
  local p = M.pos(c)
  return p ~= nil and p.state == 'outdated'
end

-- The lines a comment is displayed at: its pos (where its anchor's lines
-- are now), else its anchor, else the record's top-level lnum/end_lnum (a
-- record not read through the store).
-- Returns: lnum, end_lnum
function M.range(c)
  local r = M.pos(c) or c.anchor or c
  local lnum = r.lnum or c.lnum
  return lnum, r.end_lnum or lnum
end

-- A comment as displayed: "[KIND] body", or "[KIND:L1-5] body" for a range
function M.headline(c)
  local label = c.kind:upper()
  local lnum, end_lnum = M.range(c)
  if end_lnum > lnum then
    label = string.format('%s:L%d-%d', label, lnum, end_lnum)
  end
  return '[' .. label .. '] ' .. c.body
end

-- The quickfix row for a comment: its headline, with " | Response: reply"
-- when it has one. The row carries only the comment's id in user_data; the
-- context stays in the store.
local function view_item(c)
  local text = M.headline(c)
  if c.response then
    text = text .. ' | Response: ' .. c.response
  end
  if M.is_outdated(c) then text = '[outdated] ' .. text end
  local lnum, end_lnum = M.range(c)
  return {
    filename = c.filename,
    lnum = lnum,
    end_lnum = end_lnum,
    col = 1,
    text = text,
    type = c.kind:sub(1, 1):upper(),
    user_data = { id = c.id },
  }
end

local function view_items()
  local items = {}
  for i, c in ipairs(comments) do
    items[i] = view_item(c)
  end
  return items
end

-- Refill the review's quickfix list, keeping its selected entry: the same
-- comment if it is still listed, else the same position (clamped). A refill
-- alone would reset the selection to the first entry.
local function refresh_view()
  if not view_exists() then return end
  local before = vim.fn.getqflist({ id = qf_id, idx = 0, items = 0 })
  local selected = before.items[before.idx]
  local selected_id = selected and type(selected.user_data) == 'table' and selected.user_data.id
  local items = view_items()
  local idx = math.min(before.idx, #items)
  for i, item in ipairs(items) do
    if selected_id and item.user_data.id == selected_id then
      idx = i
      break
    end
  end
  vim.fn.setqflist({}, 'r', { id = qf_id, items = items, title = QF_TITLE })
  if idx > 1 then vim.fn.setqflist({}, 'a', { id = qf_id, idx = idx }) end
end

-- Where the review lives. Per project: log.jsonl (the review), state.json
-- (its cache) and the lock dir `lock`, in the project's storage dir, next to
-- where comments.json used to be. The project root is the git toplevel of the
-- global cwd, else the cwd itself (symlinks resolved). Memoized on the cwd
-- and the storage_dir option, so it is a string compare on every store call.
--
-- With the explicit (deprecated, global) storage_file, the log, cache and
-- lock sit next to that file, named after it (<file>.log.jsonl,
-- <file>.state.json, <file>.lock, <file>.snapshots), so two storage_file
-- values never share a log. The path is used as given, not resolved: migrating renames the file,
-- which would change a resolved path.
local resolved = {}

local function resolve()
  local explicit = config.options.storage_file
  if explicit ~= nil then
    return {
      path = explicit, dir = vim.fn.fnamemodify(explicit, ':h'), explicit = true,
      log = explicit .. '.log.jsonl', state = explicit .. '.state.json', lock = explicit .. '.lock',
      snapshots = explicit .. '.snapshots',
    }
  end
  local cwd = vim.fn.getcwd(-1, -1)
  local opt = config.options.storage_dir
  if resolved.cwd == cwd and resolved.opt == opt then return resolved end

  local root = utils.realpath(utils.git_toplevel(cwd) or cwd)
  local dir
  if type(opt) == 'function' then
    dir = opt(root)
  elseif type(opt) == 'string' then
    dir = opt
  end
  if type(dir) ~= 'string' or dir == '' then
    dir = vim.fn.stdpath('data') .. '/quickfix-review/'
      .. vim.fn.fnamemodify(root, ':t') .. '-' .. vim.fn.sha256(root):sub(1, 12)
  end
  -- ~ and $VARS are expanded; the result is absolute, without a trailing slash
  dir = (vim.fn.fnamemodify(vim.fs.normalize(dir), ':p'):gsub('(.)/+$', '%1'))
  resolved = {
    cwd = cwd, opt = opt, root = root, dir = dir, path = dir .. '/comments.json',
    log = dir .. '/log.jsonl', state = dir .. '/state.json', lock = dir .. '/lock',
    snapshots = dir .. '/snapshots',
  }
  return resolved
end

-- The comments.json of the review: the pre-log storage file, which is
-- migrated into the log (and renamed to comments.json.pre-log.bak) on first use
function M.path()
  return resolve().path
end

-- The review's event log, its source of truth
function M.log_path()
  return resolve().log
end

-- The cache of the replayed log
function M.state_path()
  return resolve().state
end

-- The directory of the review's file snapshots (see snapshots.lua):
-- `snapshots/` in the storage dir, or `<storage_file>.snapshots`
function M.snapshots_dir()
  return resolve().snapshots
end

-- The project's storage directory (for an explicit storage_file, its directory)
function M.dir()
  return resolve().dir
end

-- The project root the storage dir belongs to, or nil for an explicit storage_file
function M.root()
  return resolve().root
end

-- Where comments.json is kept once it has been migrated into the log
local MIGRATED = '.pre-log.bak'
-- state.json is written after this many events, besides on exit and :ReviewSave
local FLUSH_EVERY = 50
local JSON_NIL = { luanil = { object = true, array = true } }

local function mkdir_for(path)
  local parent = vim.fn.fnamemodify(path, ':h')
  if vim.fn.isdirectory(parent) == 0 then pcall(vim.fn.mkdir, parent, 'p') end
end

local function read_bytes(path)
  local fh = io.open(path, 'rb')
  if not fh then return nil end
  local content = fh:read('*a')
  fh:close()
  return content
end

-- The normalized comment for each logged record, so a record is normalized
-- once and an unchanged comment keeps its identity across changes. false for
-- a record that can't be shown (no file or no valid line number).
local views = setmetatable({}, { __mode = 'k' })

local function view_of(record)
  local c = views[record]
  if c == nil then
    c = normalize(record) or false
    if c then
      -- Derived, never logged: a comment from before anchors is anchored at
      -- its line with no snapshot (the fallback search handles it), and
      -- its display position starts at its anchor.
      c.anchor = c.anchor or { lnum = c.lnum, end_lnum = c.end_lnum }
      c.pos = { sha = c.anchor.sha, lnum = c.anchor.lnum, end_lnum = c.anchor.end_lnum, state = 'current' }
    end
    views[record] = c
  end
  return c or nil
end

-- What `reduced` reflects: which log (path, header log_id, inode), how far it
-- has been read (bytes and lines), and the source_sha256 of its imports
local synced
-- Events applied since state.json was last written
local unsaved = 0

local function fresh_sync(loc)
  return { log = loc and loc.log, state = loc and loc.state, offset = 0, lines = 0, imports = {} }
end

local function reset(loc)
  synced = fresh_sync(loc)
  reduced = reduce.new()
  unsaved = 0
end
reset(nil)

-- Messages shown once per session, by key
local notified = {}

local function notify_once(key, msg, level)
  if notified[key] then return end
  notified[key] = true
  vim.notify('quickfix-review: ' .. msg, level)
end

-- The error the review is currently refused for, so it is reported once
-- rather than on every read and change
local bad_notified = nil

local function refuse(e)
  if e ~= bad_notified then
    bad_notified = e
    vim.notify('quickfix-review: ' .. e .. '; the review will not be modified until the file is fixed',
      vim.log.levels.ERROR)
  end
  return false, e
end

-- Run fn with the review's lock held (log.with_lock), creating the storage
-- dir first. Nested calls (a sync inside a change) run under the outer lock.
-- Returns: true and fn's two results, or false and the lock error
local lock_held = false

local function locked(loc, fn)
  if lock_held then return true, fn() end
  mkdir_for(loc.log)
  lock_held = true
  local ok, got, a, b = pcall(log.with_lock, loc.lock, fn)
  lock_held = false
  if not ok then error(got, 0) end
  return got, a, b
end

local function apply(events)
  for _, ev in ipairs(events) do
    if ev.op == 'import' and type(ev.source_sha256) == 'string' then
      synced.imports[ev.source_sha256] = true
    end
    local _, ignored = reduce.apply(reduced, ev)
    if ignored == 'duplicate' then
      notify_once('duplicate', string.format('ignoring logged comments whose id is already in the review'
        .. ' (first: event %s in %s)', tostring(ev.eid), synced.log), vim.log.levels.WARN)
    end
  end
  unsaved = unsaved + #events
end

-- Write state.json (the replayed log, and how far it was read) if events
-- were applied since it was last written, or always with `force`. It is only
-- a cache: a failure is returned, never fatal.
-- Returns: ok (boolean), err (string or nil)
local function flush(force)
  if not synced.log_id or (unsaved == 0 and not force) then return true, nil end
  local doc = {
    log_id = synced.log_id, offset = synced.offset, lines = synced.lines,
    imports = vim.tbl_keys(synced.imports), state = reduced,
  }
  local ok, encoded = pcall(vim.json.encode, doc)
  if not ok then return false, 'could not encode the review cache' end
  -- A new cache gets the log's mode, so a private review's cache is private
  if not uv.fs_stat(synced.state) then
    local stat = uv.fs_stat(synced.log)
    local fd = uv.fs_open(synced.state, 'a', stat and bit.band(stat.mode, 511) or 420)
    if fd then uv.fs_close(fd) end
  end
  local wrote, err = storage.atomic_write(synced.state, encoded)
  if wrote then unsaved = 0 end
  return wrote, err
end

local function is_list(t)
  if type(t) ~= 'table' then return false end
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n == #t
end

-- The reduced state from state.json, if it is a cache of this log (same
-- log_id, no longer than the log); fills `base` with where it was read to
local function load_cache(loc, stat, base)
  local content = read_bytes(loc.state)
  if not content then return nil end
  local ok, doc = pcall(vim.json.decode, content, JSON_NIL)
  if not ok or type(doc) ~= 'table' or type(doc.state) ~= 'table' then return nil end
  local st = doc.state
  if type(doc.log_id) ~= 'string' or type(doc.offset) ~= 'number' or type(doc.lines) ~= 'number'
      or doc.offset > stat.size or not is_list(st.comments) or type(st.trash) ~= 'table'
      -- A cache from before `removed` existed is replayed from the log
      or not is_list(st.removed) then
    return nil
  end
  if log.read_id(loc.log) ~= doc.log_id then return nil end
  base.log_id, base.offset, base.lines = doc.log_id, doc.offset, doc.lines
  for _, sha in ipairs(is_list(doc.imports) and doc.imports or {}) do base.imports[sha] = true end
  return { comments = st.comments, trash = st.trash, removed = st.removed }
end

-- Bring `reduced` up to date with the log: read its tail, or replay it (from
-- state.json if that is valid, unless opts.full) when it is new, was
-- replaced or shrank. On failure nothing changes.
-- Returns: ok (boolean), err (string or nil), changed (boolean)
local function read_log(loc, stat, opts)
  local full = opts.full or not synced.log_id or synced.ino ~= stat.ino or stat.size < synced.offset
  if not full and stat.size == synced.offset then return true, nil, false end
  -- A log that grew may still be another one (rewritten in place rather than
  -- renamed over): a different header log_id means replay it from the start
  if not full then
    local id = log.read_id(loc.log)
    if id and id ~= synced.log_id then full = true end
  end

  local base, state = synced, reduced
  local cached = false
  if full then
    base, state = fresh_sync(loc), nil
    if not opts.full then state = load_cache(loc, stat, base) end
    cached = state ~= nil
    if not state then
      base = fresh_sync(loc)
      state = reduce.new()
    end
  end
  local res, err = log.read(loc.log, base.offset, base.lines)
  if not res then return false, err end
  if base.offset == 0 then base.log_id = res.log_id end

  if full then unsaved = 0 end
  synced, reduced = base, state
  synced.ino = stat.ino
  apply(res.events)
  synced.offset, synced.lines = res.offset, res.lines
  -- A replay that didn't come from the cache is worth caching
  if full and not cached and unsaved == 0 then unsaved = 1 end
  return true, nil, full or #res.events > 0
end

-- Load the records of a comments.json (its raw bytes): upgraded, normalized,
-- hand-copied duplicate ids split, and records that can't be shown dropped
-- with a warning (the original is kept as comments.json.pre-log.bak).
-- Returns: records, or nil and an error
local function load_records(raw, path)
  local list, err = storage.parse(raw, path)
  if not list then return nil, err end
  local loaded, seen, dropped = {}, {}, 0
  for _, item in ipairs(list) do
    local c = type(item) == 'table' and normalize(item) or nil
    if not c then
      dropped = dropped + 1
    else
      -- A hand-copied comment shares its id; give the copy its own, so
      -- remove(id) never deletes both
      if seen[c.id] then c.id = new_id() end
      seen[c.id] = true
      table.insert(loaded, c)
    end
  end
  if dropped > 0 then
    vim.notify(string.format('quickfix-review: dropped %d comment(s) with an invalid line number or no file in %s;'
      .. ' original kept at %s', dropped, path, path .. MIGRATED), vim.log.levels.WARN)
  end
  return loaded
end

local function serialise_all(records)
  local out = {}
  for i, c in ipairs(records) do out[i] = storage.serialise(c) end
  return out
end

-- Move comments.json into a new log: under the lock, write the header and an
-- import of its comments (with the sha256 of its bytes) in one fsync'ed
-- append, then rename it to comments.json.pre-log.bak, which keeps the
-- original bytes. A crash before the rename is finished by the next sync,
-- which finds the import's sha256 in the log. An unreadable comments.json
-- is refused: no log is written and the file is left alone.
-- Returns: ok (boolean), err (string or nil)
local function migrate(loc)
  local got, ok, err = locked(loc, function()
    local st = uv.fs_stat(loc.log)
    if st and st.size > 0 then return true end -- another Neovim did it
    local src = uv.fs_stat(loc.path)
    if not src then return true end
    local raw = read_bytes(loc.path)
    if not raw then return nil, 'Could not read ' .. loc.path end
    local records, lerr = load_records(raw, loc.path)
    if not records then return nil, lerr end
    local import = log.event('import', { source_sha256 = vim.fn.sha256(raw), comments = serialise_all(records) })
    local wrote, werr = log.append(loc.log, { log.new_header(), import }, bit.band(src.mode, 511))
    if not wrote then return nil, 'Could not write ' .. loc.log .. ': ' .. werr end
    local renamed, rerr = uv.fs_rename(loc.path, loc.path .. MIGRATED)
    if not renamed then
      vim.notify(string.format('quickfix-review: migrated %s into %s but could not rename it: %s',
        loc.path, loc.log, tostring(rerr)), vim.log.levels.WARN)
    end
    return true
  end)
  if not got then return false, ok end
  return ok == true, err
end

-- Storage paths whose legacy import has been tried this session
local import_tried = {}

-- First use of a project with neither a log nor a comments.json: copy the
-- comments under the project root out of the legacy global file (old default
-- storage_file) into a new log, as an import event. The legacy file is only
-- read, never upgraded, backed up or rewritten. The log is written even when
-- nothing matches, so the import happens once per project, across restarts:
-- a log is the "already imported" marker.
local function import_legacy(loc)
  if import_tried[loc.log] then return end
  import_tried[loc.log] = true

  local legacy = config.legacy_storage_file()
  if vim.fn.filereadable(legacy) == 0 then return end
  if utils.files_match(legacy, loc.path) or utils.files_match(legacy, loc.log) then return end

  local raw = read_bytes(legacy)
  local list, err = storage.parse(raw, legacy)
  if not list then
    vim.notify('quickfix-review: not importing from ' .. legacy .. ': ' .. err, vim.log.levels.WARN)
    return
  end

  local imported, seen = {}, {}
  for _, item in ipairs(list) do
    local c = type(item) == 'table' and normalize(item) or nil
    if c and utils.is_under(c.filename, loc.root) then
      if seen[c.id] then c.id = new_id() end
      seen[c.id] = true
      table.insert(imported, storage.serialise(c))
    end
  end

  local got, ok, werr = locked(loc, function()
    local st = uv.fs_stat(loc.log)
    if st and st.size > 0 then return 'exists' end -- another Neovim did it
    local import = log.event('import', { source_sha256 = vim.fn.sha256(raw), comments = imported })
    return log.append(loc.log, { log.new_header(), import })
  end)
  if not got or not ok then
    vim.notify('quickfix-review: import from ' .. legacy .. ' failed: ' .. tostring(got and werr or ok),
      vim.log.levels.ERROR)
    return
  end
  if ok == true and #imported > 0 then
    vim.notify(string.format('quickfix-review: imported %d comments from %s', #imported, legacy))
  end
end

-- The log is missing (or empty): migrate comments.json into it, or import
-- from the legacy global file, or leave it to the first change to create
-- Returns: ok (boolean), err (string or nil)
local function init_storage(loc)
  if uv.fs_stat(loc.path) then return migrate(loc) end
  if not loc.explicit then import_legacy(loc) end
  return true, nil
end

-- comments.json versions (path:size:mtime) already looked at
local reappeared_seen = {}

-- comments.json next to an existing log: either a migration that crashed
-- before its rename (the log holds an import with its sha256), which is
-- finished now, or something wrote it after the migration (an external tool,
-- an older plugin). That one is not read, and not deleted: warn once.
local function check_reappeared(loc)
  local st = uv.fs_stat(loc.path)
  if not st then return end
  local key = string.format('%s:%d:%d.%d', loc.path, st.size, st.mtime.sec, st.mtime.nsec)
  if reappeared_seen[key] then return end
  reappeared_seen[key] = true
  local raw = read_bytes(loc.path)
  if raw and synced.imports[vim.fn.sha256(raw)] then
    locked(loc, function()
      if uv.fs_stat(loc.path) then uv.fs_rename(loc.path, loc.path .. MIGRATED) end
    end)
    return
  end
  vim.notify(string.format('quickfix-review: %s reappeared next to the review log %s; it is not read'
    .. ' (the log is the review) and is left alone', loc.path, loc.log), vim.log.levels.WARN)
end

-- Bring the comments up to date with the log (migrating or importing first
-- when there is none). opts.full replays the whole log, ignoring the cache.
-- Returns: ok (boolean), err (string or nil)
local function sync(opts)
  opts = opts or {}
  local loc = resolve()
  local changed = false
  if synced.log ~= loc.log then
    flush()
    reset(loc)
    changed = true
  end
  local stat = uv.fs_stat(loc.log)
  if not stat or stat.size == 0 then
    -- The log was removed: so is the review
    if synced.log_id then
      reset(loc)
      changed = true
    end
    local ok, err = init_storage(loc)
    if not ok then return refuse(err) end
    stat = uv.fs_stat(loc.log)
  end
  if stat and stat.size > 0 then
    local ok, err, read_changed = read_log(loc, stat, opts)
    if not ok then return refuse(err) end
    changed = changed or read_changed
    check_reappeared(loc)
  end
  bad_notified = nil
  if changed then
    local list = {}
    for _, r in ipairs(reduced.comments) do
      local c = view_of(r)
      if c then table.insert(list, c) end
    end
    comments = list
    refresh_view()
    on_change(comments)
  end
  if unsaved >= FLUSH_EVERY then flush() end
  return true
end

-- Append the events build() returns to the log, built against its latest
-- state, all with the log locked. Memory changes only by reading back what
-- was appended, so it never holds a change that isn't on disk. Refuses to
-- change anything if the log (or a comments.json to migrate) is unusable
-- (sync() reports that once) or the lock can't be taken.
-- build() returns: events (a list, possibly empty), result
-- Returns: result, or nil if the change was refused or failed
local function mutate(build)
  local loc = resolve()
  local got, result, err = locked(loc, function()
    if not sync() then return nil end
    local events, res = build()
    if #events == 0 then return res end
    local stat = uv.fs_stat(loc.log)
    if not stat or stat.size == 0 then table.insert(events, 1, log.new_header()) end
    local wrote, werr = log.append(loc.log, events)
    -- Read back what was written: all of it, some or none
    sync()
    if not wrote then return nil, 'Could not write ' .. loc.log .. ': ' .. tostring(werr) end
    return res
  end)
  if not got then result, err = nil, result end
  if err then vim.notify('quickfix-review: ' .. err, vim.log.levels.ERROR) end
  return result
end

-- Called after any change to the comments, including ones read from disk
function M.set_on_change(fn)
  on_change = fn
end

-- Redraw the quickfix view and call on_change after comments moved (a
-- relocation), without reading or writing the log: positions are never logged
function M.refresh()
  refresh_view()
  on_change(comments)
end

-- All comments, in creation order. Treat as read-only.
function M.all()
  sync()
  return comments
end

-- Add a comment
-- Returns: true if it was added, false if it has no file or the change was refused
function M.add(item)
  return mutate(function()
    local c = normalize(item)
    if not c then return {}, false end
    return { log.event('add', { comment = storage.serialise(c) }) }, true
  end) == true
end

-- The comment with this id, or nil. Treat as read-only.
function M.get(id)
  sync()
  for _, c in ipairs(comments) do
    if c.id == id then return c end
  end
  return nil
end

-- The deleted comments, by id (kept in the log, so they can be restored).
-- Treat as read-only.
function M.trash()
  sync()
  local out = {}
  for id, r in pairs(reduced.trash) do
    out[id] = view_of(r) or r
  end
  return out
end

-- The deleted comments, newest removal first: { id, op ('delete' or
-- 'clear'), ts (unix ms, or nil), comment (its view, or the raw record) }
function M.trash_list()
  sync()
  local out = {}
  for i = #reduced.removed, 1, -1 do
    local e = reduced.removed[i]
    local r = reduced.trash[e.id]
    if r then
      table.insert(out, { id = e.id, op = e.op, ts = e.ts, comment = view_of(r) or r })
    end
  end
  return out
end

-- The most recent removal: { op = 'delete', ids = { id } } for a delete, or
-- { op = 'clear', ids = {...} } holding every comment of the last clear still
-- in the trash; nil when the trash is empty
function M.last_removal()
  sync()
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

-- Remove every comment for which pred(comment) is true: one delete event,
-- holding the comment, per match
-- Returns: number removed, or nil if the change was refused (unreadable file)
function M.remove_if(pred)
  return mutate(function()
    local events = {}
    for _, r in ipairs(reduced.comments) do
      local c = view_of(r)
      if c and pred(c) then
        table.insert(events, log.event('delete', { id = r.id, comment = r }))
      end
    end
    return events, #events
  end)
end

-- Remove the comment with this id
-- Returns: number removed (0 if there is none), or nil if the change was refused
function M.remove(id)
  return M.remove_if(function(c) return c.id == id end)
end

-- Remove every comment (one clear event holding them all)
-- Returns: true, or nil if the change was refused
function M.clear()
  return mutate(function()
    if #reduced.comments == 0 then return {}, true end
    return { log.event('clear', { comments = reduced.comments }) }, true
  end)
end

-- Replay the whole log, ignoring the cache
-- Returns: ok (boolean), message (string)
function M.reload()
  local ok, err = sync({ full = true })
  if not ok then return false, err end
  return true, string.format('Review loaded: %d comments', #comments)
end

-- Write the cache (state.json) now. Every change is already in the log, so
-- this is never needed for the review to be saved.
-- Returns: ok (boolean), message (string)
function M.save()
  local ok, err = sync()
  if not ok then return false, err end
  if not synced.log_id then
    return true, 'Review saved (no comments yet)'
  end
  local wrote, werr = flush(true)
  if not wrote then
    return false, 'Could not write ' .. synced.state .. ': ' .. tostring(werr)
  end
  return true, string.format('Review saved to %s (%d comments)', synced.log, #comments)
end

-- Write the cache if events were applied since it was last written (on exit)
function M.flush()
  flush()
end

-- Publish the comments as a quickfix list and make it the current one
function M.show()
  M.all()
  if view_exists() then
    refresh_view()
    local nr = vim.fn.getqflist({ id = qf_id, nr = 0 }).nr
    local current = vim.fn.getqflist({ nr = 0 }).nr
    if nr ~= current then
      vim.cmd('silent ' .. (nr > current and 'cnewer ' or 'colder ') .. math.abs(nr - current))
    end
  else
    -- Record the id before filling, so the FileType event fired by the fill
    -- already sees the review as the current list
    vim.fn.setqflist({}, ' ', { title = QF_TITLE })
    qf_id = vim.fn.getqflist({ id = 0 }).id
    vim.fn.setqflist({}, 'r', { id = qf_id, items = view_items(), title = QF_TITLE })
  end
end

-- Whether the current quickfix list is the review view
function M.is_current_view()
  return view_exists() and vim.fn.getqflist({ id = 0 }).id == qf_id
end

return M
