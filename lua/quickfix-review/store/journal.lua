-- The review's journal (docs/journal.md), read into memory: the events
-- replayed through reduce.lua, and where reading got to. It reads, appends
-- to, seals and checkpoints the journal (numbered segments in `events/`,
-- checkpoints in `checkpoints/`); it also runs a review shown read-only
-- from a comments.json (mode 'readonly'). Deciding which (and migrating
-- comments.json) is store/migrate.lua's job.
--
-- The state is private: callers get views of it (comments, get, trash,
-- removed, has_import) at each use, and never a table to keep or change.
local M = {}

local checkpoint = require('quickfix-review.store.checkpoint')
local config = require('quickfix-review.config')
local location = require('quickfix-review.store.location')
local lock = require('quickfix-review.store.lock')
local log = require('quickfix-review.log')
local notify = require('quickfix-review.notify')
local reduce = require('quickfix-review.reduce')
local segment = require('quickfix-review.store.segment')

local uv = vim.uv or vim.loop

-- A checkpoint is written once the tail past the newest one is this large
-- (or checkpoint_every events long)
M.CHECKPOINT_BYTES = 256 * 1024

-- The journal replayed: records as logged, and the trash
local reduced = reduce.new()
-- What `reduced` reflects:
-- { key = the review (loc.events), loc, mode = nil (no journal yet), 'v3'
--   or 'readonly', and for 'v3': path (the file read last: the active
--   segment), seg (its number), ino, offset and lines (how far it was read),
--   journal_id, imports (the source_sha256 of every import), since = { events, bytes } (the tail read
--   past the newest checkpoint this instance knows), sealed (the
--   { size, sha } of each segment before the active one, by number, as
--   its bytes were read into the state: what a checkpoint records, see
--   store/checkpoint.lua), readonly_key (the comments.json version loaded,
--   for 'readonly') }
local synced

-- Unreadable lines already warned about, by file path and header id, so
-- each is warned about once
local seen = {}

local function seen_lines(path, id)
  local key = path .. '\0' .. tostring(id)
  seen[key] = seen[key] or {}
  return seen[key]
end

local function fresh(loc, mode)
  return { key = loc and loc.events, loc = loc, mode = mode, imports = {}, since = { events = 0, bytes = 0 },
    sealed = {} }
end
synced = fresh(nil, nil)

-- Forget the review in memory and start on the one at `loc`, with no
-- journal loaded yet (the next sync loads it)
function M.switch(loc)
  synced = fresh(loc, nil)
  reduced = reduce.new()
end

-- The review in memory (loc.events of its location), or nil
function M.key() return synced.key end

-- nil (no journal yet), 'v3' or 'readonly'
function M.mode() return synced.mode end

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

-- The review read fine: a later refusal is reported again
function M.clear_refusal() bad_notified = nil end

-- Run fn with the review's lock held (store/lock.lua), creating the storage
-- dir first. Nested calls on the same review (a sync inside a change) run
-- under the outer lock; another review's lock is taken as usual.
-- Returns: true and fn's two results, or false and the lock error
function M.locked(loc, fn)
  local mk_ok, mk_err = location.mkdir_for(loc.flock)
  if not mk_ok then return false, 'Could not create ' .. vim.fn.fnamemodify(loc.flock, ':h') .. ': ' .. mk_err end
  -- Through the module table, so tests can wrap lock.with_lock
  local ok, got, a, b = pcall(lock.with_lock, loc, fn)
  if not ok then error(got, 0) end
  return got, a, b
end

-- Apply events read from a segment to `state`, noting imports in
-- `imports`; `where` names the file, for the duplicate warning. When
-- `ids` is a table, every comment id the events mention is set in it, and
-- when `records` is a list too, every comment record they carry is appended
-- to it (reduce.event_ids, read before the event is applied and pruned)
local function apply(state, imports, events, where, ids, records)
  for _, ev in ipairs(events) do
    if ids then reduce.event_ids(ev, ids, records) end
    if ev.op == 'import' and type(ev.source_sha256) == 'string' then
      imports[ev.source_sha256] = true
    end
    local _, ignored = reduce.apply(state, ev)
    if ignored == 'duplicate' then
      notify.once('duplicate', string.format('ignoring logged comments whose id is already in the review'
        .. ' (first: event %s in %s)', tostring(ev.eid), where), vim.log.levels.WARN)
    end
  end
end

