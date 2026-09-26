-- Tests for the event reducer: replaying the log's events into the review
local test_helper = dofile('test/init.lua')
local assert = dofile('test/assertions.lua')

print('\nRunning reducer tests...')

test_helper.setup_test_environment()
local reduce = require('quickfix-review.reduce')

local function rec(id, body)
  return { id = id, filename = '/f.txt', lnum = 1, end_lnum = 1, kind = 'note', body = body or id,
    created_at = 1 }
end

-- Replay `events` from a fresh state; returns the state and the ignore reasons
local function replay(events)
  local state, reasons = reduce.new(), {}
  for i, ev in ipairs(events) do
    local _, reason = reduce.apply(state, ev)
    reasons[i] = reason or false
  end
  return state, reasons
end

local function ids(state)
  local out = {}
  for i, c in ipairs(state.comments) do out[i] = c.id end
  return table.concat(out, ',')
end

assert.run_test('add appends; a duplicate add is ignored', function()
  local state, why = replay({
    { op = 'header', log_id = 'x', v = 1 },
    { op = 'add', comment = rec('a') },
    { op = 'add', comment = rec('b') },
    { op = 'add', comment = rec('a', 'again') },
  })
  assert.equals(ids(state), 'a,b', 'order of adds')
  assert.equals(reduce.get(state, 'a').body, 'a', 'first add wins')
  assert.equals(why[4], 'duplicate', 'duplicate reported')
end)

assert.run_test('add of a trashed id is ignored', function()
  local state, why = replay({
    { op = 'add', comment = rec('a') },
    { op = 'delete', id = 'a' },
    { op = 'add', comment = rec('a', 'back') },
  })
  assert.equals(ids(state), '', 'not resurrected by add')
  assert.equals(why[3], 'duplicate', 'reported as a duplicate')
  assert.truthy(state.trash.a, 'still in the trash')
end)

assert.run_test('update sets then unsets, never the id; unknown ids are ignored', function()
  local original = rec('a')
  original.response = 'old'
  local state, why = replay({
    { op = 'add', comment = original },
    { op = 'update', id = 'a', set = { body = 'new', response = 'kept?', id = 'z' }, unset = { 'response' } },
    { op = 'update', id = 'nope', set = { body = 'x' } },
  })
  local c = reduce.get(state, 'a')
  assert.equals(c.body, 'new', 'set applied')
  assert.equals(c.response, nil, 'unset applied after set')
  assert.equals(c.id, 'a', 'id protected')
  assert.equals(original.body, 'a', 'the logged record is not mutated')
  assert.equals(why[3], 'unknown', 'update of an unknown id ignored')
end)

assert.run_test('update after delete is ignored', function()
  local state, why = replay({
    { op = 'add', comment = rec('a') },
    { op = 'delete', id = 'a' },
    { op = 'update', id = 'a', set = { body = 'late' } },
  })
  assert.equals(ids(state), '', 'not resurrected by update')
  assert.equals(state.trash.a.body, 'a', 'trashed content untouched')
  assert.equals(why[3], 'unknown', 'reported as unknown')
end)

assert.run_test('delete moves to the trash; deleting twice is ignored', function()
  local state, why = replay({
    { op = 'add', comment = rec('a') },
    { op = 'add', comment = rec('b') },
    { op = 'delete', id = 'a' },
    { op = 'delete', id = 'a' },
  })
  assert.equals(ids(state), 'b', 'a removed')
  assert.equals(state.trash.a.id, 'a', 'a in the trash')
  assert.equals(why[4], 'unknown', 'second delete ignored')
end)

assert.run_test('restore brings a trashed comment back at the end; a live one is ignored', function()
  local a = rec('a')
  local state, why = replay({
    { op = 'add', comment = a },
    { op = 'add', comment = rec('b') },
    { op = 'delete', id = 'a' },
    { op = 'restore', id = 'a', comment = a },
    { op = 'restore', id = 'b', comment = rec('b', 'other') },
  })
  assert.equals(ids(state), 'b,a', 'restored at the end')
  assert.equals(state.trash.a, nil, 'out of the trash')
  assert.equals(why[5], 'live', 'restore of a live id ignored')
  assert.equals(reduce.get(state, 'b').body, 'b', 'live comment unchanged')
end)

assert.run_test('restore of an unknown id makes it live; a mismatched id is invalid', function()
  local state, why = replay({
    { op = 'restore', id = 'q', comment = rec('q') },
    { op = 'restore', id = 'r', comment = rec('s') },
  })
  assert.equals(ids(state), 'q', 'unknown id restored')
  assert.equals(why[2], 'invalid', 'mismatched ids rejected')
end)

