-- The append-only event log that holds a review: log.jsonl, one JSON object
-- per line, each line ending in \n. The first line is a header,
-- {"op":"header","log_id":"<16 hex>","v":2}; every other line is an event
-- (see reduce.lua for what each op means). Events carry `eid` (a per-process
-- nonce, "-", a counter) and `ts` (unix ms, informational only): the order of
-- events is the order of the lines.
--
-- Nothing in the log is ever rewritten, so no change can lose data. Readers
-- are tolerant: a line that fails to decode is skipped (with a warning), and
-- bytes after the last \n (another process's write in flight) are left for a
-- later read.
local M = {}

local uv = vim.uv or vim.loop

-- The log format. 2: logs may hold a checkpoint event (rotation). A log
-- whose header has a higher v is refused (never shown empty, nor appended to).
M.VERSION = 2

local function hex(bytes)
  return (bytes:gsub('.', function(b) return string.format('%02x', b:byte()) end))
end

-- Per-process, so two Neovims never mint the same eid
local nonce = hex(assert(uv.random(4)))
local counter = 0

local function now_ms()
  local sec, usec = uv.gettimeofday()
  return sec * 1000 + math.floor(usec / 1000)
end

-- A new event: `fields` with op, eid and ts added
function M.event(op, fields)
  counter = counter + 1
  local ev = fields or {}
  ev.op = op
  ev.eid = nonce .. '-' .. counter
  ev.ts = now_ms()
  return ev
end

function M.new_header()
  return { op = 'header', log_id = hex(assert(uv.random(8))), v = M.VERSION }
end

local function is_header(ev)
  return type(ev) == 'table' and ev.op == 'header' and type(ev.log_id) == 'string' and ev.log_id ~= ''
end

-- A header written by a newer version of the plugin, in a format this one
-- may not understand
local function too_new(ev)
  return type(ev.v) == 'number' and ev.v > M.VERSION
end

-- Append `events` to the log at `path` (created with `mode` if missing) in a
-- single write(2), so a record is never split and records of two processes
-- never interleave; then fsync. Not io.open: stdio buffering splits a long
-- line into several writes. If the log does not end in \n (an earlier short
-- write, or a torn record), a \n is written first, so the torn record stays
-- one undecodable line instead of swallowing this one. The fd is not kept.
-- Call with the log's lock held.
-- Returns: ok (boolean), err (string or nil), landed: how many of `events`
-- are in the log as complete lines (#events on success; on a failed write,
-- fsync or close, the ones written whole, which a read will see; nil when
-- nothing was written)
function M.append(path, events, mode)
  local parts = {}
  for i, ev in ipairs(events) do
    local ok, line = pcall(vim.json.encode, ev)
    if not ok then return false, 'could not encode a ' .. tostring(ev.op) .. ' event' end
    parts[i] = line .. '\n'
  end
  local data = table.concat(parts)

  local fd, err = uv.fs_open(path, 'a+', mode or 420)
  if not fd then return false, err end
  local function fail(e, landed)
    uv.fs_close(fd)
    return false, e or 'unknown error', landed
  end

  local stat, serr = uv.fs_fstat(fd)
  if not stat then return fail(serr) end
  local prefix = 0
  if stat.size > 0 then
    local last, rerr = uv.fs_read(fd, 1, stat.size - 1)
    if not last then return fail(rerr) end
    if last ~= '\n' then data, prefix = '\n' .. data, 1 end
  end

  local n, werr = uv.fs_write(fd, data)
  if not n then return fail(werr) end
  if n ~= #data then
    -- The events whose \n was written landed whole
    local _, landed = data:sub(prefix + 1, n):gsub('\n', '')
    return fail(string.format('short write (%d of %d bytes)', n, #data), landed)
  end
  local synced, ferr = uv.fs_fsync(fd)
  if not synced then return fail(ferr, #events) end
  local closed, cerr = uv.fs_close(fd)
  if not closed then return false, cerr, #events end
  return true, nil, #events
end

-- Read the complete lines of the log at `path` from byte `from` (default 0,
-- the start of a line; `lines` is how many lines precede it, for messages).
-- Every line that fails to decode is skipped with a warning naming its line
-- number. Bytes after the last \n are not consumed. Reading from 0, the
-- first line must be a header. `seen`, a table the caller keeps, makes the
-- warning once per line number: lines warned about are recorded in it.
-- Returns: { events, offset, lines, log_id (from 0 only), ino (of the file
-- read) }, or nil and an error when the file can't be read, is shorter than
-- `from`, or has no header
function M.read(path, from, lines, seen)
  from, lines = from or 0, lines or 0
  local fd, err = uv.fs_open(path, 'r', 0)
  if not fd then return nil, 'Could not read ' .. path .. ': ' .. tostring(err) end
  local stat = uv.fs_fstat(fd)
  local size = stat and stat.size or 0
  if size < from then
    uv.fs_close(fd)
    return nil, path .. ' is shorter than what was read of it'
  end
  local data, rerr = '', nil
  if size > from then data, rerr = uv.fs_read(fd, size - from, from) end
  uv.fs_close(fd)
  if not data then return nil, 'Could not read ' .. path .. ': ' .. tostring(rerr) end

  local result = { events = {}, offset = from, lines = lines, ino = stat and stat.ino }
  local pos = 1
  while true do
    local nl = data:find('\n', pos, true)
    if not nl then break end
    local line = data:sub(pos, nl - 1)
    pos = nl + 1
    result.lines = result.lines + 1
    local ok, ev = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
    if not ok or type(ev) ~= 'table' or type(ev.op) ~= 'string' then ev = nil end

    if from == 0 and result.lines == 1 then
      if not is_header(ev) then
        return nil, path .. ' is not a quickfix-review log (its first line is not a header, possibly torn by an'
          .. ' interrupted write); to rebuild it, move it aside (e.g. rename it to ' .. path .. '.bad) and restart'
          .. ' Neovim: comments.json beside it, if any, is migrated again'
      end
      if too_new(ev) then
        return nil, string.format('%s was written by a newer version of quickfix-review (log format v%s, this'
          .. ' version reads up to v%d); upgrade the plugin to read or change it', path, tostring(ev.v), M.VERSION)
      end
      result.log_id = ev.log_id
    elseif ev then
      table.insert(result.events, ev)
    elseif line ~= '' and not (seen and seen[result.lines]) then
      if seen then seen[result.lines] = true end
      vim.notify(string.format('quickfix-review: skipping unreadable line %d of %s', result.lines, path),
        vim.log.levels.WARN)
    end
  end
  result.offset = from + pos - 1
  return result
end

-- The log_id in the header of the log at `path`, or nil
function M.read_id(path)
  local fd = uv.fs_open(path, 'r', 0)
  if not fd then return nil end
  local head = uv.fs_read(fd, 4096, 0)
  uv.fs_close(fd)
  local line = head and head:match('^([^\n]*)\n')
  if not line then return nil end
  local ok, ev = pcall(vim.json.decode, line)
  return ok and is_header(ev) and not too_new(ev) and ev.log_id or nil
end

-- Whether `data` (a log's bytes) starts with a header this version reads
function M.readable_header(data)
  local line = data:match('^([^\n]*)\n')
  if not line then return false end
  local ok, ev = pcall(vim.json.decode, line)
  return ok and is_header(ev) and not too_new(ev)
end

-- Whether process `pid` may be alive: only a definite ESRCH says it is not
function M.pid_alive(pid)
  local alive, _, name = uv.kill(pid, 0)
  return alive or name ~= 'ESRCH'
end

local STALE_SECONDS = 10
local WAIT_MS = 1000

-- The pid in the lock `lockdir`, or nil
local function read_pid(lockdir)
  local fh = io.open(lockdir .. '/pid', 'r')
  if not fh then return nil end
  local pid = tonumber(fh:read('*l') or '')
  fh:close()
  return pid
end

-- A lock left by a process that is gone, or held for longer than any append
-- takes. A lock this process holds is never stale (with_lock doesn't nest).
-- Returns: stale (boolean), and the pid it was judged by (nil when judged
-- by age alone, before its pid was read)
local function stale(lockdir)
  local stat = uv.fs_stat(lockdir)
  if not stat then return false end
  if os.time() - stat.mtime.sec > STALE_SECONDS then return true, read_pid(lockdir) end
  local pid = read_pid(lockdir)
  -- No pid yet: the holder is between its mkdir and writing the pid
  if not pid then return false end
  if pid == uv.os_getpid() then return true, pid end
  return not M.pid_alive(pid), pid
end

local function unlock(lockdir)
  os.remove(lockdir .. '/pid')
  uv.fs_rmdir(lockdir)
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
-- stale lock is broken; a live one is waited on for up to a second.
-- Returns: true and fn's results, or false and an error (fn not run)
function M.with_lock(lockdir, fn)
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
      if uv.hrtime() > deadline then
        return false, 'Timed out waiting for the lock ' .. lockdir
      end
    elseif uv.hrtime() > deadline then
      return false, 'Timed out waiting for the lock ' .. lockdir
    else
      uv.sleep(5)
    end
  end
  local results = { pcall(fn) }
  unlock(lockdir)
  if not results[1] then error(results[2], 0) end
  return true, unpack(results, 2, table.maxn(results))
end

return M
