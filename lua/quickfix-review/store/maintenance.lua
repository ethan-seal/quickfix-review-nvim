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
-- - each sealed segment's `.refs` sidecar. A missing (or unreadable) one is
--   never taken as "no refs": it is rebuilt from its segment under the lock
--   first;
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
-- GC runs at most once per GC_EVERY per review: <snapshots>/gc.stamp's
-- mtime is when it last completed. The sealed segments' `.refs` are read
-- before taking the lock (only the active segment is ever written); under
-- the lock the segments are listed again, missing `.refs` rebuilt and the
-- active segment and checkpoints read.
local GC_GRACE = 24 * 3600
local GC_EVERY = 24 * 3600
local SHA_RUN = segment.SHA_RUN

-- Temp files (<name>.tmp.<pid>) a crashed writer left behind: those of
-- storage.atomic_write in snapshots/, of segment.durable_write in events/,
-- and the segment.create temps beside events/ (checkpoints/
-- is checkpoint.gc's). Swept with the GC
-- (outside the lock: a dead pid has no writer), when the writer's pid is
-- dead and the file is older than TMP_MAX_AGE; a live (or reused) pid's
-- file is kept, as another Neovim may be mid-write. In the review's own dir,
-- which may be a user's directory (storage_file, storage_dir), only the
-- exact names this plugin writes there are matched.
local TMP_MAX_AGE = 3600

local function sweep_tmp(loc)
  local now = os.time()
  local function sweep(dir, pid_of)
    local handle = uv.fs_scandir(dir)
    while handle do
      local name = uv.fs_scandir_next(handle)
      if not name then break end
      local pid = tonumber(pid_of(name))
      if pid then
        local path = dir .. '/' .. name
        local st = uv.fs_stat(path)
        if st and st.type == 'file' and now - st.mtime.sec > TMP_MAX_AGE and not log.pid_alive(pid) then
          os.remove(path)
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
end

local function is_sha(s) return type(s) == 'string' and #s == 64 and s:match('^%x+$') ~= nil end

-- The hashes in the `.refs` of sealed segment `n` into `refs`
-- Returns: true, or false if it is missing or not a list of hashes
local function read_refs(dir, n, refs)
  local raw = location.read_bytes(segment.refs_path(dir, n))
  if not raw then return false end
  local ok, list = pcall(vim.json.decode, raw)
  if not ok or not (vim.islist or vim.tbl_islist)(list) then return false end
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
  local stamp = loc.snapshots .. '/gc.stamp'
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
  local first = segment.list(loc.events)
  if #first == 0 then return 0 end
  for i = 1, #first - 1 do
    if read_refs(loc.events, first[i], refs) then done[first[i]] = true end
  end

  -- Rebuild the missing .refs of sealed segment `n` from its bytes
  -- Returns: an error message, or nil once its hashes are in refs
  local function rebuild(n)
    local path = segment.path(loc.events, n)
    local data = location.read_bytes(path)
    if not data then return 'could not read ' .. path end
    if not log.readable_header(data) then return path .. ' has no header this version reads' end
    local list = segment.refs_of(data)
    for _, sha in ipairs(list) do refs[sha] = true end
    local st = uv.fs_stat(path)
    local ok, err = segment.durable_write(segment.refs_path(loc.events, n), vim.json.encode(list) .. '\n',
      st and bit.band(st.mode, 511) or 420)
    if not ok then
      vim.notify('quickfix-review: could not write ' .. segment.refs_path(loc.events, n) .. ': ' .. tostring(err),
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
        cp = checkpoint.load(c.path, j)
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
      if not done[n] and not read_refs(loc.events, n, refs) then
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
