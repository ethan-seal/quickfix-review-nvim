-- Tests for the v3 journal's segments and checkpoints (docs/journal.md):
-- sealing a full segment, checkpoint GC, loading from (or without)
-- checkpoints, history across segments, and snapshot GC over segments
local test_helper = dofile('test/init.lua')
local assert = dofile('test/assertions.lua')

print('\nRunning journal segment and checkpoint tests...')

local qf = test_helper.setup_test_environment()
local test_file = test_helper.create_test_file([[
line 1
line 2
line 3
line 4
line 5
]])
local abs = vim.fn.fnamemodify(test_file, ':p')
local storage_file = test_helper.storage_file
local events = test_helper.events_path()
local checkpoints = test_helper.checkpoints_path()
local uv = vim.uv or vim.loop

-- Simulate quitting and reopening Neovim with these options. Quitting
-- writes a checkpoint, unless no_flush.
local function restart(opts, no_flush)
  if not no_flush and package.loaded['quickfix-review.store'] then
    package.loaded['quickfix-review.store'].flush()
  end
  for name, _ in pairs(package.loaded) do
    if name:match('^quickfix%-review') then package.loaded[name] = nil end
  end
  qf = require('quickfix-review')
  opts = opts or {}
  if opts.storage_dir == nil then opts.storage_file = opts.storage_file or storage_file end
  qf.setup(opts)
  return qf, require('quickfix-review.store')
end

local function reset(opts)
  vim.fn.setqflist({}, 'f')
  test_helper.remove_storage()
  qf, _ = restart(opts, true)
  qf.clear_review()
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

local function mentioning(calls, text)
  local found = {}
  for _, c in ipairs(calls) do
    if tostring(c.msg):find(text, 1, true) then table.insert(found, c) end
  end
  return found
end

local function read_bytes(path)
  local fh = io.open(path, 'rb')
  if not fh then return nil end
  local data = fh:read('*a')
  fh:close()
  return data
end

local function ids_of(list)
  local out = {}
  for i, c in ipairs(list) do out[i] = c.id end
  return table.concat(out, ',')
end

local function add_at(lnum, kind)
  vim.fn.cursor(lnum, 1)
  qf.add_comment(kind or 'NOTE')
end

local function segs() return test_helper.segments_of(test_helper.log_path()) end

local function inodes()
  local out = {}
  for _, s in ipairs(segs()) do out[s.n] = uv.fs_stat(s.path).ino end
  return out
end

assert.run_test('defaults: 4 MiB segments, a checkpoint every 500 events, 2 kept; nothing seals below', function()
  local config = require('quickfix-review.config')
  assert.equals(config.defaults.segment_max_bytes, 4 * 1024 * 1024, 'segment_max_bytes')
  assert.equals(config.defaults.checkpoint_every, 500, 'checkpoint_every')
  assert.equals(config.defaults.checkpoint_keep, 2, 'checkpoint_keep')
  reset()
  for l = 1, 3 do add_at(l) end
  assert.length(segs(), 1, 'one segment')
  assert.equals(test_helper.log_records(test_helper.log_path())[1].op, 'header', 'it starts with its header')
  assert.equals(vim.fn.filereadable(test_helper.log_path()), 0, 'a new review has no log.jsonl')
end)

assert.run_test('log_max_bytes is an alias of segment_max_bytes; log_retention_days is ignored, each noted once', function()
  local calls = capture_notify(function()
    restart({ log_max_bytes = 1234, log_retention_days = 3 }, true)
  end)
  local config = require('quickfix-review.config')
  assert.equals(config.options.segment_max_bytes, 1234, 'the alias applies')
  assert.length(mentioning(calls, 'log_max_bytes is deprecated'), 1, 'a deprecation note')
  assert.length(mentioning(calls, 'log_retention_days is ignored'), 1, 'retention is ignored')
  calls = capture_notify(function()
    restart({ segment_max_bytes = -1, checkpoint_every = 'x', checkpoint_keep = 0 }, true)
  end)
  config = require('quickfix-review.config')
  assert.length(calls, 3, 'three warnings: ' .. vim.inspect(calls))
  assert.equals(config.options.segment_max_bytes, config.defaults.segment_max_bytes, 'bad size: default')
  assert.equals(config.options.checkpoint_every, 500, 'bad every: default')
  assert.equals(config.options.checkpoint_keep, 2, 'bad keep: default')
  restart({}, true)
end)

