-- Tests for the event log file: tolerant reads and appends (the lock: test_lock.lua)
local test_helper = dofile((vim.env.QFR_TEST_ROOT or '.') .. '/test/init.lua')
local assert = dofile(test_helper.root .. '/test/assertions.lua')

print('\nRunning event log tests...')

test_helper.setup_test_environment()
local log = require('quickfix-review.log')

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
  local header = log.segment_header(log.new_journal_id(), 1)
  assert.truthy(header.journal_id:match('^%x+$') and #header.journal_id == 16, '16 hex journal_id')
  assert.equals(header.v, 3, 'a v3 segment header')
  local a, b = log.event('add', {}), log.event('add', {})
  assert.not_equals(a.eid, b.eid, 'distinct eids')
  assert.equals(type(a.ts), 'number', 'ts set')
  assert.truthy(log.append(path, { header, a, b }, 384), 'appended')
  assert.equals(vim.fn.getfperm(path), 'rw-------', 'created with the mode given')
  local result = log.read(path)
  assert.equals(result.log_id, header.journal_id, 'header first')
  assert.length(result.events, 2, 'both events')
  assert.equals(log.read_id(path), header.journal_id, 'read_id')
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

test_helper.cleanup_test_environment()

return assert
