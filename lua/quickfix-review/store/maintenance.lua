-- Keeping the review's storage bounded: log rotation, retention of rotated
-- logs, and snapshot garbage collection.
local M = {}

local config = require('quickfix-review.config')
local journal = require('quickfix-review.store.journal')
local location = require('quickfix-review.store.location')
local log = require('quickfix-review.log')
local reduce = require('quickfix-review.reduce')

local uv = vim.uv or vim.loop

-- Log rotation. A log grown past the log_max_bytes option is rotated by the
-- change that grew it, under the lock: the log on disk (not this instance's
-- memory) is replayed, a new log (a header and one checkpoint event holding
-- that state, see reduce.lua) is written beside it, the old log is
-- hard-linked (or copied) to log.<unix ms>.jsonl, and the new one renamed
-- over log.jsonl. So log.jsonl is never missing, nor only a header, for a
-- reader, which never takes the lock. Rotated logs are kept for
-- :ReviewHistory, and deleted after log_retention_days if that is set: the
-- checkpoint holds the trash, so nothing is lost with them.
local DAY_MS = 24 * 60 * 60 * 1000

local function now_ms()
  local sec, usec = uv.gettimeofday()
  return sec * 1000 + math.floor(usec / 1000)
end

-- A positive number option, or `default`
local function positive(v, default)
  if type(v) == 'number' and v > 0 then return v end
  return default
end

-- log.jsonl (or <file>.log.jsonl) as rotated at `ms`: log.<ms>.jsonl
local function rotated_name(loc, ms)
  return (loc.log:gsub('%.jsonl$', '')) .. '.' .. string.format('%d', ms) .. '.jsonl'
end

-- The rotated logs of the review at `loc`, oldest first: { path, ms }...
-- Only this review's: anchored on the log's own name, as several reviews
-- (storage_file) may share a directory
local function list_rotated(loc)
  local dir = vim.fn.fnamemodify(loc.log, ':h')
  local base = vim.fn.fnamemodify(loc.log, ':t'):gsub('%.jsonl$', '')
  local pattern = '^' .. vim.pesc(base) .. '%.(%d+)%.jsonl$'
  local out = {}
  local handle = uv.fs_scandir(dir)
  while handle do
    local name = uv.fs_scandir_next(handle)
    if not name then break end
    local ms = name:match(pattern)
    if ms then table.insert(out, { path = dir .. '/' .. name, ms = tonumber(ms) }) end
  end
  table.sort(out, function(a, b) return a.ms < b.ms end)
  return out
end

-- The rotated logs of the review, oldest first
function M.rotated_logs()
  local out = {}
  for i, r in ipairs(list_rotated(location.resolve())) do out[i] = r.path end
  return out
end

-- The size of the header and checkpoint a rotated-to log starts with, by
-- log path: { ino (of that log), bytes }. A log is rotated again only once
-- it is larger than twice that, so a checkpoint that alone exceeds
-- log_max_bytes does not rotate on every change.
local head = {}

