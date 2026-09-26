-- Tests for the event log file: tolerant reads, appends, and the lock
local test_helper = dofile('test/init.lua')
local assert = dofile('test/assertions.lua')

print('\nRunning event log tests...')

test_helper.setup_test_environment()
local log = require('quickfix-review.log')
local uv = vim.uv or vim.loop

local HEADER = '{"op":"header","log_id":"00000000000000aa","v":1}\n'

local function line(id)
  return vim.json.encode({ op = 'add', eid = 'e-' .. id, ts = 1,
    comment = { id = id, filename = '/f', lnum = 1, kind = 'note', body = id } }) .. '\n'
end

local function write_bytes(path, content, mode)
  local fh = io.open(path, mode or 'wb')
  assert.truthy(fh, 'can open ' .. path)
  fh:write(content)
  fh:close()
end

local function capture_notify(fn)
  local calls = {}
  local original = vim.notify
  vim.notify = function(msg, level) table.insert(calls, { msg = msg, level = level }) end
  local ok, err = pcall(fn)
  vim.notify = original
  if not ok then error(err, 0) end
  return calls
end

local function fresh()
  local path = vim.fn.tempname() .. '-log.jsonl'
  os.remove(path)
  return path
end

assert.run_test('a torn line in the middle is skipped with a warning naming its line', function()
  local path = fresh()
  write_bytes(path, HEADER .. line('a') .. '{"op":"add","comm\n' .. line('b'))
  local result
  local calls = capture_notify(function() result = log.read(path) end)
  assert.truthy(result, 'read succeeds')
  assert.equals(result.log_id, '00000000000000aa', 'header read')
  assert.length(result.events, 2, 'both good events read')
  assert.equals(result.events[2].comment.id, 'b', 'the event after the torn line read')
  assert.length(calls, 1, 'one warning')
  assert.truthy(calls[1].msg:find('line 3 of ' .. path, 1, true), 'names the line: ' .. calls[1].msg)
  assert.equals(calls[1].level, vim.log.levels.WARN, 'as a warning')
  os.remove(path)
end)

