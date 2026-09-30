-- The storage lock of a review: flock(2) on its lock file (loc.flock), which
-- the kernel releases when the holder exits, however it exits, and inside it
-- the mkdir lock (loc.lock), so a process that took only the mkdir lock (an
-- older version, or one whose flock failed) is excluded too. Where LuaJIT's
-- FFI is missing, or on Windows, the mkdir lock alone is used; so it is, with
-- a warning, for a lock file whose flock fails with anything but contention
-- (a filesystem that refuses flock): for the session, except for ENOLCK,
-- which falls back for that call only. See docs/journal.md#locking.
local uv = vim.uv or vim.loop

local M = {}

local log = require('quickfix-review.log')

local WAIT_MS = 1000

-- The lock paths this process holds, each to its fd (true for the mkdir
-- lock): a nested with_lock on a held path runs under the outer lock
local held = {}

-- Whether this process holds the lock at `path`
function M.held(path) return held[path] ~= nil end

local function timed_out(path) return false, 'Timed out waiting for the lock ' .. path end

local has_ffi, ffi = pcall(require, 'ffi')
if has_ffi then
  -- Raises if already declared (by another plugin, or a reload of this one)
  pcall(ffi.cdef, 'int flock(int fd, int op);')
  pcall(ffi.cdef, 'char *strerror(int errnum);')
end

local LOCK_EX_NB, LOCK_UN = 6, 8 -- LOCK_EX | LOCK_NB, LOCK_UN
-- The errnos of a flock that is only contended: EWOULDBLOCK (EAGAIN on
-- Linux, 11; 35 on macOS and the BSDs), and EINTR
local EAGAIN = (has_ffi and ffi.os == 'Linux') and 11 or 35
local EINTR = 4
-- ENOLCK (no lock available: 37 on Linux, 77 on macOS and the BSDs) is
-- transient, so it is never memoised in flock_unsupported
local ENOLCK = (has_ffi and ffi.os == 'Linux') and 37 or 77

-- The text of errno `e`, or "errno <e>" where strerror can't be called
local function errno_text(e)
  local ok, text = pcall(function() return ffi.string(ffi.C.strerror(e)) end)
  if ok and type(text) == 'string' and text ~= '' then return text .. ' (errno ' .. tostring(e) .. ')' end
  return 'errno ' .. tostring(e)
end

-- The flock paths whose flock failed with anything but contention or
-- ENOLCK: their review takes the mkdir lock alone, for the rest of the
-- session. ENOLCK falls back for that call only; flock is tried again on the
-- next.
local flock_unsupported = {}

-- Run fn with `path` flock'ed. The file is opened for appending (never
-- truncated nor written: its content is irrelevant) and kept open for as
-- long as the lock is held; closing it releases the lock. Only contention
-- is retried: any other failure returns nil, 'unsupported' and its errno.
local function with_flock(path, fn)
  local fd, err = uv.fs_open(path, 'a', 420) -- 0644
  if not fd then return false, 'Could not lock ' .. path .. ': ' .. tostring(err) end
  local deadline = uv.hrtime() + WAIT_MS * 1e6
  while ffi.C.flock(fd, LOCK_EX_NB) ~= 0 do
    -- Read before any other call can overwrite it
    local e = ffi.errno()
    if e ~= EAGAIN and e ~= EINTR then
      uv.fs_close(fd)
      return nil, 'unsupported', e
    end
    if uv.hrtime() > deadline then
      uv.fs_close(fd)
      return timed_out(path)
    end
    uv.sleep(10)
  end
  held[path] = fd
  local results = { pcall(fn) }
  -- No longer counted as held before the fd is closed
  held[path] = nil
  pcall(ffi.C.flock, fd, LOCK_UN)
  uv.fs_close(fd)
  if not results[1] then error(results[2], 0) end
  return true, unpack(results, 2, table.maxn(results))
end

-- The mkdir lock: the fallback where flock isn't available

local STALE_SECONDS = 10

local function hex(bytes)
  return (bytes:gsub('.', function(c) return string.format('%02x', c:byte()) end))
end

-- The pid in the lock `lockdir`, or nil
local function read_pid(lockdir)
  local fh = io.open(lockdir .. '/pid', 'r')
  if not fh then return nil end
  local pid = tonumber(fh:read('*l') or '')
  fh:close()
  return pid
end

-- A lock left by a process that is gone. A lock naming a live process is
-- never stale, however old: its holder may be slow or paused, and breaking
-- it would let two writers in. Age is only used for a lock with no pid,
-- whose holder crashed between its mkdir and writing the pid (a fresh one
-- is a holder about to write it). A lock naming this process is stale: a
-- nested call on a held lock never reaches take (held[]), so it is left by a
-- crash or an earlier process with a reused pid.
-- Returns: stale (boolean), and the pid it was judged by (nil when there
-- was none, and it was judged by age)
local function stale(lockdir)
  local stat = uv.fs_stat(lockdir)
  if not stat then return false end
  local pid = read_pid(lockdir)
  if not pid then return os.time() - stat.mtime.sec > STALE_SECONDS, nil end
  if pid == uv.os_getpid() then return true, pid end
  return not log.pid_alive(pid), pid
end

local function unlock(lockdir)
  os.remove(lockdir .. '/pid')
  uv.fs_rmdir(lockdir)
end

-- Release a lock this process took: only while it still names this process.
-- One broken as stale meanwhile (see break_lock) may be another holder's
-- now, which is left alone. The check and the removal are not atomic, which
-- narrows, but does not close, that window.
local function release(lockdir)
  if read_pid(lockdir) == uv.os_getpid() then unlock(lockdir) end
end

