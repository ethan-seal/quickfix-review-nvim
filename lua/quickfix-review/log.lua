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

-- Whether byte `offset` of the file at `path` starts a line: it is 0, or
-- the byte before it is a \n. A tail offset that does not is stale (the log
-- was rewritten in place), so the log must be replayed from the start. A
-- file that can't be read answers false.
function M.at_line_start(path, offset)
  if offset <= 0 then return true end
  local fd = uv.fs_open(path, 'r', 0)
  if not fd then return false end
  local byte = uv.fs_read(fd, 1, offset - 1)
  uv.fs_close(fd)
  return byte == '\n'
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

return M