-- The headers of the segments of the journal in `events` (a dir), checked:
-- numbered 1..N with no gap, all of one journal_id.
-- Returns: { segs = { n... }, journal_id }, or nil and an error
function M.inspect(events)
  local segs = segment.list(events)
  if #segs == 0 then return nil, 'no segments in ' .. events end
  local journal_id
  for i, n in ipairs(segs) do
    local path = segment.path(events, n)
    if n ~= i then return nil, string.format('%s is missing (the journal has a gap)', segment.path(events, i)) end
    local h = log.read_header(path)
    if h and log.too_new(h) then
      return nil, string.format('%s was written by a newer version of quickfix-review (format v%s, this'
        .. ' version reads up to v%d); upgrade the plugin to read or change it', path, tostring(h.v), log.VERSION)
    end
    if not h then return nil, path .. ' has no header line' end
    if h.v ~= log.VERSION then return nil, string.format('%s is not a v%d segment', path, log.VERSION) end
    if not journal_id then
      journal_id = h.journal_id
    elseif h.journal_id ~= journal_id then
      return nil, string.format('%s belongs to another journal (journal_id %s, not %s)', path,
        tostring(h.journal_id), journal_id)
    end
  end
  return { segs = segs, journal_id = journal_id }
end

-- The { size, sha } of the whole of segment file `path`, once read to
-- `offset` (from inode `ino`) into the state, read through one fd: nil if
-- it is now another file or shorter, as the hash would then not be of the
-- bytes the state came from
local function hash_read(path, ino, offset)
  local data, st = segment.read_fd(path)
  if not data or st.ino ~= ino or #data < offset then return nil end
  local sha = segment.sha(data)
  return sha and { size = #data, sha = sha } or nil
end

-- Replay the journal in `events` into a new state, from its newest valid
-- checkpoint in `checkpoints` (unless that is nil). Only reads. When `ids`
-- is a table, the ids the replayed events mention are collected in it (see
-- apply) and returned as .ids, and with `records` a list the comment
-- records they carry, returned as .records; pass checkpoints = nil for
-- every event.
-- Returns: { state, imports, seg, path, ino, offset, lines, journal_id,
-- since = { events, bytes }, sealed, ids, records }, or nil and an error
function M.replay(events, checkpoints, ids, records)
  local j, err = M.inspect(events)
  if not j then return nil, err end
  local state, imports = reduce.new(), {}
  local from_seg, from_offset, from_lines = 1, 0, 0
  local out = { journal_id = j.journal_id, since = { events = 0, bytes = 0 }, sealed = {} }
  if checkpoints then
    -- Each sealed segment hashed at most once in this replay
    local hashes = {}
    for _, cp in ipairs((checkpoint.list(checkpoints))) do
      local got = checkpoint.load(cp.path, { events = events, journal_id = j.journal_id }, hashes)
      if got then
        state, imports = got.state, got.imports
        from_seg, from_offset, from_lines = got.seg, got.offset, got.lines
        for i, h in pairs(got.sealed) do out.sealed[i] = h end
        break
      end
    end
  end
  for _, n in ipairs(j.segs) do
    if n >= from_seg then
      local path = segment.path(events, n)
      local offset = n == from_seg and from_offset or 0
      local res, rerr = log.read(path, offset, n == from_seg and from_lines or 0,
        seen_lines(path, j.journal_id))
      if not res then return nil, rerr end
      apply(state, imports, res.events, path, ids, records)
      out.since.events = out.since.events + #res.events
      out.since.bytes = out.since.bytes + res.offset - offset
      out.seg, out.path, out.ino, out.offset, out.lines = n, path, res.ino, res.offset, res.lines
      -- Missing when it can't be hashed: no checkpoint is written then
      if n < j.segs[#j.segs] then out.sealed[n] = hash_read(path, res.ino, res.offset) end
    end
  end
  out.state, out.imports, out.ids, out.records = state, imports, ids, records
  return out
end

-- Load the journal at `loc` (from its newest valid checkpoint, unless
-- opts.full). On failure nothing changes.
-- Returns: ok, err
function M.load(loc, opts)
  local r, err = M.replay(loc.events, not (opts and opts.full) and loc.checkpoints or nil)
  if not r then return false, err end
  synced = fresh(loc, 'v3')
  for _, k in ipairs({ 'journal_id', 'seg', 'path', 'ino', 'offset', 'lines', 'imports', 'since', 'sealed' }) do
    synced[k] = r[k]
  end
  reduced = r.state
  return true, nil
end

-- Show `records` (serialised comments) read-only for the review at `loc`,
-- loaded from the comments.json version `key`
function M.load_readonly(loc, records, key)
  synced = fresh(loc, 'readonly')
  synced.readonly_key = key
  reduced = reduce.new()
  reduce.apply(reduced, { op = 'import', comments = records })
end

-- The comments.json version shown read-only, or nil
function M.readonly_key() return synced.mode == 'readonly' and synced.readonly_key or nil end

-- The error for a change to a review loaded read-only, or nil
function M.readonly_error(loc)
  if not (synced.mode == 'readonly' and synced.key == loc.events) then return nil end
  return string.format('%s is not writable: %s is shown read-only; the change was not saved', loc.dir, loc.path)
end

-- Read what was appended since the last read: the tail of the file being
-- read, then any newer segment (the current one is finished first: once
-- N+1 exists, nothing more is written to N). A file that was replaced,
-- shrank or vanished, or a segment of another journal, means the review
-- must be loaded again (`stale`). On failure nothing changes.
-- Returns: ok, err, changed, stale
function M.read_tail(loc)
  if synced.key ~= loc.events or synced.mode ~= 'v3' then return true, nil, false, true end
  local st = uv.fs_stat(synced.path)
  if not st or st.ino ~= synced.ino or st.size < synced.offset then return true, nil, false, true end
  local next_path = segment.path(loc.events, synced.seg + 1)
  local has_next = uv.fs_stat(next_path) ~= nil
  if st.size == synced.offset and not has_next then return true, nil, false, false end
  local changed = false
  local id = synced.journal_id
  local function read(path, from, lines)
    local res, err = log.read(path, from, lines, seen_lines(path, id))
    if not res then return nil, err end
    apply(reduced, synced.imports, res.events, path)
    synced.since.events = synced.since.events + #res.events
    synced.since.bytes = synced.since.bytes + res.offset - from
    changed = changed or #res.events > 0
    return res
  end
  if st.size > synced.offset or has_next then
    local res, err = read(synced.path, synced.offset, synced.lines)
    if not res then return false, err, changed, false end
    synced.offset, synced.lines = res.offset, res.lines
  end
  while has_next do
    -- The segment read to its end is sealed: its hash, for checkpoints
    synced.sealed[synced.seg] = hash_read(synced.path, synced.ino, synced.offset)
    local h = log.read_header(next_path)
    -- Created complete (see segment.create): no header is another journal's
    if not h or h.journal_id ~= synced.journal_id then return true, nil, changed, true end
    local nst = uv.fs_stat(next_path)
    local n = synced.seg + 1
    local after = segment.path(loc.events, n + 1)
    has_next = uv.fs_stat(after) ~= nil
    local res, err = read(next_path, 0, 0)
    if not res then return false, err, changed, false end
    synced.seg, synced.path, synced.ino, synced.offset, synced.lines = n, next_path, nst.ino, res.offset, res.lines
    next_path = after
  end
  return true, nil, changed, false
end

-- The file mode of the review's files: the active file's, so a private
-- review stays private
local function file_mode()
  local st = synced.path and uv.fs_stat(synced.path)
  return st and bit.band(st.mode, 511) or 420
end

-- Start the journal at `loc`: segment 1, holding a new header and
-- `events` (an import, when migrating comments.json), created complete.
-- Call with the lock held; the next sync loads it.
-- Returns: 'created', 'exists', or nil and an error
function M.create(loc, events, mode)
  local all = { log.segment_header(log.new_journal_id(), 1) }
  vim.list_extend(all, events or {})
  return segment.create(loc.events, 1, all, mode)
end

-- Append `events` to the active segment. Call with
-- the lock held, right after a sync: the active segment is then the
-- highest-numbered one. Memory changes only by reading it back (a sync).
-- Returns: as log.append
function M.append(loc, events)
  if synced.key ~= loc.events or synced.mode ~= 'v3' then
    return false, 'the review is not loaded'
  end
  -- log.append creates a missing file: never a segment without its header
  if not uv.fs_stat(synced.path) then return false, synced.path .. ' is missing' end
  return log.append(synced.path, events)
end

-- A positive number option, or its default
local function option(name)
  local v = config.options[name]
  if type(v) == 'number' and v > 0 then return v end
  return config.defaults[name]
end

-- The active segment as read into the state, for a checkpoint at the
-- current position: the sha256 of its bytes up to it and the hashes those
-- name, read through one fd that must still be the file read (its inode,
-- and no shorter), so the hash is of the bytes the state came from
-- Returns: prefix_sha, refs; or nil and an error
local function current_prefix()
  local data, st = segment.read_fd(synced.path, synced.offset)
  if not data then return nil, st end
  if st.ino ~= synced.ino or #data ~= synced.offset then return nil, synced.path .. ' was replaced' end
  local sha = segment.sha(data)
  if not sha then return nil, 'could not hash ' .. synced.path end
  return sha, segment.refs_of(data)
end

-- Write a checkpoint at the current position, the state encoded before the
-- lock is taken (unless the caller holds it). The tail counts restart. Not
-- written (an error) when the hashes of the bytes the state came from are
-- not all known: load would reject it.
-- Returns: ok, err
function M.write_checkpoint(loc)
  if synced.mode ~= 'v3' or synced.key ~= loc.events then return true, nil end
  local seg, offset = synced.seg, synced.offset
  local prefix_sha, refs = current_prefix()
  if not prefix_sha then return false, 'no checkpoint written: ' .. tostring(refs) end
  local sealed = {}
  for i = 1, seg - 1 do
    sealed[i] = synced.sealed[i]
    if not sealed[i] then return false, 'no checkpoint written: segment ' .. i .. ' was not hashed' end
  end
  local encoded, err = checkpoint.encode(synced.journal_id, seg, offset, synced.lines, reduced, synced.imports,
    refs, prefix_sha, sealed)
  if not encoded then return false, err end
  local j = { events = loc.events, journal_id = synced.journal_id }
  local mode = file_mode()
  local got, ok, werr = M.locked(loc, function()
    return checkpoint.write(loc.checkpoints, j, seg, offset, encoded, mode, option('checkpoint_keep'))
  end)
  if not got then return false, ok end
  if ok and synced.seg == seg and synced.offset == offset then synced.since = { events = 0, bytes = 0 } end
  return ok, werr
end

-- Whether the tail past the newest checkpoint is long enough for another
function M.checkpoint_due()
  return synced.mode == 'v3'
    and (synced.since.events >= option('checkpoint_every') or synced.since.bytes >= M.CHECKPOINT_BYTES)
end

-- Seal the active segment if it has grown past segment_max_bytes: write
-- its .refs, create the next segment (its header only), move to it and
-- write a checkpoint there. Call with the lock held, right after a sync.
-- A failure is only warned about: every event is already in the journal.
-- Returns: true if a new segment was started
function M.seal_if_due(loc)
  if synced.mode ~= 'v3' or synced.key ~= loc.events then return false end
  local st = uv.fs_stat(synced.path)
  if not st or st.size < option('segment_max_bytes') then return false end
  local mode = file_mode()
  local n = synced.seg
  local function warn(e)
    vim.notify('quickfix-review: could not seal ' .. synced.path .. ': ' .. tostring(e), vim.log.levels.WARN)
    return false
  end
  local ok, err, hash = segment.write_refs(loc.events, n, mode)
  if not ok then return warn(err) end
  -- Read to its end under the lock: these are the bytes the state holds
  -- (read_tail hashes it again as it moves on)
  synced.sealed[n] = hash
  local created, cerr = segment.create(loc.events, n + 1, { log.segment_header(synced.journal_id, n + 1) }, mode)
  if not created then return warn(cerr) end
  local rok, rerr, _, stale = M.read_tail(loc)
  if not rok or stale or synced.seg ~= n + 1 then return warn(rerr or 'the new segment could not be read') end
  M.write_checkpoint(loc)
  return true
end

-- Write a checkpoint if events were read past the newest one (on exit), or
-- always with `force` (:ReviewSave). Only a cache: a failure is returned,
-- never fatal.
-- Returns: ok, err
function M.flush(force)
  if synced.mode ~= 'v3' or not synced.loc then return true, nil end
  if synced.since.events == 0 and not force then return true, nil end
  return M.write_checkpoint(synced.loc)
end

-- Where the review is read to: { mode, path, seg, offset, journal_id }
function M.position()
  return { mode = synced.mode, path = synced.path, seg = synced.seg, offset = synced.offset,
    journal_id = synced.journal_id }
end

-- Views of the state. Treat every table returned as read-only.

-- The live comment records, in the order they were added
function M.comments() return reduced.comments end

-- The live record with this id, or nil
function M.get(id) return reduce.get(reduced, id) end

-- The trashed record with this id, or nil
function M.trashed(id) return reduced.trash[id] end

-- The trashed records, by id
function M.trash() return reduced.trash end

-- The removals, in the order they were made: { id, op, eid, ts }...
function M.removed() return reduced.removed end

-- The old project roots of the review (rebase events, see reduce.lua), or
-- nil for a state from before them
function M.rebases() return reduced.rebases end

-- Whether an import with this source_sha256 is in the journal
function M.has_import(sha) return synced.imports[sha] == true end

return M