-- The size above which the log (stat'ed as `stat`) at `loc` is rotated
function M.rotate_limit(loc, stat)
  local limit = positive(config.options.log_max_bytes, config.defaults.log_max_bytes)
  local h = head[loc.log]
  if h and h.ino == stat.ino then limit = math.max(limit, 2 * h.bytes) end
  return limit
end

-- A .rotating-<pid> temp file older than this is removed even if its pid is
-- alive (a reused pid)
local STRAY_SECONDS = 10 * 60

-- Remove the .rotating-<pid> (and .rotating-<pid>-old copy) temp files of
-- rotations that crashed (their process is gone, or they are old). Call with
-- the lock held.
local function remove_strays(loc)
  local dir = vim.fn.fnamemodify(loc.log, ':h')
  local pattern = '^' .. vim.pesc(vim.fn.fnamemodify(loc.log, ':t')) .. '%.rotating%-(%d+)$'
  local copy_pattern = '^' .. vim.pesc(vim.fn.fnamemodify(loc.log, ':t')) .. '%.rotating%-(%d+)%-old$'
  local me = uv.os_getpid()
  local handle = uv.fs_scandir(dir)
  while handle do
    local name = uv.fs_scandir_next(handle)
    if not name then break end
    local pid = tonumber(name:match(pattern) or name:match(copy_pattern) or '')
    if pid and pid ~= me then
      local path = dir .. '/' .. name
      local st = uv.fs_stat(path)
      if st and (not log.pid_alive(pid) or os.time() - st.mtime.sec > STRAY_SECONDS) then os.remove(path) end
    end
  end
end

-- Rotate the log at `loc` (see above). Call with the lock held. A failure
-- leaves the log as it was and is only warned about: the change that
-- triggered it is already in the log.
-- Returns: true if the log was rotated
function M.rotate(loc)
  local function warn(e)
    vim.notify('quickfix-review: could not rotate ' .. loc.log .. ': ' .. tostring(e), vim.log.levels.WARN)
    return false
  end
  local old = uv.fs_stat(loc.log)
  if not old then return false end
  local res, err = log.read(loc.log, 0, 0, journal.seen_lines(loc))
  if not res then return warn(err) end
  -- Not known yet (another Neovim rotated, or a restart): how large the
  -- log's leading checkpoint is, so it isn't rotated again too soon
  if res.events[1] and res.events[1].op == 'checkpoint' and not (head[loc.log] and head[loc.log].ino == old.ino) then
    local ok, cp = pcall(vim.json.encode, res.events[1])
    local bytes = (ok and #cp or 0) + #vim.json.encode(log.new_header()) + 2
    head[loc.log] = { ino = old.ino, bytes = bytes }
    if old.size <= 2 * bytes then return false end
  end
  local state, imports = reduce.new(), {}
  for _, ev in ipairs(res.events) do
    if ev.op == 'import' and type(ev.source_sha256) == 'string' then imports[ev.source_sha256] = true end
    if ev.op == 'checkpoint' and type(ev.imports) == 'table' then
      for _, sha in ipairs(ev.imports) do
        if type(sha) == 'string' then imports[sha] = true end
      end
    end
    reduce.apply(state, ev)
  end
  local checkpoint = log.event('checkpoint', { state = state, imports = vim.tbl_keys(imports) })

  local mode = bit.band(old.mode, 511)
  local tmp = loc.log .. '.rotating-' .. uv.os_getpid()
  remove_strays(loc)
  os.remove(tmp)
  local wrote, werr = log.append(tmp, { log.new_header(), checkpoint }, mode)
  if not wrote then
    os.remove(tmp)
    return warn(werr)
  end
  uv.fs_chmod(tmp, mode)

  -- Never over an existing rotated log (two rotations in one millisecond)
  local ms = now_ms()
  while uv.fs_stat(rotated_name(loc, ms)) do ms = ms + 1 end
  local rotated = rotated_name(loc, ms)
  -- Hard-linked into place, or (no hard links) copied to a temp name and
  -- renamed into place: never filled in under its final name, where a GC
  -- reading rotated logs outside the lock could see it half-copied
  local kept, kerr = uv.fs_link(loc.log, rotated)
  if not kept then
    local copy = tmp .. '-old'
    os.remove(copy)
    kept, kerr = uv.fs_copyfile(loc.log, copy, { excl = true })
    if kept then kept, kerr = uv.fs_rename(copy, rotated) end
    if not kept then
      os.remove(tmp)
      os.remove(copy)
      return warn(kerr)
    end
  end
  local renamed, rerr = uv.fs_rename(tmp, loc.log)
  if not renamed then
    os.remove(tmp)
    os.remove(rotated)
    return warn(rerr)
  end
  local new = uv.fs_stat(loc.log)
  if new then head[loc.log] = { ino = new.ino, bytes = new.size } end
  return true
end

-- Storage paths whose rotated logs have been checked for retention this session
local retention_done = {}

-- Delete the rotated logs older than log_retention_days (by the time in
-- their name), once per review per session. Nothing else is touched.
function M.apply_retention(loc)
  local days = positive(config.options.log_retention_days, nil)
  if not days or retention_done[loc.log] then return end
  retention_done[loc.log] = true
  local cutoff = now_ms() - days * DAY_MS
  for _, r in ipairs(list_rotated(loc)) do
    if r.ms < cutoff then os.remove(r.path) end
  end
end

-- Snapshot garbage collection. A snapshot is in use while any event of the
-- review's retained logs (the current one and the rotated ones) names it:
-- every comment's and trash entry's anchor comes from those events (the
-- checkpoint a rotated-to log starts with carries both). Each snapshots dir
-- belongs to one log, in every storage mode.
--
-- References are every 64-hex run in the logs' bytes, not decoded events: a
-- torn record stays an undecodable line forever, and an event shape this
-- version doesn't know may still name snapshots, so neither may let its
-- snapshots go. A log that can't be read, or whose header isn't one this
-- version reads, stops the GC.
--
-- Snapshots are written (snapshots.put) before the event naming them is
-- appended, outside the lock, so an unreferenced snapshot may be another
-- Neovim's about to be referenced: only those untouched for GC_GRACE are
-- deleted (put touches an existing one).
--
-- A rotated log only ever appears complete (hard-linked, or copied to a
-- temp name and renamed into place) and is never written again, so the
-- rotated logs are read before taking the lock: holding it through many
-- large reads could make another Neovim's change time out. Under the lock
-- the current log is read, and so is any rotated log that appeared since
-- (a rotation in between); one retention deleted since only keeps its
-- snapshots a while longer.
local GC_GRACE = 24 * 3600
local SHA_RUN = '%f[%x]' .. ('%x'):rep(64) .. '%f[^%x]'

function M.gc(loc)
  if journal.readonly_error(loc) then return 0 end
  local dir_stat = uv.fs_stat(loc.snapshots)
  if not dir_stat or dir_stat.type ~= 'directory' or not uv.fs_stat(loc.log) then return 0 end
  local function abort(msg)
    vim.notify('quickfix-review: not collecting snapshots: ' .. msg, vim.log.levels.DEBUG)
    return 0
  end

  local refs, read = {}, {}
  -- Returns: an error message, or nil once `path`'s references are in refs
  local function collect(path)
    local data = location.read_bytes(path)
    if not data then return 'could not read ' .. path end
    if not log.readable_header(data) then return path .. ' has no header this version reads' end
    for sha in data:gmatch(SHA_RUN) do refs[sha:lower()] = true end
    read[path] = true
  end
  for _, r in ipairs(list_rotated(loc)) do
    local err = collect(r.path)
    if err then return abort(err) end
  end

  local got, removed = journal.locked(loc, function()
    local err = collect(loc.log)
    if err then return abort(err) end
    for _, r in ipairs(list_rotated(loc)) do
      if not read[r.path] then
        err = collect(r.path)
        if err then return abort(err) end
      end
    end

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
    return count
  end)
  if not got then return abort(tostring(removed)) end
  return removed or 0
end

-- Delete the review's unreferenced snapshots older than a day (see gc).
-- Returns: how many were deleted
function M.gc_snapshots()
  return M.gc(location.resolve())
end

-- Collect the snapshots of the review once this session, 5s after startup
-- (not in the test suite, which sets vim.g._quickfix_review_no_startup_gc)
function M.schedule_startup_gc()
  if vim.g._quickfix_review_startup_gc or vim.g._quickfix_review_no_startup_gc then return end
  vim.g._quickfix_review_startup_gc = true
  vim.defer_fn(function()
    local ok, err = pcall(M.gc_snapshots)
    if not ok then vim.notify('quickfix-review: snapshot GC failed: ' .. tostring(err), vim.log.levels.DEBUG) end
  end, 5000)
end

return M