assert.run_test('trailing bytes after the last newline are not consumed', function()
  local path = fresh()
  local head = HEADER .. line('a')
  local partial = line('b')
  write_bytes(path, head .. partial:sub(1, 20))
  local result
  local calls = capture_notify(function() result = log.read(path) end)
  assert.length(result.events, 1, 'only the complete event')
  assert.equals(result.offset, #head, 'offset stops before the partial line')
  assert.equals(result.lines, 2, 'two lines read')
  assert.length(calls, 0, 'no warning for an unfinished line')

  -- The writer finishes its line; reading on from the offset picks it up
  write_bytes(path, partial:sub(21), 'ab')
  local tail = log.read(path, result.offset, result.lines)
  assert.length(tail.events, 1, 'the finished event read')
  assert.equals(tail.events[1].comment.id, 'b', 'whole, not split')
  assert.equals(tail.offset, #head + #partial, 'offset at the end')
  assert.equals(tail.lines, 3, 'line count carried on')
  os.remove(path)
end)

assert.run_test('append after a torn tail starts a new line', function()
  local path = fresh()
  write_bytes(path, HEADER .. '{"op":"add","torn')
  assert.truthy(log.append(path, { log.event('add', { comment = { id = 'c', filename = '/f', lnum = 1 } }) }),
    'appended')
  local result
  local calls = capture_notify(function() result = log.read(path) end)
  assert.length(result.events, 1, 'the appended event decodes')
  assert.equals(result.events[1].comment.id, 'c', 'intact')
  assert.length(calls, 1, 'the torn line is its own unreadable line')
  assert.truthy(calls[1].msg:find('line 2 of', 1, true), 'line 2')
  os.remove(path)
end)

assert.run_test('events get distinct eids; append writes several in one go', function()
  local path = fresh()
  local header = log.new_header()
  assert.truthy(header.log_id:match('^%x+$') and #header.log_id == 16, '16 hex log_id')
  local a, b = log.event('add', {}), log.event('add', {})
  assert.not_equals(a.eid, b.eid, 'distinct eids')
  assert.equals(type(a.ts), 'number', 'ts set')
  assert.truthy(log.append(path, { header, a, b }, 384), 'appended')
  assert.equals(vim.fn.getfperm(path), 'rw-------', 'created with the mode given')
  local result = log.read(path)
  assert.equals(result.log_id, header.log_id, 'header first')
  assert.length(result.events, 2, 'both events')
  assert.equals(log.read_id(path), header.log_id, 'read_id')
  os.remove(path)
end)

assert.run_test('a file without a header is not a log; reading past its end fails', function()
  local path = fresh()
  write_bytes(path, line('a'))
  local result, err = log.read(path)
  assert.equals(result, nil, 'refused')
  assert.truthy(err:find('not a quickfix-review log', 1, true), 'says why: ' .. tostring(err))
  assert.truthy(err:find(path .. '.bad', 1, true), 'names the manual fix: ' .. err)
  assert.equals(log.read_id(path), nil, 'no log_id')
  write_bytes(path, HEADER)
  result, err = log.read(path, 1000)
  assert.equals(result, nil, 'shorter than the offset')
  assert.truthy(err:find('shorter', 1, true), 'says so')
  os.remove(path)
end)

local function seed_lock(dir, pid)
  vim.fn.mkdir(dir, 'p')
  write_bytes(dir .. '/pid', tostring(pid) .. '\n')
end

assert.run_test('the lock runs fn, releases it, and re-raises its errors', function()
  local dir = vim.fn.tempname() .. '-lock'
  local ok, a, b = log.with_lock(dir, function() return 1, 2 end)
  assert.truthy(ok, 'locked')
  assert.equals(a, 1, 'first result')
  assert.equals(b, 2, 'second result')
  assert.equals(vim.fn.isdirectory(dir), 0, 'released')
  local raised = pcall(log.with_lock, dir, function() error('boom') end)
  assert.falsy(raised, 'error re-raised')
  assert.equals(vim.fn.isdirectory(dir), 0, 'released after an error')
end)

assert.run_test('a lock left by a dead process or by this one is broken', function()
  local dir = vim.fn.tempname() .. '-lock'
  local child = vim.system({ 'true' })
  child:wait()
  seed_lock(dir, child.pid)
  assert.truthy(log.with_lock(dir, function() end), 'dead holder: broken')
  seed_lock(dir, uv.os_getpid())
  assert.truthy(log.with_lock(dir, function() end), 'own pid (a crash before unlock): broken')
  assert.equals(vim.fn.isdirectory(dir), 0, 'released')
end)

assert.run_test('a broken lock leaves nothing aside, and the new holder\'s pid is in it', function()
  local dir = vim.fn.tempname() .. '-lock'
  local child = vim.system({ 'true' })
  child:wait()
  seed_lock(dir, child.pid)
  local held
  assert.truthy(log.with_lock(dir, function()
    local fh = io.open(dir .. '/pid', 'r')
    held = fh and tonumber(fh:read('*l'))
    if fh then fh:close() end
  end), 'broken and taken')
  assert.equals(held, uv.os_getpid(), 'this process holds it')
  assert.length(vim.fn.glob(dir .. '.stale-*', true, true), 0, 'no stale lock left aside')
  assert.equals(vim.fn.isdirectory(dir), 0, 'released')
end)

assert.run_test('a lock moved away by a breaker before its pid is written is taken again', function()
  local dir = vim.fn.tempname() .. '-lock'
  local original_open = io.open
  local moved = false
  io.open = function(path, mode)
    if not moved and path == dir .. '/pid' and mode == 'w' then
      moved = true
      uv.fs_rename(dir, dir .. '.stale-test')
    end
    return original_open(path, mode)
  end
  local runs, held = 0, nil
  local ok, a, b = pcall(log.with_lock, dir, function()
    runs = runs + 1
    local fh = original_open(dir .. '/pid', 'r')
    held = fh and tonumber(fh:read('*l'))
    if fh then fh:close() end
  end)
  io.open = original_open
  vim.fn.delete(dir .. '.stale-test', 'rf')
  assert.truthy(ok, 'no error raised: ' .. tostring(a))
  assert.truthy(moved, 'the lock was moved away once')
  assert.equals(a, true, 'taken on retry: ' .. tostring(b))
  assert.equals(runs, 1, 'fn ran once')
  assert.equals(held, uv.os_getpid(), 'this process holds it')
  assert.equals(vim.fn.isdirectory(dir), 0, 'released')
end)

assert.run_test('a stale lock whose pid changed since it was judged is not broken', function()
  local dir = vim.fn.tempname() .. '-lock'
  local child = vim.system({ 'true' })
  child:wait()
  seed_lock(dir, child.pid)
  local holder = vim.system({ 'sleep', '30' })
  -- Between stale() reading the dead pid and break_lock re-reading it, the
  -- lock is broken and retaken by a live process
  local original_kill = uv.kill
  uv.kill = function(pid, sig)
    if pid == child.pid then write_bytes(dir .. '/pid', tostring(holder.pid) .. '\n') end
    return original_kill(pid, sig)
  end
  local ok, taken = pcall(log.with_lock, dir, function() error('must not run') end)
  uv.kill = original_kill
  holder:kill(9)
  local left = vim.fn.isdirectory(dir)
  vim.fn.delete(dir, 'rf')
  assert.truthy(ok, 'no error raised')
  assert.falsy(taken, 'not taken')
  assert.equals(left, 1, 'the retaken lock is left alone')
  assert.length(vim.fn.glob(dir .. '.stale-*', true, true), 0, 'nothing moved aside')
end)

assert.run_test('a stale lock that can never be broken times out rather than spinning', function()
  local dir = vim.fn.tempname() .. '-lock'
  local child = vim.system({ 'true' })
  child:wait()
  seed_lock(dir, child.pid)
  -- Every rename (of the stale lock aside) fails; after LIMIT calls the real
  -- one is back, so a regression breaks the lock instead of hanging the suite
  local LIMIT = 1000000
  local original_rename, calls = uv.fs_rename, 0
  uv.fs_rename = function(a, b)
    calls = calls + 1
    if calls > LIMIT then return original_rename(a, b) end
    return nil, 'EPERM: operation not permitted', 'EPERM'
  end
  local start = uv.hrtime()
  local ran = false
  local ok, taken, err = pcall(log.with_lock, dir, function() ran = true end)
  local waited = (uv.hrtime() - start) / 1e6
  uv.fs_rename = original_rename
  vim.fn.delete(dir, 'rf')
  assert.truthy(ok, 'no error raised: ' .. tostring(taken))
  assert.falsy(taken, 'not taken')
  assert.truthy(tostring(err):find('Timed out', 1, true), 'times out: ' .. tostring(err))
  assert.falsy(ran, 'fn not run')
  assert.truthy(calls <= LIMIT, 'gave up before the rename was restored (' .. calls .. ' calls)')
  assert.truthy(waited < 3000, 'within about the wait, got ' .. waited .. 'ms')
end)

assert.run_test('a live lock is waited on, then times out; an old one is broken', function()
  local dir = vim.fn.tempname() .. '-lock'
  local holder = vim.system({ 'sleep', '30' })
  seed_lock(dir, holder.pid)
  local start = uv.hrtime()
  local ok, err = log.with_lock(dir, function() error('must not run') end)
  local waited = (uv.hrtime() - start) / 1e6
  assert.falsy(ok, 'not taken')
  assert.truthy(err:find('Timed out', 1, true), 'times out: ' .. tostring(err))
  assert.truthy(waited >= 900, 'waited about a second, got ' .. waited .. 'ms')
  assert.equals(vim.fn.isdirectory(dir), 1, 'the live lock is left alone')

  local old = os.time() - 60
  uv.fs_utime(dir, old, old)
  assert.truthy(log.with_lock(dir, function() end), 'held for over 10s: broken')
  holder:kill(9)
  holder:wait()
end)

test_helper.cleanup_test_environment()

return assert
