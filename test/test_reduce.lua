-- Tests for the event reducer: replaying the log's events into the review
local test_helper = dofile((vim.env.QFR_TEST_ROOT or '.') .. '/test/init.lua')
local assert = dofile(test_helper.root .. '/test/assertions.lua')

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

-- state.index.by_id matches one rebuilt from scratch, record for record
local function check_index(state, what)
  local fresh = reduce.reindex({ comments = state.comments, trash = state.trash, removed = state.removed })
  assert.truthy(vim.deep_equal(state.index.by_id, fresh.index.by_id), 'by_id equal to a rebuild: ' .. what)
  for id, c in pairs(fresh.index.by_id) do
    assert.truthy(state.index.by_id[id] == c, 'by_id[' .. id .. '] is the live record: ' .. what)
  end
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
  check_index(state, 'after ignored events')
end)

-- The state of `events`, round-tripped through JSON as a checkpoint is
local function as_checkpoint(state)
  local decoded = vim.json.decode(vim.json.encode({ op = 'checkpoint', eid = 'cp', ts = 9, state = reduce.persisted(state) }),
    { luanil = { object = true, array = true } })
  return decoded
end

assert.run_test('a checkpoint of a replay replays to the same state', function()
  local events = {
    { op = 'header', log_id = 'x', v = 1 },
    { op = 'add', comment = rec('a') },
    { op = 'add', comment = rec('b') },
    { op = 'add', comment = rec('c') },
    { op = 'add', comment = rec('d') },
    { op = 'delete', id = 'b', eid = 'e1', ts = 5 },
    { op = 'clear', comments = { rec('c'), rec('d') }, eid = 'e2', ts = 6 },
    { op = 'add', comment = rec('e') },
    { op = 'update', id = 'a', set = { body = 'new' } },
  }
  local state = replay(events)
  local again, why = replay({ { op = 'header', log_id = 'y', v = 1 }, as_checkpoint(state) })
  assert.equals(why[2], false, 'applied')
  assert.truthy(vim.deep_equal(again.comments, state.comments), 'same comments')
  assert.truthy(vim.deep_equal(again.trash, state.trash), 'same trash')
  assert.truthy(vim.deep_equal(again.removed, state.removed), 'same removals, in order')

  -- Later events apply on top
  local later = replay({
    { op = 'header', log_id = 'y', v = 1 }, as_checkpoint(state),
    { op = 'update', id = 'e', set = { body = 'E' } },
    { op = 'delete', id = 'a', eid = 'e3' },
    { op = 'restore', id = 'c', comment = rec('c') },
    { op = 'add', comment = rec('b') }, -- in the trash: still a duplicate
  })
  assert.equals(ids(later), 'e,c', 'updated, deleted and restored on top')
  assert.equals(reduce.get(later, 'e').body, 'E', 'update applied')
  assert.truthy(later.trash.a and later.trash.b and later.trash.d, 'trash carried over')
  assert.equals(later.trash.c, nil, 'restored out of the trash')
end)

assert.run_test('a checkpoint keeps records verbatim', function()
  local r = rec('a')
  r.extra = { nested = true }
  r.legacy_text = 'old text'
  r.anchor = { sha = 'abc123', lnum = 1, end_lnum = 1, lines = { 'x' } }
  local state = replay({ { op = 'add', comment = r } })
  local again = replay({ as_checkpoint(state) })
  local got = again.comments[1]
  assert.truthy(vim.deep_equal(got, r), 'record unchanged: ' .. vim.inspect(got))
  assert.equals(got.pos, nil, 'no pos')
end)


-- K adds, then K deletes each with its own eid, K = TRASH_KEEP + 500
local function many_deletes()
  local K = reduce.TRASH_KEEP + 500
  local events = {}
  for i = 1, K do table.insert(events, { op = 'add', comment = rec('c' .. i) }) end
  for i = 1, K do table.insert(events, { op = 'delete', id = 'c' .. i, eid = 'e' .. i, ts = i }) end
  return events, K
end