-- Break a stale lock: rename it aside, then remove it. Of two processes
-- that both judged it stale, only one rename succeeds, so the other never
-- removes a lock taken since. `judged` is the pid stale() judged it by: the
-- lock is left alone if its pid has changed since (it was broken and taken
-- again meanwhile), which narrows, but does not close, the window in which
-- a fresh lock could be broken; take() recovers from that ('lost').
local function break_lock(lockdir, judged)
  if read_pid(lockdir) ~= judged then return end
  local aside = string.format('%s.stale-%d-%s', lockdir, uv.os_getpid(), hex(assert(uv.random(4))))
  if uv.fs_rename(lockdir, aside) then unlock(aside) end
end

-- Take `lockdir`: mkdir it and write this process's pid inside, then read
-- the pid back, in case a breaker moved the dir away meanwhile.
-- Returns: 'ok', 'busy' (it exists), 'lost' (someone else's now), or nil
-- and an error
local function take(lockdir)
  local ok, err, name = uv.fs_mkdir(lockdir, 448) -- 0700
  if not ok then
    if name == 'EEXIST' then return 'busy' end
    return nil, 'Could not lock ' .. lockdir .. ': ' .. tostring(err)
  end
  local me = uv.os_getpid()
  local fh = io.open(lockdir .. '/pid', 'w')
  local wrote = fh and fh:write(tostring(me), '\n')
  if fh then fh:close() end
  if not wrote then
    -- Moved away by a breaker before the pid was written: try again
    if not uv.fs_stat(lockdir) then return 'lost' end
    -- rmdir only removes an empty dir, but in a race of three that may be
    -- another taker's fresh lockdir (moved in after a breaker moved ours
    -- away): that taker then reads no pid of its own, sees 'lost' and retries
    uv.fs_rmdir(lockdir)
    return nil, 'Could not lock ' .. lockdir .. ': could not write its pid'
  end
  return read_pid(lockdir) == me and 'ok' or 'lost'
end

-- Run fn with `lockdir` held: mkdir'ed, with this process's pid inside. A
-- stale lock (see stale) is broken; one whose holder is alive, however old,
-- is waited on for up to a second.
local function with_mkdir(lockdir, fn)
  local deadline = uv.hrtime() + WAIT_MS * 1e6
  while true do
    local got, err = take(lockdir)
    if got == 'ok' then break end
    if not got then return false, err end
    local is_stale, judged = false, nil
    if got == 'busy' then is_stale, judged = stale(lockdir) end
    if is_stale then
      break_lock(lockdir, judged)
      -- A lock that can't be broken (its rename keeps failing) is not
      -- retried forever
      if uv.hrtime() > deadline then return timed_out(lockdir) end
    elseif uv.hrtime() > deadline then
      return timed_out(lockdir)
    else
      uv.sleep(5)
    end
  end
  held[lockdir] = true
  local results = { pcall(fn) }
  held[lockdir] = nil
  release(lockdir)
  if not results[1] then error(results[2], 0) end
  return true, unpack(results, 2, table.maxn(results))
end

-- 'flock', or 'mkdir' where flock can't be called
M.backend = (has_ffi and vim.fn.has('win32') == 0) and 'flock' or 'mkdir'

-- Run fn with the lock of the review at `loc` (a store/location) held: the
-- flock, and inside it the mkdir lock (loc.lock), so a process holding only
-- the mkdir lock (an older version, or one whose flock failed) and one on the
-- flock exclude each other. A lock another process holds is waited on for up
-- to a second each. Nested calls on the same review run under the outer
-- lock; another review's lock is taken as usual. Where flock fails with
-- anything but contention, the mkdir lock alone is taken instead, with one
-- warning: from then on, except after ENOLCK, where flock is tried again on
-- the next call.
-- Returns: true and fn's results, or false and an error (fn not run)
function M.with_lock(loc, fn)
  -- Either lock held means this process holds the review: after a fallback
  -- (ENOLCK) the flock would be tried again, and the mkdir lock under it
  -- would judge its own pid stale and break the outer lock
  if held[loc.lock] or held[loc.flock] then return true, fn() end
  if M.backend ~= 'flock' or flock_unsupported[loc.flock] then return with_mkdir(loc.lock, fn) end
  local r = vim.F.pack_len(with_flock(loc.flock, function() return vim.F.pack_len(with_mkdir(loc.lock, fn)) end))
  if r[1] == true then return unpack(r[2], 1, r[2].n) end
  if r[1] == nil and r[2] == 'unsupported' then
    if r[3] ~= ENOLCK then flock_unsupported[loc.flock] = true end
    require('quickfix-review.notify').once(
      'lock-flock:' .. loc.flock,
      'flock on ' .. loc.flock .. ' failed (' .. errno_text(r[3]) .. '); using the mkdir lock ' .. tostring(loc.lock) .. ' instead',
      vim.log.levels.WARN
    )
    return with_mkdir(loc.lock, fn)
  end
  return unpack(r, 1, r.n)
end

-- Run fn with both locks of the review at `loc` held: the flock, and inside
-- it the mkdir lock (loc.lock) that Neovims running the v2 code take, so a
-- v2 -> v3 migration (and every write to a review still in v2) excludes
-- them too (docs/journal.md#migration). with_lock itself now takes both, so
-- this is the explicit call for those writes, going through M.with_lock.
-- Where the mkdir lock is the backend, it is the one lock, taken once.
-- Returns: as with_lock
function M.with_both(loc, fn)
  if M.backend ~= 'flock' or held[loc.lock] then return M.with_lock(loc, fn) end
  local inner
  local ok, err = M.with_lock(loc, function()
    if held[loc.lock] then
      inner = vim.F.pack_len(true, fn())
    else
      inner = vim.F.pack_len(with_mkdir(loc.lock, fn))
    end
  end)
  if not ok then return false, err end
  return unpack(inner, 1, inner.n)
end

return M
