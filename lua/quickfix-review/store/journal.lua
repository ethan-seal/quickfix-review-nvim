-- The review's journal (docs/journal.md), read into memory: the events
-- replayed through reduce.lua, and where reading got to. It reads, appends
-- to, seals and checkpoints a v3 journal (numbered segments in `events/`,
-- checkpoints in `checkpoints/`); it also runs a review whose v2 log could
-- not be migrated (mode 'v2': log.jsonl read and appended as one segment,
-- never sealed nor checkpointed) and one shown read-only from a
-- comments.json (mode 'readonly'). Deciding which (and migrating) is
-- store/migrate.lua's job.
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
-- { key = the review (loc.events), loc, mode = nil (no journal yet), 'v3',
--   'v2' or 'readonly', and for 'v3' and 'v2': path (the file read last:
--   the active segment, or log.jsonl), seg (its number; 1 in 'v2'), ino,
--   offset and lines (how far it was read), journal_id and migrated (how
--   many segments are migrated v2 logs) for 'v3', imports (the
--   source_sha256 of every import), since = { events, bytes } (the tail read
--   past the newest checkpoint this instance knows), readonly_key (the
--   comments.json version loaded, for 'readonly') }
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
  return { key = loc and loc.events, loc = loc, mode = mode, imports = {}, since = { events = 0, bytes = 0 } }
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

-- nil (no journal yet), 'v3', 'v2' or 'readonly'
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
-- under the outer lock; another review's lock is taken as usual. `both`
-- also takes the v2 mkdir lock, which Neovims running the v2 code respect
-- (a migration, and every write of a review still in v2).
-- Returns: true and fn's two results, or false and the lock error
function M.locked(loc, fn, both)
  local mk_ok, mk_err = location.mkdir_for(loc.log)
  if not mk_ok then return false, 'Could not create ' .. vim.fn.fnamemodify(loc.log, ':h') .. ': ' .. mk_err end
  -- Through the module table, so tests can wrap lock.with_lock
  local ok, got, a, b = pcall(both and lock.with_both or lock.with_lock, loc, fn)
  if not ok then error(got, 0) end
  return got, a, b
end

-- Apply events read from segment `seg` to `state`, noting imports in
-- `imports`; `where` names the file, for the duplicate warning
local function apply(state, imports, seg, events, where)
  for _, ev in ipairs(events) do
    if ev.op == 'import' and type(ev.source_sha256) == 'string' then
      imports[ev.source_sha256] = true
    elseif ev.op == 'checkpoint' and type(ev.imports) == 'table' then
      -- A v2 rotation checkpoint: the imports of the log it rotated, so a
      -- crashed comments.json migration is still recognised
      for _, sha in ipairs(ev.imports) do
        if type(sha) == 'string' then imports[sha] = true end
      end
    end
    local _, ignored = reduce.apply_in_segment(state, seg, ev)
    if ignored == 'duplicate' then
      notify.once('duplicate', string.format('ignoring logged comments whose id is already in the review'
        .. ' (first: event %s in %s)', tostring(ev.eid), where), vim.log.levels.WARN)
    end
  end
end

-- The headers of the segments of the journal in `events` (a dir), checked:
-- numbered 1..N with no gap, every segment after the migrated v2 ones a v3
-- segment of one journal_id.
-- Returns: { segs = { n... }, journal_id, migrated }, or nil and an error
function M.inspect(events)
  local segs = segment.list(events)
  if #segs == 0 then return nil, 'no segments in ' .. events end
  local journal_id, migrated
  for i, n in ipairs(segs) do
    local path = segment.path(events, n)
    if n ~= i then return nil, string.format('%s is missing (the journal has a gap)', segment.path(events, i)) end
    local h = log.read_header(path)
    if h and log.too_new(h) then
      return nil, string.format('%s was written by a newer version of quickfix-review (format v%s, this'
        .. ' version reads up to v%d); upgrade the plugin to read or change it', path, tostring(h.v), log.VERSION)
    end
    if h and h.v == 3 and h.journal_id then
      if not journal_id then
        journal_id, migrated = h.journal_id, n - 1
      elseif h.journal_id ~= journal_id then
        -- Segments of the migrated v2 logs (n <= migrated) have their own
        -- log_ids and are exempt
        return nil, string.format('%s belongs to another journal (journal_id %s, not %s)', path,
          tostring(h.journal_id), journal_id)
      end
    elseif not h then
      return nil, path .. ' has no header line'
    elseif journal_id then
      return nil, path .. ' is not a segment of journal ' .. journal_id
    end
  end
  if not journal_id then return nil, 'no v3 segment in ' .. events end
  return { segs = segs, journal_id = journal_id, migrated = migrated }