assert.run_test('removed and trash keep only the newest TRASH_KEEP removals', function()
  local events, K = many_deletes()
  local state = replay(events)
  assert.equals(#state.removed, reduce.TRASH_KEEP, 'removed bounded')
  assert.equals(state.removed[1].id, 'c501', 'oldest kept is c501')
  assert.equals(state.removed[#state.removed].id, 'c' .. K, 'newest last')
  assert.equals(state.trash.c1, nil, 'c1 pruned')
  assert.equals(state.trash.c500, nil, 'c500 pruned')
  assert.truthy(state.trash.c501, 'c501 kept')
  assert.truthy(state.trash['c' .. K], 'newest kept')
  assert.equals(vim.tbl_count(state.trash), reduce.TRASH_KEEP, 'trash bounded')
  for _, e in ipairs(state.removed) do
    assert.truthy(state.trash[e.id], 'every removed id is in the trash: ' .. e.id)
  end
  check_index(state, 'after many deletes')

  -- Replay from scratch equals a checkpoint of a prefix plus the rest
  local split = 2 * K - 300
  local prefix = {}
  for i = 1, split do prefix[i] = events[i] end
  local rest = { as_checkpoint(replay(prefix)) }
  for i = split + 1, #events do table.insert(rest, events[i]) end
  local again = replay(rest)
  assert.truthy(vim.deep_equal(again.comments, state.comments), 'same comments')
  assert.truthy(vim.deep_equal(again.trash, state.trash), 'same trash')
  assert.truthy(vim.deep_equal(again.removed, state.removed), 'same removals, in order')
end)

assert.run_test('a restore of a pruned id makes it live', function()
  local events = many_deletes()
  local state = replay(events)
  local _, why = reduce.apply(state, { op = 'restore', id = 'c1', comment = rec('c1'), eid = 'r1' })
  assert.equals(why, nil, 'applied')
  assert.truthy(reduce.get(state, 'c1'), 'c1 live')
  assert.equals(#state.removed, reduce.TRASH_KEEP, 'removed unchanged')
  check_index(state, 'after restoring a pruned id')
end)

assert.run_test('an add of a pruned id is applied', function()
  local events = many_deletes()
  local state = replay(events)
  local _, why = reduce.apply(state, { op = 'add', comment = rec('c1', 'back') })
  assert.equals(why, nil, 'no longer a duplicate')
  assert.equals(reduce.get(state, 'c1').body, 'back', 'live again')
  -- An id still in the trash stays a duplicate
  local _, why2 = reduce.apply(state, { op = 'add', comment = rec('c501', 'back') })
  assert.equals(why2, 'duplicate', 'kept trash id still a duplicate')
end)

assert.run_test('a clear larger than TRASH_KEEP is kept whole', function()
  local n = reduce.TRASH_KEEP + 10
  local events, cleared = {}, {}
  for i = 1, n do
    table.insert(events, { op = 'add', comment = rec('k' .. i) })
    cleared[i] = rec('k' .. i)
  end
  table.insert(events, { op = 'add', comment = rec('last') })
  table.insert(events, { op = 'clear', comments = cleared, eid = 'big' })
  local state = replay(events)
  assert.equals(#state.removed, n, 'the whole clear is kept')
  for i = 1, n do assert.truthy(state.trash['k' .. i], 'k' .. i .. ' in the trash') end

  reduce.apply(state, { op = 'delete', id = 'last', eid = 'd1' })
  assert.equals(#state.removed, reduce.TRASH_KEEP, 'pruned to the bound by the next removal')
  assert.equals(state.removed[#state.removed].id, 'last', 'newest last')
  assert.equals(state.trash.k11, nil, 'oldest of the clear pruned')
  assert.truthy(state.trash.k12, 'rest of the clear kept')
  assert.equals(vim.tbl_count(state.trash), reduce.TRASH_KEEP, 'trash bounded')
end)
assert.run_test('a malformed checkpoint is ignored and changes nothing', function()
  local base = { { op = 'add', comment = rec('a') } }
  for i, bad in ipairs({
    { op = 'checkpoint' },
    { op = 'checkpoint', state = { comments = {}, trash = {} } },
    { op = 'checkpoint', state = { comments = { { body = 'no id' } }, trash = {}, removed = {} } },
    { op = 'checkpoint', state = { comments = {}, trash = { x = rec('y') }, removed = {} } },
    { op = 'checkpoint', state = { comments = {}, trash = {}, removed = { 'b' } } },
  }) do
    local state, why = replay(vim.list_extend(vim.deepcopy(base), { bad }))
    assert.equals(why[2], 'invalid', 'case ' .. i .. ' invalid')
    assert.equals(ids(state), 'a', 'case ' .. i .. ' unchanged')
    check_index(state, 'malformed checkpoint ' .. i)
  end
end)

assert.run_test('by_id stays equal to a rebuild after every op', function()
  local state = reduce.new()
  local events = {
    { op = 'header', log_id = 'x', v = 1 },
    { op = 'add', comment = rec('a') },
    { op = 'add', comment = rec('a', 'dup') },
    { op = 'import', comments = { rec('b'), rec('c'), rec('b', 'dup in import'), rec('d') } },
    { op = 'update', id = 'b', set = { body = 'B' } },
    { op = 'update', id = 'zz', set = { body = 'nope' } },
    { op = 'delete', id = 'a', eid = 'e1', ts = 1 },
    { op = 'delete', id = 'a', eid = 'e2', ts = 2 },
    { op = 'clear', comments = { rec('c'), rec('d') }, eid = 'e3', ts = 3 },
    { op = 'restore', id = 'c', comment = rec('c') },
    { op = 'restore', id = 'c', comment = rec('c', 'live') },
    { op = 'add', comment = rec('e') },
  }
  for i, ev in ipairs(events) do
    reduce.apply(state, ev)
    check_index(state, 'event ' .. i .. ' (' .. ev.op .. ')')
  end
  assert.equals(ids(state), 'b,c,e', 'ops applied')
  assert.equals(reduce.get(state, 'b').body, 'B', 'get sees the updated record')
  assert.equals(reduce.get(state, 'a'), nil, 'deleted id not live')

  reduce.apply(state, as_checkpoint(state))
  check_index(state, 'checkpoint')
  reduce.apply(state, { op = 'update', id = 'e', set = { body = 'E' } })
  check_index(state, 'update after checkpoint')
  assert.equals(reduce.get(state, 'e').body, 'E', 'get after checkpoint')
end)

assert.run_test('a checkpoint carrying an index has it rebuilt', function()
  local state = replay({
    { op = 'checkpoint', state = { comments = { rec('a'), rec('b') }, trash = {}, removed = {},
      index = { by_id = { zz = rec('zz') } } } },
  })
  check_index(state, 'checkpoint with bogus index')
  assert.equals(reduce.get(state, 'zz'), nil, 'bogus entry dropped')
  assert.equals(reduce.get(state, 'b').id, 'b', 'real entry indexed')
end)

assert.run_test('deleting one of duplicate ids indexes the next copy', function()
  local state = replay({
    { op = 'checkpoint', state = { comments = { rec('a', 'first'), rec('b'), rec('a', 'second') }, trash = {},
      removed = {} } },
  })
  assert.equals(reduce.get(state, 'a').body, 'first', 'the first copy wins')
  reduce.apply(state, { op = 'delete', id = 'a', eid = 'd1' })
  check_index(state, 'after deleting the first copy')
  assert.equals(reduce.get(state, 'a').body, 'second', 'the second copy is found')
end)

assert.run_test('persisted state has no index', function()
  local state = replay({ { op = 'add', comment = rec('a') } })
  local decoded = vim.json.decode(vim.json.encode(reduce.persisted(state)))
  assert.equals(decoded.index, nil, 'no index key')
  assert.equals(decoded.comments[1].id, 'a', 'comments kept')
end)

assert.run_test('a rebase records its from_root; again it is a no-op, never a duplicate', function()
  local state, why = replay({
    { op = 'add', comment = rec('a') },
    { op = 'rebase', from_root = '/old/root', eid = 'r1' },
    { op = 'rebase', from_root = '/other', eid = 'r2' },
    { op = 'rebase', from_root = '/old/root', eid = 'r3' },
  })
  assert.equals(why[2], false, 'applied')
  assert.equals(why[4], false, 'a repeat is not reported (never duplicate)')
  assert.equals(table.concat(state.rebases, ','), '/old/root,/other', 'recorded once, in order')
  assert.equals(ids(state), 'a', 'comments untouched')
end)

assert.run_test('a malformed rebase is invalid and changes nothing', function()
  for i, bad in ipairs({
    { op = 'rebase' },
    { op = 'rebase', from_root = 3 },
    { op = 'rebase', from_root = 'rel/path' },
    { op = 'rebase', from_root = '/' },
    { op = 'rebase', from_root = '/old/' },
    { op = 'rebase', from_root = '' },
  }) do
    local state, why = replay({ bad })
    assert.equals(why[1], 'invalid', 'case ' .. i .. ' invalid')
    assert.length(state.rebases, 0, 'case ' .. i .. ' nothing recorded')
  end
end)

assert.run_test('a checkpoint keeps the rebases; one without them keeps the state\'s', function()
  local state = replay({ { op = 'add', comment = rec('a') }, { op = 'rebase', from_root = '/old' } })
  assert.equals(reduce.persisted(state).rebases[1], '/old', 'persisted carries the rebases')
  local again, why = replay({ as_checkpoint(state) })
  assert.equals(why[1], false, 'applied')
  assert.equals(table.concat(again.rebases, ','), '/old', 'rebases restored')
  assert.truthy(again.rebases ~= state.rebases, 'copied')
  -- A v2 rotation checkpoint has no rebases: they are left as they are
  local kept, kwhy = replay({
    { op = 'rebase', from_root = '/old' },
    { op = 'checkpoint', state = { comments = { rec('b') }, trash = {}, removed = {} } },
  })
  assert.equals(kwhy[2], false, 'a checkpoint without rebases is valid')
  assert.equals(table.concat(kept.rebases, ','), '/old', 'rebases kept')
  assert.equals(ids(kept), 'b', 'the state replaced')
  local _, bwhy = replay({ { op = 'checkpoint', state = { comments = {}, trash = {}, removed = {}, rebases = 'x' } } })
  assert.equals(bwhy[1], 'invalid', 'rebases not a list')
  _, bwhy = replay({ { op = 'checkpoint', state = { comments = {}, trash = {}, removed = {}, rebases = { 1 } } } })
  assert.equals(bwhy[1], 'invalid', 'a rebase not a string')
end)

assert.run_test('resolve_filename maps a path under a rebase root, the longest first', function()
  local record = require('quickfix-review.store.record')
  local rebases = { '/old', '/old/sub' }
  assert.equals(record.resolve_filename('/old/a.txt', '/new', rebases), '/new/a.txt', 'under /old')
  assert.equals(record.resolve_filename('/old/sub/b.txt', '/new', rebases), '/new/b.txt', 'the longest wins')
  assert.equals(record.resolve_filename('/old2/c.txt', '/new', rebases), '/old2/c.txt', 'a sibling prefix')
  assert.equals(record.resolve_filename('/old', '/new', rebases), '/old', 'the root itself')
  assert.equals(record.resolve_filename('rel.txt', '/new', rebases), '/new/rel.txt', 'relative, as before')
  assert.equals(record.resolve_filename('/old/a.txt', nil, rebases), '/old/a.txt', 'no root: unchanged')
end)

assert.run_test('replaying 5000 adds is fast', function()
  local events = {}
  for i = 1, 5000 do events[i] = { op = 'add', comment = rec('c' .. i) } end
  local t0 = vim.uv.hrtime()
  local state = replay(events)
  local ms = (vim.uv.hrtime() - t0) / 1e6
  assert.equals(#state.comments, 5000, 'all added')
  assert.truthy(ms < 1000, 'replay took ' .. ms .. ' ms')
end)

test_helper.cleanup_test_environment()

return assert