assert.run_test('sealing: N+1 holds only its header, N.refs exists, a checkpoint at (N+1, header end)', function()
  reset()
  local store = require('quickfix-review.store')
  local snapshots = require('quickfix-review.snapshots')
  local sha = snapshots.put({ 'line 1' })
  assert.truthy(store.add({ filename = abs, lnum = 1, kind = 'note', body = 'one',
    anchor = { sha = sha, lnum = 1, end_lnum = 1 } }), 'added')
  local before = inodes()
  local seg1 = read_bytes(test_helper.segment_path(1))
  local ids = ids_of(store.all())

  local store2
  qf, store2 = restart({ segment_max_bytes = 1 }, true)
  assert.truthy(store2.add({ filename = abs, lnum = 2, kind = 'note', body = 'two' }), 'added, sealing')
  local after = segs()
  assert.length(after, 2, 'a second segment')
  assert.equals(uv.fs_stat(test_helper.segment_path(1)).ino, before[1], 'segment 1 keeps its inode')
  local s1 = read_bytes(test_helper.segment_path(1))
  assert.equals(s1:sub(1, #seg1), seg1, 'segment 1 only grew')
  local s2 = read_bytes(test_helper.segment_path(2))
  local lines = vim.split(s2, '\n', { plain = true, trimempty = true })
  assert.length(lines, 1, 'segment 2 holds only its header')
  local h2 = vim.json.decode(lines[1])
  local h1 = vim.json.decode(vim.split(s1, '\n', { plain = true })[1])
  assert.equals(h2.op, 'header', 'a header')
  assert.equals(h2.journal_id, h1.journal_id, 'of the same journal')
  assert.equals(h2.seg, 2, 'numbered')
  local refs = vim.json.decode(read_bytes(events .. '/000001.refs'))
  assert.truthy(vim.tbl_contains(refs, sha), 'segment 1\'s refs name its snapshot: ' .. vim.inspect(refs))
  local cp = checkpoints .. '/' .. string.format('%06d-%012d.json', 2, #s2)
  assert.truthy(uv.fs_stat(cp) ~= nil, 'a checkpoint at the end of segment 2\'s header: ' ..
    vim.inspect(test_helper.checkpoint_files()))
  local doc = vim.json.decode(read_bytes(cp))
  assert.equals(doc.seg, 2, 'its seg')
  assert.equals(doc.offset, #s2, 'its offset')
  assert.equals(doc.state.index, nil, 'no index in it')
  assert.length(doc.state.comments, 2, 'both comments')

  -- The next change lands in segment 2 (and seals it)
  assert.truthy(store2.add({ filename = abs, lnum = 3, kind = 'note', body = 'three' }), 'added')
  assert.equals(uv.fs_stat(test_helper.segment_path(1)).ino, before[1], 'segment 1 still the same file')
  assert.equals(read_bytes(test_helper.segment_path(1)), s1, 'and no longer written')
  assert.length(test_helper.log_ops(test_helper.segment_path(2), 'add'), 1, 'the add went to segment 2')
  local _, store3 = restart({}, true)
  assert.equals(ids_of(store3.all()), ids_of(store2.all()), 'the same after a restart')
  assert.truthy(ids_of(store3.all()):find(ids, 1, true) == 1, 'the first comment first')
  assert.length(test_helper.saved(), 3, 'three comments replayed from the segments')
end)

assert.run_test('checkpoint GC: 5 writes leave 2; temp, corrupt, foreign and past-EOF files are deleted', function()
  reset()
  local store
  qf, store = restart({}, true)
  add_at(1)
  local header = vim.json.decode(vim.fn.readfile(test_helper.segment_path(1))[1])
  vim.fn.mkdir(checkpoints, 'p')
  local size = uv.fs_stat(test_helper.segment_path(1)).size
  local planted = {
    tmp = checkpoints .. '/000001-000000000001.json.tmp.99999',
    corrupt = checkpoints .. '/000009-000000000001.json',
    foreign = checkpoints .. '/000008-000000000001.json',
    past = checkpoints .. '/000007-000000000001.json',
  }
  vim.fn.writefile({ '{"v":3,' }, planted.tmp)
  vim.fn.writefile({ 'not json' }, planted.corrupt)
  vim.fn.writefile({ vim.json.encode({ v = 3, state_v = require('quickfix-review.reduce').STATE_VERSION,
    journal_id = 'ffffffffffffffff', seg = 1, offset = size, lines = 2,
    state = { comments = {}, trash = vim.empty_dict(), removed = {} }, imports = {}, refs = {} }) }, planted.foreign)
  vim.fn.writefile({ vim.json.encode({ v = 3, state_v = require('quickfix-review.reduce').STATE_VERSION,
    journal_id = header.journal_id, seg = 7, offset = 1, lines = 1,
    state = { comments = {}, trash = vim.empty_dict(), removed = {} }, imports = {}, refs = {} }) }, planted.past)
  for i = 1, 5 do
    add_at(i)
    local ok = require('quickfix-review.store.journal').write_checkpoint(require('quickfix-review.store.location').resolve())
    assert.truthy(ok, 'checkpoint ' .. i .. ' written')
  end
  local files = test_helper.checkpoint_files()
  assert.length(files, 2, 'two kept: ' .. vim.inspect(files))
  for what, p in pairs(planted) do
    assert.falsy(uv.fs_stat(p), what .. ' deleted')
  end
  -- The newest two, both of this journal
  local last = uv.fs_stat(test_helper.segment_path(1)).size
  assert.equals(vim.fn.fnamemodify(files[1], ':t'), string.format('%06d-%012d.json', 1, last), 'the newest')
  assert.equals(#store.all(), 6, 'the review is intact')
end)

assert.run_test('loading: without checkpoints the same state; a new STATE_VERSION ignores and rebuilds them', function()
  reset()
  for l = 1, 4 do add_at(l) end
  local store = require('quickfix-review.store')
  store.remove(store.all()[2].id)
  qf, store = restart() -- writes a checkpoint
  local comments, trash, last = store.all(), store.trash(), store.last_removal()
  assert.truthy(test_helper.checkpoint_path() ~= nil, 'a checkpoint written')

  -- A checkpoint is used: an edited body in it shows
  local cp = test_helper.checkpoint_path()
  local doc = vim.json.decode(read_bytes(cp))
  doc.state.comments[1].body = 'from the checkpoint'
  vim.fn.writefile({ vim.json.encode(doc) }, cp)
  qf, store = restart({}, true)
  assert.equals(store.all()[1].body, 'from the checkpoint', 'loaded from the checkpoint')

  vim.fn.delete(checkpoints, 'rf')
  qf, store = restart({}, true)
  assert.truthy(vim.deep_equal(store.all(), comments), 'same comments without checkpoints')
  assert.truthy(vim.deep_equal(store.trash(), trash), 'same trash without checkpoints')
  assert.truthy(vim.deep_equal(store.last_removal(), last), 'same removals without checkpoints')

  -- Checkpoints of another state version are ignored, then replaced
  qf, store = restart() -- no events read past a checkpoint: none written
  store.save()
  local old = test_helper.checkpoint_path()
  doc = vim.json.decode(read_bytes(old))
  doc.state.comments[1].body = 'stale checkpoint'
  vim.fn.writefile({ vim.json.encode(doc) }, old)
  local reduce = require('quickfix-review.reduce')
  local saved_version = reduce.STATE_VERSION
  for name, _ in pairs(package.loaded) do
    if name:match('^quickfix%-review') then package.loaded[name] = nil end
  end
  reduce = require('quickfix-review.reduce')
  reduce.STATE_VERSION = saved_version + 1
  qf = require('quickfix-review')
  qf.setup({ storage_file = storage_file })
  store = require('quickfix-review.store')
  assert.truthy(vim.deep_equal(store.all(), comments), 'the old checkpoint is ignored')
  assert.truthy(store.save(), 'saved')
  local files = test_helper.checkpoint_files()
  assert.length(files, 1, 'rebuilt, the old one deleted: ' .. vim.inspect(files))
  assert.equals(vim.json.decode(read_bytes(files[1])).state_v, saved_version + 1, 'at the new version')
  reduce.STATE_VERSION = saved_version
  qf, store = restart({}, true)
end)

assert.run_test('history reads back across segments', function()
  reset()
  local store
  qf, store = restart({ segment_max_bytes = 1 }, true)
  add_at(1)
  local id = store.all()[1].id
  assert.equals(store.edit(id, 'edited'), 'edited', 'edited')
  add_at(2)
  assert.truthy(#segs() >= 3, 'several segments')
  local rows = qf.history_rows(id)
  local ops = {}
  for i, r in ipairs(rows) do ops[i] = r.op end
  assert.equals(table.concat(ops, ','), 'add,update', 'the comment\'s events, from both segments')
  assert.length(qf.history_rows(), 3, 'every event')
end)

assert.run_test('two Neovims appending while sealing lose and duplicate nothing', function()
  local file = vim.fn.tempname() .. '-sealing.json'
  local script = vim.fn.tempname() .. '-writer.lua'
  vim.fn.writefile({
    'local who = ...',
    string.format('require("quickfix-review").setup({ storage_file = %q, segment_max_bytes = 3000,', file),
    '  checkpoint_every = 7 })',
    'local store = require("quickfix-review.store")',
    'local ok = 0',
    'for i = 1, 50 do',
    string.format('  if store.add({ filename = %q, lnum = 1, kind = "note",', abs),
    '    body = who .. " " .. i .. " " .. string.rep("x", 100) }) then ok = ok + 1 end',
    'end',
    'if ok ~= 50 then io.stderr:write("only " .. ok .. " adds succeeded\\n") vim.cmd("cquit 3") end',
  }, script)
  local function writer(who)
    return vim.system({
      vim.v.progpath, '--headless', '--clean',
      '--cmd', 'set rtp^=' .. vim.fn.getcwd(),
      '-c', string.format('lua assert(loadfile(%q))(%q)', script, who),
      '-c', 'qall!',
    })
  end
  local one, two = writer('one'), writer('two')
  local r1, r2 = one:wait(60000), two:wait(60000)
  local ok, err = pcall(function()
    assert.equals(r1.code, 0, 'writer one exits cleanly: ' .. tostring(r1.stderr))
    assert.equals(r2.code, 0, 'writer two exits cleanly: ' .. tostring(r2.stderr))
    local list = test_helper.segments_of(test_helper.log_path(file))
    assert.truthy(#list >= 3, 'sealed several times: ' .. #list)
    local eids, adds, journal_id = {}, { one = 0, two = 0 }, nil
    for i, s in ipairs(list) do
      assert.equals(s.n, i, 'no gap')
      local records = test_helper.log_records(s.path)
      assert.equals(records[1].op, 'header', s.path .. ' starts with a header')
      journal_id = journal_id or records[1].journal_id
      assert.equals(records[1].journal_id, journal_id, 'one journal')
      for j = 2, #records do
        local ev = records[j]
        assert.equals(ev.op, 'add', 'an add')
        assert.falsy(eids[ev.eid], 'eid ' .. tostring(ev.eid) .. ' logged once')
        eids[ev.eid] = true
        adds[ev.comment.body:match('^(%a+) ')] = adds[ev.comment.body:match('^(%a+) ')] + 1
      end
    end
    assert.equals(adds.one, 50, 'every add of writer one, once')
    assert.equals(adds.two, 50, 'every add of writer two, once')
    assert.length(test_helper.saved(test_helper.log_path(file)), 100, '100 live comments')
    local cps = test_helper.checkpoint_files(file)
    assert.truthy(#cps >= 1 and #cps <= 2, 'at most 2 checkpoints: ' .. #cps)
    assert.length(vim.fn.glob(test_helper.checkpoints_path(file) .. '/*.tmp.*', true, true), 0, 'no temp file')
    assert.falsy(require('quickfix-review.store.lock').held(test_helper.flock_path(file)), 'no lock left behind')
  end)
  test_helper.remove_storage(file)
  os.remove(script)
  if not ok then error(err, 0) end
end)

assert.run_test('snapshot GC reads sealed segments outside the lock and keeps what any segment names', function()
  reset()
  local store = require('quickfix-review.store')
  local snapshots = require('quickfix-review.snapshots')
  local day_ago = os.time() - 25 * 3600
  local snap_dir = storage_file .. '.snapshots'
  local function path(sha) return snap_dir .. '/' .. sha end

  local named = snapshots.put({ 'named' })
  assert.truthy(store.add({ filename = abs, lnum = 1, kind = 'note', body = 'n',
    anchor = { sha = named, lnum = 1, end_lnum = 1 } }), 'added')
  assert.equals(store.remove(store.all()[1].id), 1, 'deleted: only segment 1 names it')
  qf, store = restart({ segment_max_bytes = 1 }, true)
  add_at(2)
  add_at(3)
  assert.truthy(#segs() >= 3, 'sealed')
  local old = snapshots.put({ 'old' })
  for _, sha in ipairs({ named, old }) do uv.fs_utime(path(sha), day_ago, day_ago) end

  local lock = require('quickfix-review.store.lock')
  local original_lock, original_open = lock.with_lock, io.open
  local in_lock, opened = false, {}
  lock.with_lock = function(loc, fn)
    return original_lock(loc, function(...)
      in_lock = true
      local res = vim.F.pack_len(pcall(fn, ...))
      in_lock = false
      if not res[1] then error(res[2], 0) end
      return unpack(res, 2, res.n)
    end)
  end
  io.open = function(file, ...)
    if in_lock then table.insert(opened, vim.fn.fnamemodify(file, ':p')) end
    return original_open(file, ...)
  end
  local ok, removed = pcall(store.gc_snapshots)
  lock.with_lock, io.open = original_lock, original_open
  assert.truthy(ok, 'gc ran: ' .. tostring(removed))
  assert.equals(removed, 1, 'one snapshot collected')
  assert.falsy(uv.fs_stat(path(old)), 'unreferenced old deleted')
  assert.truthy(uv.fs_stat(path(named)), 'named by sealed segment 1: kept')
  local under_lock = {}
  for _, f in ipairs(opened) do under_lock[f] = true end
  local list = segs()
  assert.truthy(under_lock[vim.fn.fnamemodify(list[#list].path, ':p')], 'the active segment is read under the lock')
  for i = 1, #list - 1 do
    assert.falsy(under_lock[vim.fn.fnamemodify(list[i].path, ':p')], 'not read under the lock: ' .. list[i].path)
  end
end)

assert.run_test('a segment from a newer version is refused, not shown empty', function()
  local log = require('quickfix-review.log')
  assert.equals(log.VERSION, 3, 'the journal format is v3')
  reset()
  add_at(1)
  local store
  qf, store = restart() -- a checkpoint for this journal
  local seg = test_helper.segment_path(1)
  local lines = vim.fn.readfile(seg, 'b')
  local header = vim.json.decode(lines[1])
  assert.equals(header.v, 3, 'new segments are v3')
  header.v = 4
  lines[1] = vim.json.encode(header)
  vim.fn.writefile(lines, seg, 'b')
  local bytes = read_bytes(seg)
  local calls = capture_notify(function()
    qf, store = restart({}, true)
    store.all()
    assert.falsy(store.add({ filename = abs, lnum = 2, kind = 'note', body = 'x' }), 'add refused')
  end)
  local errors = mentioning(calls, 'newer version')
  assert.truthy(#errors >= 1, 'an error: ' .. vim.inspect(calls))
  assert.equals(errors[1].level, vim.log.levels.ERROR, 'an ERROR')
  assert.truthy(errors[1].msg:find('upgrade', 1, true), 'says to upgrade')
  assert.equals(read_bytes(seg), bytes, 'the segment is unchanged')
  assert.length(segs(), 1, 'no segment added')
end)

test_helper.remove_storage()
qf = restart({}, true)
test_helper.cleanup_test_environment()

return assert