end

-- Replay the journal in `events` into a new state, from its newest valid
-- checkpoint in `checkpoints` (unless that is nil). Only reads.
-- Returns: { state, imports, seg, path, ino, offset, lines, journal_id,
-- migrated, since = { events, bytes } }, or nil and an error
function M.replay(events, checkpoints)
  local j, err = M.inspect(events)
  if not j then return nil, err end
  local state, imports = reduce.new(), {}
  local from_seg, from_offset, from_lines = 1, 0, 0
  if checkpoints then
    for _, cp in ipairs((checkpoint.list(checkpoints))) do
      local got = checkpoint.load(cp.path, { events = events, journal_id = j.journal_id })
      if got then
        state, imports = got.state, got.imports
        from_seg, from_offset, from_lines = got.seg, got.offset, got.lines
        break
      end
    end
  end
  local out = { journal_id = j.journal_id, migrated = j.migrated, since = { events = 0, bytes = 0 } }
  for _, n in ipairs(j.segs) do
    if n >= from_seg then
      local path = segment.path(events, n)
      local offset = n == from_seg and from_offset or 0
      local res, rerr = log.read(path, offset, n == from_seg and from_lines or 0,
        seen_lines(path, j.journal_id))
      if not res then return nil, rerr end
      apply(state, imports, n, res.events, path)
      out.since.events = out.since.events + #res.events
      out.since.bytes = out.since.bytes + res.offset - offset
      out.seg, out.path, out.ino, out.offset, out.lines = n, path, res.ino, res.offset, res.lines
    end
  end
  out.state, out.imports = state, imports
  return out
end

-- Load the v3 journal at `loc` (from its newest valid checkpoint, unless
-- opts.full). On failure nothing changes.
-- Returns: ok, err
function M.load(loc, opts)
  local r, err = M.replay(loc.events, not (opts and opts.full) and loc.checkpoints or nil)
  if not r then return false, err end
  synced = fresh(loc, 'v3')
  for _, k in ipairs({ 'journal_id', 'migrated', 'seg', 'path', 'ino', 'offset', 'lines', 'imports', 'since' }) do
    synced[k] = r[k]
  end
  reduced = r.state
  return true, nil
end

