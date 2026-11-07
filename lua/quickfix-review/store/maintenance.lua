-- Keeping the review's storage bounded: snapshot garbage collection.
-- Checkpoint GC is in store/checkpoint.lua.
local M = {}

local checkpoint = require('quickfix-review.store.checkpoint')
local journal = require('quickfix-review.store.journal')
local location = require('quickfix-review.store.location')
local log = require('quickfix-review.log')
local segment = require('quickfix-review.store.segment')

local uv = vim.uv or vim.loop

-- Snapshot garbage collection (docs/journal.md#snapshots). Every event is
-- kept forever, so every snapshot an event names is kept forever: GC only
-- removes orphans, snapshots written whose event never landed. Each
-- snapshots dir belongs to one journal, in every storage mode.
--
-- The live set is the union of:
-- - each sealed segment's `.refs` sidecar, {"sha": <sha256 of the
--   segment>, "refs": [...]}. A missing (or unreadable) one is never taken
--   as "no refs": it is rebuilt from its segment under the lock first. So
--   is one whose sha is not the segment's current hash (the segment was
--   replaced, say by a git checkout of an in-repo journal) or in the old
--   bare-list format;
-- - the active segment's: the newest valid checkpoint's `refs` plus the
--   hashes in the tail after it, when that checkpoint is in the active
--   segment; else the hashes of the whole active segment.
-- Hashes are every 64-hex run in the bytes (segment.refs_of), not decoded
-- events, as the seal-time `.refs` are: a torn record stays an undecodable
-- line forever, and an event shape this version doesn't know may still
-- name snapshots, so neither may let its snapshots go. A file that can't be
-- read, or whose header isn't one this version reads, stops the GC; so does
-- finding no segments (events/ missing, or its listing failed). A
-- checkpoint with empty `refs` past the header line is not trusted (its
-- writer may have failed to read the segment): the whole segment is scanned.
--
-- Snapshots are written (snapshots.put) before the event naming them is
-- appended, outside the lock, so an unreferenced snapshot may be another
-- Neovim's about to be referenced: only those untouched for GC_GRACE are
-- deleted (put touches an existing one).
--
-- GC runs at most once per GC_EVERY per review: loc.gc_stamp's
-- (<snapshots>/gc.stamp, or local/gc.stamp in the repo) mtime is when it
-- last completed. The sealed segments' `.refs` are read,
-- and the segments hashed, before taking the lock (only the active segment
-- is ever written); under the lock the segments are listed again, missing
-- or stale `.refs` rebuilt and the active segment and checkpoints read. The
-- hashes taken outside the lock are reused under it (segment.content_hash:
-- only while a segment's size is unchanged), so no sealed segment is read
-- under the lock unless its `.refs` must be rebuilt.
local GC_GRACE = 24 * 3600
local GC_EVERY = 24 * 3600
local SHA_RUN = segment.SHA_RUN

-- Temp files (<name>.tmp.<pid>) a crashed writer left behind: those of
-- storage.atomic_write in snapshots/, of segment.durable_write in events/,
-- and the segment.create temps beside events/ (checkpoints/
-- is checkpoint.gc's); in the repo, every temp file and adopt's staging
-- dirs (events.adopt-<pid>, events.replaced-<pid>) in local/tmp. Swept with the GC
-- (outside the lock: a dead pid has no writer), when the writer's pid is
-- dead and the file is older than TMP_MAX_AGE; a live (or reused) pid's
-- file is kept, as another Neovim may be mid-write. In the review's own dir,
-- which may be a user's directory (storage_file, storage_dir), only the
-- exact names this plugin writes there are matched.
local TMP_MAX_AGE = 3600

local function sweep_tmp(loc)
  local now = os.time()
  -- `dirs`: pid_of may also match staging dirs, removed whole
  local function sweep(dir, pid_of, dirs)
    local handle = uv.fs_scandir(dir)
    while handle do
      local name = uv.fs_scandir_next(handle)
      if not name then break end
      local pid = tonumber(pid_of(name))
      if pid then
        local path = dir .. '/' .. name
        local st = dirs and uv.fs_lstat(path) or uv.fs_stat(path)
        if st and (st.type == 'file' or (dirs and st.type == 'directory'))
            and now - st.mtime.sec > TMP_MAX_AGE and not log.pid_alive(pid) then
          if st.type == 'directory' then vim.fn.delete(path, 'rf') else os.remove(path) end
        end
      end
    end
  end
  local function any(name) return name:match('^.+%.tmp%.(%d+)$') end
  sweep(loc.snapshots, any)
  sweep(loc.events, any)
  local events_name = vim.fn.fnamemodify(loc.events, ':t')
  sweep(vim.fn.fnamemodify(loc.events, ':h'), function(name)
    local base, pid = name:match('^(.+)%.tmp%.(%d+)$')
    return base == events_name and pid or nil
  end)
  if loc.tmp then
    sweep(loc.tmp, function(name)
      return name:match('^.+%.tmp%.(%d+)$') or name:match('^events%.adopt%-(%d+)$')
        or name:match('^events%.replaced%-(%d+)$')
    end, true)
  end
end

local function is_sha(s) return type(s) == 'string' and #s == 64 and s:match('^%x+$') ~= nil end

-- The hashes in the `.refs` of sealed segment `n` into `refs`, once its
-- sha is checked against the segment's bytes (hashed into `hashes`, see
-- segment.content_hash)
-- Returns: true, or false if it is missing (or unreadable, or in the old
-- list format, or not of the segment's current bytes) and must be rebuilt
local function read_refs(events, refs_dir, n, refs, hashes)
  local h = segment.content_hash(events, n, hashes)
  if not h then return false end
  local raw = location.read_bytes(segment.refs_path(refs_dir, n))
  if not raw then return false end
  local ok, doc = pcall(vim.json.decode, raw)
  if not ok or type(doc) ~= 'table' or type(doc.sha) ~= 'string' or doc.sha:lower() ~= h.sha then return false end
  local list = doc.refs
  if type(list) ~= 'table' or not (vim.islist or vim.tbl_islist)(list) then return false end
  for _, sha in ipairs(list) do
    if is_sha(sha) then refs[sha:lower()] = true end
  end
  return true
end

-- The first line of `data` decoded, or nil
local function header_of(data)
  local line = data:match('^([^\n]*)\n')
  local ok, ev = pcall(vim.json.decode, line or '', { luanil = { object = true, array = true } })
  return ok and type(ev) == 'table' and ev or nil
end

-- Delete the review's unreferenced snapshots older than GC_GRACE, unless
-- GC completed within GC_EVERY (`opts.force` skips that check)
-- Returns: how many were deleted
function M.gc(loc, opts)
  opts = opts or {}
  if journal.readonly_error(loc) then return 0 end
  local dir_stat = uv.fs_stat(loc.snapshots)
  if not dir_stat or dir_stat.type ~= 'directory' then return 0 end
  local stamp = loc.gc_stamp
  local function abort(msg)
    vim.notify('quickfix-review: not collecting snapshots: ' .. msg, vim.log.levels.DEBUG)
    return 0
  end
  local function due()
    if opts.force then return true end
    local st = uv.fs_stat(stamp)
    return not st or os.time() - st.mtime.sec >= GC_EVERY
  end
  if not due() then return 0 end
  sweep_tmp(loc)

  local refs = {}
  -- The sealed segments whose .refs were read, outside the lock
  local done = {}
  -- The sealed segments' { size, sha }, hashed once in this GC
  local hashes = {}
  local first = segment.list(loc.events)
  if #first == 0 then return 0 end
  for i = 1, #first - 1 do
    if read_refs(loc.events, loc.refs, first[i], refs, hashes) then done[first[i]] = true end
  end

  -- Rebuild the missing or stale .refs of sealed segment `n` from its bytes
  -- Returns: an error message, or nil once its hashes are in refs
  local function rebuild(n)
    local path = segment.path(loc.events, n)
    local data, st = segment.read_fd(path)
    if not data then return 'could not read ' .. path end
    if not log.readable_header(data) then return path .. ' has no header this version reads' end
    for _, sha in ipairs(segment.refs_of(data)) do refs[sha] = true end
    local encoded, hash = segment.encode_refs(data)
    if not encoded then return hash .. ' ' .. path end
    hashes[n] = hash
    location.mkdir_for(segment.refs_path(loc.refs, n))
    local ok, err = segment.durable_write(segment.refs_path(loc.refs, n), encoded, bit.band(st.mode, 511))
    if not ok then
      vim.notify('quickfix-review: could not write ' .. segment.refs_path(loc.refs, n) .. ': ' .. tostring(err),
        vim.log.levels.DEBUG)
    end
  end

  -- The active segment `n`: from the newest valid checkpoint in it, if any
  local function active(n)
    local path = segment.path(loc.events, n)
    local data = location.read_bytes(path)
    if not data then return 'could not read ' .. path end
    if not log.readable_header(data) then return path .. ' has no header this version reads' end
    local h = header_of(data)
    local cp
    if h and h.journal_id then
      local j = { events = loc.events, journal_id = h.journal_id }
      -- Only the active segment's checkpoints: loading one elsewhere would
      -- open a sealed segment, whose .refs already cover it
      for _, c in ipairs((checkpoint.list(loc.checkpoints))) do
        if c.seg ~= n then break end
        cp = checkpoint.load(c.path, j, hashes)
        if cp then break end
      end
    end
    -- Empty refs past the header may be a writer's failed read: scan all
    local hdr_end = data:find('\n', 1, true)
    if cp and cp.refs and cp.offset <= #data and (#cp.refs > 0 or (hdr_end and cp.offset <= hdr_end)) then
      for _, sha in ipairs(cp.refs) do refs[sha] = true end
      for sha in data:sub(cp.offset + 1):gmatch(SHA_RUN) do refs[sha:lower()] = true end
    else
      for _, sha in ipairs(segment.refs_of(data)) do refs[sha] = true end
    end
  end

  local got, removed = journal.locked(loc, function()
    if not due() then return 0 end
    local segs = segment.list(loc.events)
    -- A listing failure also reads as no segments: never collect then
    if #segs == 0 then return abort('no events found in ' .. loc.events) end
    for i = 1, #segs - 1 do
      local n = segs[i]
      if not done[n] and not read_refs(loc.events, loc.refs, n, refs, hashes) then
        local err = rebuild(n)
        if err then return abort(err) end
      end
    end
    local err = active(segs[#segs])
    if err then return abort(err) end

    local count = 0
    local handle = uv.fs_scandir(loc.snapshots)
    while handle do
      local name, kind = uv.fs_scandir_next(handle)
      if not name then break end
      if (kind == 'file' or kind == nil) and #name == 64 and name:match('^[0-9a-f]+$') and not refs[name] then
        -- Stat'ed right before the unlink, narrowing the window for a
        -- concurrent put's touch
        local path = loc.snapshots .. '/' .. name
        local st = uv.fs_stat(path)
        if st and st.type == 'file' and os.time() - st.mtime.sec > GC_GRACE and os.remove(path) then
          count = count + 1
        end
      end
    end
    -- Completed: the next run is a day away
    local now = os.time()
    location.mkdir_for(stamp)
    if not uv.fs_utime(stamp, now, now) then
      local fh = io.open(stamp, 'wb')
      if fh then fh:close() end
    end
    return count
  end)
  if not got then return abort(tostring(removed)) end
  return removed or 0
end

-- Delete the review's unreferenced snapshots older than a day, at most once
-- a day unless `opts.force` (see gc).
-- Returns: how many were deleted
function M.gc_snapshots(opts)
  return M.gc(location.resolve(), opts)
end

-- Collect the snapshots of the review once this session, 5s after startup,
-- if it was not collected within a day (not in the test suite, which sets
-- vim.g._quickfix_review_no_startup_gc)
function M.schedule_startup_gc()
  if vim.g._quickfix_review_startup_gc or vim.g._quickfix_review_no_startup_gc then return end
  vim.g._quickfix_review_startup_gc = true
  vim.defer_fn(function()
    local ok, err = pcall(M.gc_snapshots)
    if not ok then vim.notify('quickfix-review: snapshot GC failed: ' .. tostring(err), vim.log.levels.DEBUG) end
  end, 5000)
end

return M