assert.run_test('clear trashes only the comments it lists', function()
  local state = replay({
    { op = 'add', comment = rec('a') },
    { op = 'add', comment = rec('b') },
    { op = 'add', comment = rec('c') },
    { op = 'clear', comments = { rec('a'), rec('b') } },
  })
  assert.equals(ids(state), 'c', 'an unseen comment survives')
  assert.truthy(state.trash.a and state.trash.b, 'cleared comments in the trash')
  local restored = replay({
    { op = 'add', comment = rec('a') },
    { op = 'clear', comments = { rec('a') } },
    { op = 'restore', id = 'a', comment = rec('a') },
  })
  assert.equals(ids(restored), 'a', 'a cleared comment can be restored')
end)

assert.run_test('import adds each comment, skipping live and trashed ids', function()
  local state, why = replay({
    { op = 'add', comment = rec('a') },
    { op = 'add', comment = rec('t') },
    { op = 'delete', id = 't' },
    { op = 'import', source_sha256 = 'x', comments = { rec('a', 'dup'), rec('t'), rec('n') } },
  })
  assert.equals(ids(state), 'a,n', 'only the new one added')
  assert.equals(reduce.get(state, 'a').body, 'a', 'live comment kept')
  assert.equals(why[4], 'duplicate', 'duplicates reported')
end)

local function removed(state)
  local out = {}
  for i, e in ipairs(state.removed) do out[i] = e.id .. ':' .. e.op .. ':' .. tostring(e.eid) end
  return table.concat(out, ',')
end

assert.run_test('removed lists trashed ids in the order they were removed', function()
  local state = replay({
    { op = 'add', comment = rec('a') },
    { op = 'add', comment = rec('b') },
    { op = 'delete', id = 'a', eid = 'e1', ts = 10 },
    { op = 'delete', id = 'b', eid = 'e2', ts = 20 },
  })
  assert.equals(removed(state), 'a:delete:e1,b:delete:e2', 'in file order')
  assert.equals(state.removed[2].ts, 20, 'ts kept')
end)

assert.run_test('a removal whose ts is not a number keeps no ts', function()
  local state = replay({
    { op = 'add', comment = rec('a') },
    { op = 'delete', id = 'a', eid = 'e1', ts = 'x' },
  })
  assert.equals(removed(state), 'a:delete:e1', 'still removed')
  assert.equals(state.removed[1].ts, nil, 'no ts')
end)

assert.run_test('the comments of one clear share its eid', function()
  local events = {
    { op = 'add', comment = rec('a') },
    { op = 'add', comment = rec('b') },
    { op = 'add', comment = rec('c') },
    { op = 'clear', comments = { rec('a'), rec('b') }, eid = 'c1' },
    { op = 'delete', id = 'c', eid = 'd1' },
  }
  local state = replay(events)
  assert.equals(removed(state), 'a:clear:c1,b:clear:c1,c:delete:d1', 'delete after the clear is last')
  reduce.apply(state, { op = 'restore', id = 'c', comment = rec('c'), eid = 'r1' })
  assert.equals(removed(state), 'a:clear:c1,b:clear:c1', 'restore drops the entry; the clear is last again')
  -- Replaying gives the same list
  table.insert(events, { op = 'restore', id = 'c', comment = rec('c'), eid = 'r1' })
  assert.equals(removed(replay(events)), removed(state), 'deterministic')
end)

assert.run_test('a restored comment has no removed entry; ignored events add none', function()
  local state = replay({
    { op = 'add', comment = rec('a') },
    { op = 'delete', id = 'a', eid = 'e1' },
    { op = 'restore', id = 'a', comment = rec('a') },
    { op = 'delete', id = 'zz', eid = 'e2' },
    { op = 'clear', comments = { rec('yy') }, eid = 'e3' },
  })
  assert.equals(removed(state), '', 'nothing removed')
  assert.equals(state.trash.a, nil, 'not in the trash')
end)

assert.run_test('unknown ops and malformed events change nothing', function()
  local state, why = replay({
    { op = 'add', comment = rec('a') },
    { op = 'frobnicate', id = 'a' },
    { op = 'add', comment = { body = 'no id' } },
    { op = 'delete' },
  })
  assert.equals(ids(state), 'a', 'state unchanged')
  assert.equals(why[2], 'unknown op', 'unknown op reported')
  assert.equals(why[3], 'invalid', 'record without an id')
  assert.equals(why[4], 'invalid', 'delete without an id')
end)

test_helper.cleanup_test_environment()

return assert
