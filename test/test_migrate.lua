-- Tests for the v2 -> v3 journal migration (docs/journal.md#migration)
local test_helper = dofile((vim.env.QFR_TEST_ROOT or '.') .. '/test/init.lua')
local assert = dofile(test_helper.root .. '/test/assertions.lua')

print('\nRunning journal migration tests...')

local qf = test_helper.setup_test_environment()
local uv = vim.uv or vim.loop
local test_file = test_helper.create_test_file('line 1\nline 2\nline 3\n')
local abs = vim.fn.fnamemodify(test_file, ':p')

local function read_bytes(path)
  local fh = io.open(path, 'rb')
  if not fh then return nil end
  local content = fh:read('*a')
  fh:close()
  return content
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

local function restart(opts)
  for name, _ in pairs(package.loaded) do
    if name:match('^quickfix%-review') then package.loaded[name] = nil end
  end
  qf = require('quickfix-review')
  qf.setup(opts or {})
  return qf, require('quickfix-review.store')
end

local log = require('quickfix-review.log')

-- Unknown #1 (docs/journal.md): a running instance that finds log.jsonl
-- replaced by the v3 tombstone refuses to change the review, and neither
-- moves the tombstone aside nor starts a fresh log in its place. With v3,
-- a tombstone with no journal beside it is refused the same way.
assert.run_test('a lone v3 tombstone is refused, not replaced, and stops snapshot GC', function()
  local dir = vim.fn.tempname() .. '-tomb'
  vim.fn.mkdir(dir, 'p')
  local log_file = dir .. '/log.jsonl'
  local tomb = vim.json.encode({ op = 'header', v = 3, log_id = log.v2_header().log_id, moved_to = 'events/' }) .. '\n'
  local fh = io.open(log_file, 'wb')
  fh:write(tomb)
  fh:close()
  local ino = uv.fs_stat(log_file).ino
  local store, added
  local calls = capture_notify(function()
    qf, store = restart({ storage_dir = dir })
    added = store.add({ filename = abs, lnum = 2, kind = 'note', body = 'after' })
  end)
  local missing = false
  for _, c in ipairs(calls) do
    if tostring(c.msg):find('which is missing', 1, true) then missing = true end
  end
  assert.truthy(missing, 'refused: the journal is missing: ' .. vim.inspect(calls))
  assert.falsy(added, 'the change is refused')
  assert.equals(read_bytes(log_file), tomb, 'the tombstone is unchanged (no header appended)')
  assert.equals(uv.fs_stat(log_file).ino, ino, 'not replaced')
  assert.length(vim.fn.glob(log_file .. '.torn-*', true, true), 0, 'not moved aside')
  assert.falsy(uv.fs_stat(dir .. '/events'), 'no journal started')
  vim.fn.mkdir(dir .. '/snapshots', 'p')
  local orphan = dir .. '/snapshots/' .. string.rep('ab', 32)
  vim.fn.writefile({ 'x' }, orphan)
  uv.fs_utime(orphan, os.time() - 3 * 86400, os.time() - 3 * 86400)
  capture_notify(function() assert.equals(store.gc_snapshots(), 0, 'gc collects nothing') end)
  assert.truthy(uv.fs_stat(orphan), 'the snapshot is kept')
  vim.fn.delete(dir, 'rf')
end)

-- A v2 review's files. Comment records come from a scratch v3 review, so
-- they are what the plugin writes. Rotated logs log.1000 and log.2000, then
-- log.jsonl; each later log starts with the checkpoint of the state so far,
-- as v2 rotation wrote it. `log` is the log.jsonl path.
-- Returns: the 4 comment ids, oldest first
local function write_v2(log_path)
  local scratch = vim.fn.tempname() .. '-records.json'
  local _, store = restart({ storage_file = scratch })
  for l = 1, 4 do
    assert.truthy(store.add({ filename = abs, lnum = l % 3 + 1, kind = 'note', body = 'c' .. l }), 'seeded')
  end
  local records = vim.deepcopy(store.all())
  test_helper.remove_storage(scratch)
  local log = require('quickfix-review.log')
  local function add(r) return log.event('add', { comment = r }) end
  local function cp(n)
    local c = {}
    for i = 1, n do c[i] = records[i] end
    return log.event('checkpoint', { state = { comments = c, trash = vim.empty_dict(), removed = {} } })
  end
  local base = log_path:gsub('%.jsonl$', '')
  local function write(path, events)
    local lines = { vim.json.encode(log.v2_header()) }
    for _, ev in ipairs(events) do table.insert(lines, vim.json.encode(ev)) end
    table.insert(lines, '')
    vim.fn.writefile(lines, path, 'b')
  end
  write(base .. '.1000.jsonl', { add(records[1]), add(records[2]) })
  write(base .. '.2000.jsonl', { cp(2), add(records[3]) })
  write(log_path, { cp(3), add(records[4]) })
  local ids = {}
  for i, r in ipairs(records) do ids[i] = r.id end
  return ids
end

local function ids_of(list)
  local out = {}
  for i, c in ipairs(list) do out[i] = c.id end
  return table.concat(out, ',')
end

local function ino(path)
  local st = uv.fs_stat(path)
  return st and st.ino
end

-- Restart with the migration's test hooks set before the review loads
local function restart_hooked(opts, hooks)
  for name, _ in pairs(package.loaded) do
    if name:match('^quickfix%-review') then package.loaded[name] = nil end
  end
  local migrate = require('quickfix-review.store.migrate')
  for k, v in pairs(hooks) do migrate._test[k] = v end
  qf = require('quickfix-review')
  qf.setup(opts)
  local store = require('quickfix-review.store')
  store.all()
  for k, _ in pairs(hooks) do migrate._test[k] = nil end
  migrate._test.mismatch = false
  return qf, store
end

assert.run_test('migration: 2 rotated logs and log.jsonl become segments 1..3 (same inodes), log.jsonl the tombstone', function()
  local dir = vim.fn.tempname() .. '-v2'
  vim.fn.mkdir(dir, 'p')
  local ids = write_v2(dir .. '/log.jsonl')
  vim.fn.writefile({ '{"v":2}' }, dir .. '/state.json')
  local inos = { ino(dir .. '/log.1000.jsonl'), ino(dir .. '/log.2000.jsonl'), ino(dir .. '/log.jsonl') }
  local bytes = { read_bytes(dir .. '/log.1000.jsonl'), read_bytes(dir .. '/log.2000.jsonl'), read_bytes(dir .. '/log.jsonl') }
  local v2_header = vim.json.decode(vim.fn.readfile(dir .. '/log.jsonl')[1])
  local _, store = restart({ storage_dir = dir })
  assert.equals(ids_of(store.all()), table.concat(ids, ','), 'the same comments')
  for i = 1, 3 do
    local p = string.format('%s/events/%06d.jsonl', dir, i)
    assert.equals(ino(p), inos[i], 'segment ' .. i .. ' is the v2 file (a hard link)')
    assert.equals(read_bytes(p), bytes[i], 'segment ' .. i .. '\'s bytes unchanged')
    assert.truthy(uv.fs_stat(string.format('%s/events/%06d.refs', dir, i)), 'segment ' .. i .. ' has refs')
  end
  local h4 = vim.json.decode(vim.fn.readfile(dir .. '/events/000004.jsonl')[1])
  assert.equals(h4.v, 3, 'segment 4 is v3')
  assert.equals(h4.migrated_from.segments, 3, 'naming the migrated segments')
  local tomb = vim.json.decode(vim.fn.readfile(dir .. '/log.jsonl')[1])
  assert.equals(tomb.moved_to, 'events/', 'log.jsonl is the tombstone')
  assert.equals(tomb.log_id, v2_header.log_id, 'of the v2 log')
  assert.length(vim.fn.readfile(dir .. '/log.jsonl'), 1, 'and nothing else')
  assert.falsy(uv.fs_stat(dir .. '/state.json'), 'state.json is gone')
  assert.falsy(uv.fs_stat(dir .. '/log.1000.jsonl'), 'rotated names are gone')
  assert.falsy(uv.fs_stat(dir .. '/log.2000.jsonl'), 'rotated names are gone')
  assert.length(vim.fn.glob(dir .. '/checkpoints/*.json', true, true), 1, 'the first checkpoint')

  -- Changes go to segment 4; a stray state.json is deleted on load
  assert.truthy(store.add({ filename = abs, lnum = 1, kind = 'note', body = 'after' }), 'added')
  assert.length(test_helper.log_ops(dir .. '/events/000004.jsonl', 'add'), 1, 'in segment 4')
  vim.fn.writefile({ '{"v":2}' }, dir .. '/state.json')
  local ids5 = ids_of(store.all())
  _, store = restart({ storage_dir = dir })
  assert.equals(ids_of(store.all()), ids5, 'the same after a restart')
  assert.falsy(uv.fs_stat(dir .. '/state.json'), 'the stray state.json is deleted')
  _, store = restart({ storage_dir = dir })
  vim.fn.delete(dir .. '/checkpoints', 'rf')
  _, store = restart({ storage_dir = dir })
  assert.equals(ids_of(store.all()), ids5, 'the same replayed without checkpoints')
  vim.fn.delete(dir, 'rf')
end)

assert.run_test('a migration crashed after step 3 is redone at the next load; the v2 bytes are unchanged', function()
  local dir = vim.fn.tempname() .. '-crash'
  vim.fn.mkdir(dir, 'p')
  local ids = write_v2(dir .. '/log.jsonl')
  local sha = vim.fn.sha256(read_bytes(dir .. '/log.jsonl'))
  local log_ino = ino(dir .. '/log.jsonl')
  local store
  capture_notify(function() qf, store = restart_hooked({ storage_dir = dir }, { crash_after = 3 }) end)
  assert.truthy(uv.fs_stat(dir .. '/events/000004.jsonl'), 'half built: segment 4 created')
  assert.equals(vim.fn.sha256(read_bytes(dir .. '/log.jsonl')), sha, 'log.jsonl unchanged')
  assert.falsy(read_bytes(dir .. '/log.jsonl'):find('moved_to', 1, true), 'no tombstone')
  assert.equals(ids_of(store.all()), table.concat(ids, ','), 'read as v2 meanwhile')
  _, store = restart({ storage_dir = dir })
  assert.equals(ids_of(store.all()), table.concat(ids, ','), 'the same comments')
  assert.equals(vim.fn.sha256(read_bytes(dir .. '/events/000003.jsonl')), sha, 'segment 3 holds the v2 bytes')
  assert.equals(ino(dir .. '/events/000003.jsonl'), log_ino, 'the same file')
  assert.length(test_helper.segments_of(dir .. '/log.jsonl'), 4, 'four segments, no leftover')
  assert.truthy(log.is_tombstone(vim.json.decode(vim.fn.readfile(dir .. '/log.jsonl')[1])), 'now the tombstone')
  vim.fn.delete(dir, 'rf')
end)

assert.run_test('a migration that does not verify leaves v2 authoritative, with one warning', function()
  local dir = vim.fn.tempname() .. '-mismatch'
  vim.fn.mkdir(dir, 'p')
  local ids = write_v2(dir .. '/log.jsonl')
  local before = read_bytes(dir .. '/log.jsonl')
  local store
  local calls = capture_notify(function()
    qf, store = restart_hooked({ storage_dir = dir }, { mismatch = true })
    store.all()
    store.all()
  end)
  local warned = {}
  for _, c in ipairs(calls) do
    if tostring(c.msg):find('could not migrate', 1, true) then table.insert(warned, c) end
  end
  assert.length(warned, 1, 'one warning: ' .. vim.inspect(calls))
  assert.equals(warned[1].level, vim.log.levels.WARN, 'a WARN')
  assert.equals(read_bytes(dir .. '/log.jsonl'), before, 'log.jsonl unchanged')
  assert.falsy(uv.fs_stat(dir .. '/events'), 'the half-built journal is removed')
  assert.falsy(uv.fs_stat(dir .. '/checkpoints'), 'no checkpoints')
  assert.equals(ids_of(store.all()), table.concat(ids, ','), 'read as v2')
  calls = capture_notify(function()
    assert.truthy(store.add({ filename = abs, lnum = 1, kind = 'note', body = 'v2 still' }), 'written as v2')
  end)
  assert.length(calls, 0, 'no further warning this session: ' .. vim.inspect(calls))
  assert.truthy(read_bytes(dir .. '/log.jsonl'):find('v2 still', 1, true), 'appended to log.jsonl')
  assert.falsy(uv.fs_stat(dir .. '/events'), 'still no journal')
  -- Snapshot GC in v2 mode: log.jsonl's hashes are live
  local snapshots = require('quickfix-review.snapshots')
  local named = snapshots.put({ 'named by log.jsonl only' })
  assert.truthy(store.add({ filename = abs, lnum = 1, kind = 'note', body = 'anchored',
    anchor = { sha = named, lnum = 1, end_lnum = 1 } }), 'anchored, as v2')
  local anchored_id
  for _, c in ipairs(store.all()) do
    if c.body == 'anchored' then anchored_id = c.id end
  end
  assert.equals(store.remove(anchored_id), 1, 'removed: only log.jsonl names it')
  local orphan = snapshots.put({ 'orphan' })
  local day_ago = os.time() - 25 * 3600
  for _, sha in ipairs({ named, orphan }) do uv.fs_utime(dir .. '/snapshots/' .. sha, day_ago, day_ago) end
  assert.equals(store.gc_snapshots(), 1, 'one collected')
  assert.truthy(uv.fs_stat(dir .. '/snapshots/' .. named), 'named by the v2 log: kept')
  assert.falsy(uv.fs_stat(dir .. '/snapshots/' .. orphan), 'the unreferenced one deleted')
  -- The next session migrates it
  _, store = restart({ storage_dir = dir })
  assert.length(store.all(), 5, 'migrated with the new comment')
  assert.truthy(log.is_tombstone(vim.json.decode(vim.fn.readfile(dir .. '/log.jsonl')[1])), 'migrated')
  vim.fn.delete(dir, 'rf')
end)

-- A v2 review whose migration did not verify, loaded in v2 fallback mode
-- (rotated logs log.1000 and log.2000, then log.jsonl; see write_v2).
-- Returns: dir, the 4 comment ids, store
local function v2_fallback(suffix)
  local dir = vim.fn.tempname() .. suffix
  vim.fn.mkdir(dir, 'p')
  local ids = write_v2(dir .. '/log.jsonl')
  local store
  capture_notify(function() qf, store = restart_hooked({ storage_dir = dir }, { mismatch = true }) end)
  assert.falsy(uv.fs_stat(dir .. '/events'), 'in v2 fallback mode')
  assert.equals(ids_of(store.all()), table.concat(ids, ','), 'read as v2')
  return dir, ids, store
end

assert.run_test('v2 fallback: history covers the rotated logs, oldest first, then log.jsonl', function()
  local dir, ids = v2_fallback('-fallback-history')
  local history_view = require('quickfix-review.history_view')
  local rows = history_view.history_rows()
  local got = {}
  for i, row in ipairs(rows) do got[i] = row.op .. ':' .. tostring(row.id) end
  local want = {}
  for i, id in ipairs(ids) do want[i] = 'add:' .. id end
  assert.equals(table.concat(got, ','), table.concat(want, ','), 'the adds of all three logs, in order')
  local first = history_view.history_rows(ids[1])
  assert.length(first, 1, 'the first comment\'s history, from log.1000')
  assert.equals(first[1].op, 'add', 'its add')
  vim.fn.delete(dir, 'rf')
end)

assert.run_test('v2 fallback: log.jsonl rewritten in place with another log_id is reloaded from the start', function()
  local dir, ids, store = v2_fallback('-fallback-logid')
  local log_file = dir .. '/log.jsonl'
  local old = read_bytes(log_file)
  local inode = ino(log_file)

  -- A new header log_id and other bodies, all of the same length, so the
  -- size and inode are what was read
  local old_id = old:match('"log_id":"(%x+)"')
  local new_id = log.v2_header().log_id
  assert.equals(#new_id, #old_id, 'log_ids of one length')
  local new = old:gsub(old_id, new_id, 1):gsub('"body":"([^"]*)"', function(b)
    return '"body":"' .. string.rep('z', #b) .. '"'
  end)
  assert.equals(#new, #old, 'same size')
  local fh = io.open(log_file, 'r+b')
  fh:write(new)
  fh:close()
  assert.equals(ino(log_file), inode, 'same inode')

  local list = store.all()
  assert.equals(ids_of(list), table.concat(ids, ','), 'the same comments')
  for n, c in ipairs(list) do
    assert.truthy(c.body:match('^z+$'), 'comment ' .. n .. ' from the rewritten log: ' .. c.body)
  end
  assert.falsy(uv.fs_stat(dir .. '/events'), 'still v2')
  vim.fn.delete(dir, 'rf')
end)

assert.run_test('v2 fallback: log.jsonl rewritten in place leaving the offset mid-line is reloaded from the start', function()
  local dir, ids, store = v2_fallback('-fallback-midline')
  local log_file = dir .. '/log.jsonl'
  local old = read_bytes(log_file)
  local inode = ino(log_file)

  -- Same header (and log_id), same inode; a body in the checkpoint grows,
  -- so the old end of the log now falls inside a later line, and a new
  -- add makes the file longer than what was read
  local lines = vim.split(old, '\n', { plain = true, trimempty = true })
  assert.length(lines, 3, 'header, checkpoint and one add')
  local grown = lines[2]:gsub('"body":"([^"]*)"', function(b) return '"body":"' .. b .. 'grown"' end, 1)
  local extra = vim.json.decode(lines[3])
  extra.eid = extra.eid .. 'x'
  extra.comment.id = string.rep('f', #extra.comment.id)
  extra.comment.body = 'extra'
  local new = table.concat({ lines[1], grown, lines[3], vim.json.encode(extra) }, '\n') .. '\n'
  assert.truthy(#new > #old, 'longer than before')
  assert.truthy(new:sub(#old, #old) ~= '\n', 'the old offset is mid-line now')
  local fh = io.open(log_file, 'r+b')
  fh:write(new)
  fh:close()
  assert.equals(ino(log_file), inode, 'same inode')

  local list
  local calls = capture_notify(function() list = store.all() end)
  assert.equals(ids_of(list), table.concat(ids, ',') .. ',' .. extra.comment.id, 'the comments and the new one')
  assert.equals(list[1].body, 'c1grown', 'the rewritten first comment')
  assert.equals(list[5].body, 'extra', 'the new comment')
  assert.length(calls, 0, 'no unreadable-line warning from a mid-line read: ' .. vim.inspect(calls))
  vim.fn.delete(dir, 'rf')
end)

assert.run_test('two storage_files in one dir migrate and run independently', function()
  local dir = vim.fn.tempname() .. '-two'
  vim.fn.mkdir(dir, 'p')
  local a, b = dir .. '/a.json', dir .. '/b.json'
  local ids_a = write_v2(a .. '.log.jsonl')
  local ids_b = write_v2(b .. '.log.jsonl')
  local b_bytes = read_bytes(b .. '.log.jsonl')
  local store
  _, store = restart({ storage_file = a })
  assert.equals(ids_of(store.all()), table.concat(ids_a, ','), 'a migrated')
  assert.length(test_helper.segments_of(a .. '.log.jsonl'), 4, 'a has four segments')
  assert.equals(read_bytes(b .. '.log.jsonl'), b_bytes, 'b untouched')
  assert.truthy(uv.fs_stat(b .. '.log.1000.jsonl'), 'b\'s rotated logs untouched')
  assert.falsy(uv.fs_stat(b .. '.events'), 'b not migrated')
  assert.truthy(store.add({ filename = abs, lnum = 1, kind = 'note', body = 'only a' }), 'added to a')
  _, store = restart({ storage_file = b })
  assert.equals(ids_of(store.all()), table.concat(ids_b, ','), 'b migrated, without a\'s comment')
  assert.length(test_helper.segments_of(b .. '.log.jsonl'), 4, 'b has four segments')
  assert.length(test_helper.segments_of(a .. '.log.jsonl'), 4, 'a still has four')
  local ja = vim.json.decode(vim.fn.readfile(a .. '.events/000004.jsonl')[1]).journal_id
  local jb = vim.json.decode(vim.fn.readfile(b .. '.events/000004.jsonl')[1]).journal_id
  assert.truthy(ja ~= jb, 'two journals')
  _, store = restart({ storage_file = a })
  assert.length(store.all(), 5, 'a keeps its own comment')
  -- Snapshot GC from a leaves b's snapshots alone; each has its own stamp
  local snapshots = require('quickfix-review.snapshots')
  local day_ago = os.time() - 25 * 3600
  local orphan_a = snapshots.put({ 'orphan of a' })
  uv.fs_utime(a .. '.snapshots/' .. orphan_a, day_ago, day_ago)
  _, store = restart({ storage_file = b })
  snapshots = require('quickfix-review.snapshots')
  local only_b = snapshots.put({ 'only b names it' })
  assert.truthy(store.add({ filename = abs, lnum = 1, kind = 'note', body = 'b anchored',
    anchor = { sha = only_b, lnum = 1, end_lnum = 1 } }), 'anchored in b')
  uv.fs_utime(b .. '.snapshots/' .. only_b, day_ago, day_ago)
  _, store = restart({ storage_file = a })
  assert.equals(store.gc_snapshots(), 1, 'a\'s orphan collected')
  assert.falsy(uv.fs_stat(a .. '.snapshots/' .. orphan_a), 'a\'s orphan deleted')
  assert.truthy(uv.fs_stat(b .. '.snapshots/' .. only_b), 'b\'s snapshot kept')
  assert.truthy(uv.fs_stat(a .. '.snapshots/gc.stamp'), 'a has its stamp')
  assert.falsy(uv.fs_stat(b .. '.snapshots/gc.stamp'), 'b has none yet')
  _, store = restart({ storage_file = b })
  assert.equals(store.gc_snapshots(), 0, 'b: nothing to collect')
  assert.truthy(uv.fs_stat(b .. '.snapshots/' .. only_b), 'b\'s snapshot kept by b\'s GC')
  assert.truthy(uv.fs_stat(b .. '.snapshots/gc.stamp'), 'b has its stamp')
  vim.fn.delete(dir, 'rf')
end)

assert.run_test('snapshot GC keeps what a stray v2 log.jsonl beside a v3 journal names', function()
  local dir = vim.fn.tempname() .. '-stray'
  vim.fn.mkdir(dir, 'p')
  local store
  _, store = restart({ storage_dir = dir })
  assert.truthy(store.add({ filename = abs, lnum = 1, kind = 'note', body = 'v3' }), 'a born-v3 review')
  assert.truthy(uv.fs_stat(dir .. '/events/000001.jsonl'), 'with a journal')
  local snapshots = require('quickfix-review.snapshots')
  local stray = snapshots.put({ 'named by the stray log' })
  local orphan = snapshots.put({ 'orphan' })
  local day_ago = os.time() - 25 * 3600
  for _, sha in ipairs({ stray, orphan }) do uv.fs_utime(dir .. '/snapshots/' .. sha, day_ago, day_ago) end
  -- An old Neovim's v2 log.jsonl, naming a snapshot. A review born v3 now
  -- has the tombstone, which old code refuses; this is a review born
  -- before that (writefile replaces the tombstone to model it)
  vim.fn.writefile({
    vim.json.encode(log.v2_header()),
    vim.json.encode(log.event('add', { comment = { id = 'x', filename = abs, lnum = 1, kind = 'note', body = 's',
      anchor = { sha = stray, lnum = 1, end_lnum = 1 } } })),
    '',
  }, dir .. '/log.jsonl', 'b')
  assert.equals(store.gc_snapshots(), 1, 'one collected')
  assert.truthy(uv.fs_stat(dir .. '/snapshots/' .. stray), 'named by the stray log: kept')
  assert.falsy(uv.fs_stat(dir .. '/snapshots/' .. orphan), 'the unreferenced one deleted')
  vim.fn.delete(dir, 'rf')
end)

-- A born-v3 review's log.jsonl: the tombstone, so a pre-v3 Neovim refuses
-- it as it refuses a migrated review. Pre-v3 code cannot run in-tree, so
-- this asserts the shape old code refuses: the Unknown #1 test above
-- (a lone tombstone is refused), and pre-v3 is_header / too_new (`git show
-- 1bdc598^:lua/quickfix-review/log.lua`), which take a line for a header
-- only when log_id is a non-empty string and refuse one whose v > 2.
local function assert_tombstone(path, what)
  local lines = vim.fn.readfile(path)
  assert.length(lines, 1, what .. ': one line')
  local t = vim.json.decode(lines[1])
  local keys = vim.tbl_keys(t)
  table.sort(keys)
  assert.equals(table.concat(keys, ','), 'log_id,moved_to,op,v', what .. ': a migrated tombstone\'s keys')
  assert.equals(t.op, 'header', what .. ': a header')
  assert.equals(t.v, 3, what .. ': v3')
  assert.equals(t.moved_to, 'events/', what .. ': moved to events/')
  assert.truthy(type(t.log_id) == 'string' and t.log_id ~= '', what .. ': a non-empty log_id')
  return t
end

local function mentioning(calls, text)
  local out = {}
  for _, c in ipairs(calls) do
    if tostring(c.msg):find(text, 1, true) then table.insert(out, c) end
  end
  return out
end

assert.run_test('a born-v3 review writes the tombstone log.jsonl, with the shape of a migrated one', function()
  local dir = vim.fn.tempname() .. '-born'
  vim.fn.mkdir(dir, 'p')
  local store
  _, store = restart({ storage_dir = dir })
  assert.falsy(uv.fs_stat(dir .. '/log.jsonl'), 'no log.jsonl before the review starts')
  assert.truthy(store.add({ filename = abs, lnum = 1, kind = 'note', body = 'one' }), 'added')
  local t = assert_tombstone(dir .. '/log.jsonl', 'born-v3')
  local h1 = vim.json.decode(vim.fn.readfile(dir .. '/events/000001.jsonl')[1])
  assert.equals(t.log_id, h1.journal_id, 'log_id is the journal\'s id')
  local bytes = read_bytes(dir .. '/log.jsonl')
  local calls = capture_notify(function()
    _, store = restart({ storage_dir = dir })
    assert.truthy(store.add({ filename = abs, lnum = 2, kind = 'note', body = 'two' }), 'added after a restart')
  end)
  assert.length(store.all(), 2, 'both comments')
  assert.length(mentioning(calls, 'which is missing'), 0, 'not refused')
  assert.length(mentioning(calls, 'is a v2 log beside'), 0, 'no stray-v2 notice')
  assert.equals(read_bytes(dir .. '/log.jsonl'), bytes, 'the tombstone is unchanged')
  vim.fn.delete(dir, 'rf')
end)

assert.run_test('two storage_files in one dir each get their own tombstone', function()
  local dir = vim.fn.tempname() .. '-two-born'
  vim.fn.mkdir(dir, 'p')
  local a, b = dir .. '/a.json', dir .. '/b.json'
  local store
  _, store = restart({ storage_file = a })
  assert.truthy(store.add({ filename = abs, lnum = 1, kind = 'note', body = 'a' }), 'added to a')
  _, store = restart({ storage_file = b })
  assert.truthy(store.add({ filename = abs, lnum = 1, kind = 'note', body = 'b' }), 'added to b')
  local ta = assert_tombstone(a .. '.log.jsonl', 'a')
  local tb = assert_tombstone(b .. '.log.jsonl', 'b')
  assert.truthy(ta.log_id ~= tb.log_id, 'each its own id')
  assert.falsy(uv.fs_stat(dir .. '/log.jsonl'), 'no <dir>/log.jsonl')
  vim.fn.delete(dir, 'rf')
end)

assert.run_test('a born-v3 review with no log.jsonl gets its tombstone on the next load', function()
  local dir = vim.fn.tempname() .. '-backfill'
  vim.fn.mkdir(dir, 'p')
  local store
  _, store = restart({ storage_dir = dir })
  assert.truthy(store.add({ filename = abs, lnum = 1, kind = 'note', body = 'one' }), 'added')
  vim.fn.setfperm(dir .. '/events/000001.jsonl', 'rw-------')
  local jid = vim.json.decode(vim.fn.readfile(dir .. '/events/000001.jsonl')[1]).journal_id
  os.remove(dir .. '/log.jsonl')
  _, store = restart({ storage_dir = dir })
  assert.length(store.all(), 1, 'loaded')
  local t = assert_tombstone(dir .. '/log.jsonl', 'backfilled')
  assert.equals(t.log_id, jid, 'with the journal\'s id')
  assert.equals(vim.fn.getfperm(dir .. '/log.jsonl'), 'rw-------', 'with segment 1\'s mode')
  vim.fn.delete(dir, 'rf')
end)

assert.run_test('a v2 log.jsonl beside a born-v3 journal is never replaced by the tombstone', function()
  local dir = vim.fn.tempname() .. '-noclobber'
  vim.fn.mkdir(dir, 'p')
  local store
  _, store = restart({ storage_dir = dir })
  assert.truthy(store.add({ filename = abs, lnum = 1, kind = 'note', body = 'v3' }), 'added')
  -- An old Neovim's v2 log, written while this review had no tombstone
  os.remove(dir .. '/log.jsonl')
  vim.fn.writefile({ vim.json.encode(log.v2_header()), '' }, dir .. '/log.jsonl', 'b')
  local bytes = read_bytes(dir .. '/log.jsonl')
  local calls = capture_notify(function()
    _, store = restart({ storage_dir = dir })
    assert.truthy(store.add({ filename = abs, lnum = 2, kind = 'note', body = 'v3 again' }), 'added')
  end)
  assert.length(store.all(), 2, 'the journal is the review')
  assert.equals(read_bytes(dir .. '/log.jsonl'), bytes, 'the v2 log is unchanged')
  assert.length(mentioning(calls, 'is a v2 log beside'), 1, 'the stray-v2 warning')
  -- And the exclusive create itself leaves an existing file alone
  local journal = require('quickfix-review.store.journal')
  local loc = { log = dir .. '/log.jsonl', events = dir .. '/events' }
  assert.equals(journal.write_tombstone(loc, 'ffffffffffffffff', 420), 'exists', 'exists')
  assert.equals(read_bytes(dir .. '/log.jsonl'), bytes, 'still unchanged')
  vim.fn.delete(dir, 'rf')
end)

assert.run_test('no tombstone is written when segment 1 is not created', function()
  local dir = vim.fn.tempname() .. '-noseg'
  vim.fn.mkdir(dir, 'p')
  local store
  _, store = restart({ storage_dir = dir })
  local segment = require('quickfix-review.store.segment')
  local original = segment.create
  segment.create = function() return nil, 'ENOSPC (test)' end
  local ok, err = pcall(function()
    capture_notify(function()
      assert.falsy(store.add({ filename = abs, lnum = 1, kind = 'note', body = 'x' }), 'the add refused')
    end)
  end)
  segment.create = original
  if not ok then error(err, 0) end
  assert.falsy(uv.fs_stat(dir .. '/events/000001.jsonl'), 'no segment 1')
  assert.falsy(uv.fs_stat(dir .. '/log.jsonl'), 'no tombstone')
  vim.fn.delete(dir, 'rf')
end)

-- The step-7 cleanup deletes rotated logs because a migration hard-linked
-- them into events/. Beside a born-v3 tombstone they were never imported:
-- they are kept
assert.run_test('opening a born-v3 review keeps a rotated log beside its tombstone', function()
  local dir = vim.fn.tempname() .. '-born-rotated'
  vim.fn.mkdir(dir, 'p')
  local store
  _, store = restart({ storage_dir = dir })
  assert.truthy(store.add({ filename = abs, lnum = 1, kind = 'note', body = 'one' }), 'added')
  assert_tombstone(dir .. '/log.jsonl', 'born-v3')
  local rotated = dir .. '/log.1700000000000.jsonl'
  vim.fn.writefile({ vim.json.encode(log.v2_header()), '' }, rotated, 'b')
  local maintenance = require('quickfix-review.store.maintenance')
  local listed = maintenance.list_rotated({ log = dir .. '/log.jsonl' })
  assert.length(listed, 1, 'named as a rotated log')
  local bytes = read_bytes(rotated)
  _, store = restart({ storage_dir = dir })
  assert.length(store.all(), 1, 'loaded')
  assert.equals(read_bytes(rotated), bytes, 'the rotated log is kept')
  vim.fn.delete(dir, 'rf')
end)

assert.run_test('reduce: a checkpoint event applies only in segment 1', function()
  local reduce = require('quickfix-review.reduce')
  local s = reduce.new()
  local ev = { op = 'checkpoint', state = { comments = {}, trash = {}, removed = {} } }
  local _, why = reduce.apply_in_segment(s, 2, ev)
  assert.equals(why, 'superseded', 'skipped in a later segment')
  _, why = reduce.apply_in_segment(s, 1, ev)
  assert.equals(why, nil, 'applied in segment 1')
end)

qf = restart()
test_helper.setup_test_environment()
test_helper.cleanup_test_environment()

return assert