-- The v2 log at `path`, replayed on its own (its leading checkpoint, if
-- any, is its base, as for segment 1)
-- Returns: the read result (log.read's) with .state and .imports, or nil
-- and an error
function M.replay_v2(path)
  local res, err = log.read(path, 0, 0, seen_lines(path, log.read_id(path)))
  if not res then return nil, err end
  if log.is_tombstone(res.header) then return nil, path .. ' was moved to a v3 journal' end
  res.state, res.imports = reduce.new(), {}
  apply(res.state, res.imports, 1, res.events, path)
  return res
end

-- Load the review at `loc` from its v2 log (loc.log), not migrated
-- Returns: ok, err
function M.load_v2(loc)
  local res, err = M.replay_v2(loc.log)
  if not res then return false, err end
  synced = fresh(loc, 'v2')
  synced.path, synced.seg, synced.ino, synced.offset, synced.lines = loc.log, 1, res.ino, res.offset, res.lines
  synced.log_id, synced.imports = res.log_id, res.imports
  reduced = res.state
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
  if synced.key ~= loc.events or (synced.mode ~= 'v3' and synced.mode ~= 'v2') then
    return true, nil, false, true
  end
  local st = uv.fs_stat(synced.path)
  if not st or st.ino ~= synced.ino or st.size < synced.offset then return true, nil, false, true end
  if synced.mode == 'v2' then
    -- A v2 log rewritten in place (another log_id, or the offset mid-line)
    if log.read_id(synced.path) ~= synced.log_id or not log.at_line_start(synced.path, synced.offset) then
      return true, nil, false, true
    end
  end
  local next_path = synced.mode == 'v3' and segment.path(loc.events, synced.seg + 1)
  local has_next = next_path and uv.fs_stat(next_path) ~= nil
  if st.size == synced.offset and not has_next then return true, nil, false, false end
  local changed = false
  local function read(path, seg, from, lines, id)
    local res, err = log.read(path, from, lines, seen_lines(path, id))
    if not res then return nil, err end
    apply(reduced, synced.imports, seg, res.events, path)
    synced.since.events = synced.since.events + #res.events
    synced.since.bytes = synced.since.bytes + res.offset - from
    changed = changed or #res.events > 0
    return res
  end
  local id = synced.mode == 'v3' and synced.journal_id or synced.log_id
  if st.size > synced.offset or has_next then
    local res, err = read(synced.path, synced.seg, synced.offset, synced.lines, id)
    if not res then return false, err, changed, false end
    synced.offset, synced.lines = res.offset, res.lines
  end
  while has_next do
    local h = log.read_header(next_path)
    -- Created complete (see segment.create): no header is another journal's
    if not h or h.journal_id ~= synced.journal_id then return true, nil, changed, true end
    local nst = uv.fs_stat(next_path)
    local n = synced.seg + 1
    local after = segment.path(loc.events, n + 1)
    has_next = uv.fs_stat(after) ~= nil
    local res, err = read(next_path, n, 0, 0, id)
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

-- Write the tombstone log.jsonl (log.tombstone, `log_id` = the journal's
-- id) beside the v3 journal at `loc`, so a pre-v3 Neovim refuses the
-- review instead of starting a v2 log beside it. Created exclusively (see
-- segment.create_file): an existing log.jsonl, e.g. an old Neovim's v2
-- log, is never replaced. Call with the lock held, once segment 1 exists.
-- Returns: as segment.create_file
function M.write_tombstone(loc, journal_id, mode)
  return segment.create_file(loc.log, vim.json.encode(log.tombstone(journal_id)) .. '\n', mode)
end

-- Start the v3 journal at `loc`: segment 1, holding a new header and
-- `events` (an import, when migrating comments.json), created complete;
-- then the tombstone log.jsonl (after: a crash between them leaves a
-- journal with no tombstone, which the next open writes, never a tombstone
-- with no journal). A failed tombstone only warns: segment 1 is the review.
-- Call with the lock held; the next sync loads it.
-- Returns: 'created', 'exists', or nil and an error
function M.create(loc, events, mode)
  local jid = log.new_journal_id()
  local all = { log.segment_header(jid, 1) }
  vim.list_extend(all, events or {})
  local res, err = segment.create(loc.events, 1, all, mode)
  if res == 'created' then
    local tres, terr = M.write_tombstone(loc, jid, mode)
    if not tres then
      notify.once('tombstone:' .. loc.log, 'could not write the tombstone ' .. loc.log .. ': ' .. tostring(terr)
        .. '; a Neovim running an older version could write to the review', vim.log.levels.WARN)
    end
  end
  return res, err
end

-- Append `events` to the active segment (to log.jsonl in 'v2'). Call with
-- the lock held, right after a sync: the active segment is then the
-- highest-numbered one. Memory changes only by reading it back (a sync).
-- Returns: as log.append
function M.append(loc, events)
  if synced.key ~= loc.events or (synced.mode ~= 'v3' and synced.mode ~= 'v2') then
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

-- The newest `refs` of a checkpoint at the current position: the hashes the
-- active segment names up to it, or nil (left out) if it can't be read
local function current_refs()
  local data = location.read_bytes(synced.path)
  if not data then return nil end
  return segment.refs_of(data, synced.offset)
end

-- Write a checkpoint at the current position, the state encoded before the
-- lock is taken (unless the caller holds it). The tail counts restart.
-- Returns: ok, err
function M.write_checkpoint(loc)
  if synced.mode ~= 'v3' or synced.key ~= loc.events then return true, nil end
  local seg, offset = synced.seg, synced.offset
  local encoded, err = checkpoint.encode(synced.journal_id, seg, offset, synced.lines, reduced, synced.imports,
    current_refs())
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
  local ok, err = segment.write_refs(loc.events, n, mode)
  if not ok then return warn(err) end
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
    journal_id = synced.journal_id, migrated = synced.migrated }
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

-- Whether an import with this source_sha256 is in the journal
function M.has_import(sha) return synced.imports[sha] == true end

return M
