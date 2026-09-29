-- The review's event log, read into memory: `reduced` (the log replayed
-- through reduce.lua) and `synced` (how far it was read), the lock every
-- write takes (locked), applying read events (apply), and the state.json
-- cache of the replay (flush, load_cache). Callers reach this state only
-- through the accessors below, fetched at each use: reset and read_log
-- replace the tables.
local M = {}

local location = require('quickfix-review.store.location')
local log = require('quickfix-review.log')
local notify = require('quickfix-review.notify')
local reduce = require('quickfix-review.reduce')
local storage = require('quickfix-review.storage')

local uv = vim.uv or vim.loop

-- state.json is written after this many events, besides on exit and :ReviewSave
M.FLUSH_EVERY = 50
local JSON_NIL = { luanil = { object = true, array = true } }

-- The log replayed: records as logged, and the trash
local reduced = reduce.new()
-- What `reduced` reflects: which log (path, header log_id, inode), how far it
-- has been read (bytes and lines), and the source_sha256 of its imports
local synced
-- Events applied since state.json was last written
local unsaved = 0
-- Set when `reduced` is a comments.json loaded read-only (its storage dir is
-- not writable, so it can't be migrated): { log = the log it stands in for,
-- key = the comments.json version (size:mtime) loaded }
local readonly = nil

local function fresh_sync(loc)
  return { log = loc and loc.log, state = loc and loc.state, offset = 0, lines = 0, imports = {} }
end

-- Unreadable lines of the log already warned about (log.read's `seen`), so
-- each is warned about once: { log = path, log_id = its header's, lines = {} }
local log_seen = nil

-- The `seen` table for reading the log at `loc`, new when the log (path or
-- header log_id) is another one than the lines were seen in
function M.seen_lines(loc)
  local id = log.read_id(loc.log)
  if not (log_seen and log_seen.log == loc.log and log_seen.log_id == id) then
    log_seen = { log = loc.log, log_id = id, lines = {} }
  end
  return log_seen.lines
end

-- The log (path:ino:size:mtime) comments.json was last checked against (see
-- check_reappeared): a sync that finds the log unchanged skips that stat
local reappeared_log_key

function M.reset(loc)
  log_seen = nil
  reappeared_log_key = nil
  synced = fresh_sync(loc)
  reduced = reduce.new()
  unsaved = 0
  readonly = nil
end
M.reset(nil)

-- The error the review is currently refused for, so it is reported once
-- rather than on every read and change
local bad_notified = nil

function M.refuse(e)
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

function M.locked(loc, fn)
  if lock_held then return true, fn() end
  local mk_ok, mk_err = location.mkdir_for(loc.log)
  if not mk_ok then return false, 'Could not create ' .. vim.fn.fnamemodify(loc.log, ':h') .. ': ' .. mk_err end
  lock_held = true
  local ok, got, a, b = pcall(log.with_lock, loc.lock, fn)
  lock_held = false
  if not ok then error(got, 0) end
  return got, a, b
end

function M.apply(events)
  for _, ev in ipairs(events) do
    if ev.op == 'import' and type(ev.source_sha256) == 'string' then
      synced.imports[ev.source_sha256] = true
    elseif ev.op == 'checkpoint' and type(ev.imports) == 'table' then
      -- The imports of the log it rotated, so a crashed migration is still
      -- recognised (see check_reappeared)
      for _, sha in ipairs(ev.imports) do
        if type(sha) == 'string' then synced.imports[sha] = true end
      end
    end
    local _, ignored = reduce.apply(reduced, ev)
    if ignored == 'duplicate' then
      notify.once('duplicate', string.format('ignoring logged comments whose id is already in the review'
        .. ' (first: event %s in %s)', tostring(ev.eid), synced.log), vim.log.levels.WARN)
    end
  end
  unsaved = unsaved + #events
end

-- Write state.json (the replayed log, and how far it was read) if events
-- were applied since it was last written, or always with `force`. It is only
-- a cache: a failure is returned, never fatal.
-- Returns: ok (boolean), err (string or nil)
function M.flush(force)
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
  local content = location.read_bytes(loc.state)
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
  -- A log rewritten in place may keep its log_id: an offset mid-line is stale
  if not log.at_line_start(loc.log, doc.offset) then return nil end
  base.log_id, base.offset, base.lines = doc.log_id, doc.offset, doc.lines
  for _, sha in ipairs(is_list(doc.imports) and doc.imports or {}) do base.imports[sha] = true end
  return { comments = st.comments, trash = st.trash, removed = st.removed }
end

-- Bring `reduced` up to date with the log: read its tail, or replay it (from
-- state.json if that is valid, unless opts.full) when it is new, was
-- replaced or shrank. On failure nothing changes.
-- Returns: ok (boolean), err (string or nil), changed (boolean)
function M.read_log(loc, stat, opts)
  local full = opts.full or not synced.log_id or synced.ino ~= stat.ino or stat.size < synced.offset
  -- A log of the same inode, and no shorter, may still be another one
  -- (rewritten in place rather than renamed over): a different (or no)
  -- header log_id means replay it from the start
  if not full and log.read_id(loc.log) ~= synced.log_id then full = true end
  -- ... and one rewritten in place under the same header is caught when the
  -- offset read to no longer follows a \n
  if not full and not log.at_line_start(loc.log, synced.offset) then full = true end
  if not full and stat.size == synced.offset then return true, nil, false end

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
  local res, err = log.read(loc.log, base.offset, base.lines, M.seen_lines(loc))
  -- The log was replaced (rotated, see rotate) between the stat and the
  -- read: what was read (or failed to be) is another file than was stat'ed.
  -- Read the new one instead, once.
  local now = not opts.retried and uv.fs_stat(loc.log)
  if now and now.ino ~= stat.ino and (not res or (res.ino and res.ino ~= stat.ino)) then
    return M.read_log(loc, now, { full = opts.full, retried = true })
  end
  if not res then return false, err end
  if base.offset == 0 then base.log_id = res.log_id end

  if full then unsaved = 0 end
  synced, reduced = base, state
  synced.ino = stat.ino
  M.apply(res.events)
  synced.offset, synced.lines = res.offset, res.lines
  -- A replay that didn't come from the cache is worth caching
  if full and not cached and unsaved == 0 then unsaved = 1 end
  return true, nil, full or #res.events > 0
end

-- The error for a change to a review loaded read-only, or nil
function M.readonly_error(loc)
  if not (readonly and readonly.log == loc.log) then return nil end
  return string.format('%s is not writable: %s is shown read-only; the change was not saved', loc.dir, loc.path)
end

-- Accessors. `reduced` and `synced` are replaced by reset and read_log:
-- fetch them at each use, never keep them.

-- The log replayed: { comments, trash, removed } (see reduce.lua)
function M.reduced() return reduced end

-- What `reduced` reflects: { log, state, log_id, ino, offset, lines, imports }
function M.synced() return synced end

-- Events applied since state.json was last written
function M.unsaved() return unsaved end

-- The comments.json loaded read-only ({ log, key }), or nil
function M.readonly() return readonly end

function M.set_readonly(v) readonly = v end

-- The log key comments.json was last checked against (see check_reappeared)
function M.reappeared_key() return reappeared_log_key end

function M.set_reappeared_key(v) reappeared_log_key = v end

-- The review read fine: a later refusal is reported again
function M.clear_refusal() bad_notified = nil end

return M
