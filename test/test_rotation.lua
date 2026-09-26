-- Tests for log rotation: a log grown past log_max_bytes is carried into a
-- new log as a checkpoint, the old one kept as log.<ms>.jsonl, and rotated
-- logs older than log_retention_days deleted
local test_helper = dofile('test/init.lua')
local assert = dofile('test/assertions.lua')

print('\nRunning log rotation tests...')

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
local log_file = test_helper.log_path()
local uv = vim.uv or vim.loop
local original_data_home = vim.env.XDG_DATA_HOME

-- Simulate quitting and reopening Neovim with these options (storage_file
-- is the test's unless opts.storage_dir is given). Quitting writes the
-- cache, unless no_flush.
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

local function reset()
  vim.fn.setqflist({}, 'f')
  test_helper.remove_storage()
  qf, _ = restart({}, true)
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

local function rotated(file)
  return vim.fn.glob((file or storage_file) .. '.log.*.jsonl', true, true)
end

local function ids_of(list)
  local out = {}
  for i, c in ipairs(list) do out[i] = c.id end
  return table.concat(out, ',')
end

local function trash_ids(list)
  local out = {}
  for i, t in ipairs(list) do out[i] = t.id end
  return table.concat(out, ',')
end

local function add_at(lnum, kind)
  vim.fn.cursor(lnum, 1)
  qf.add_comment(kind or 'NOTE')
end

assert.run_test('defaults: 5 MB, keep rotated logs; nothing rotates below the limit', function()
  reset()
  local config = require('quickfix-review.config')
  assert.equals(config.options.log_max_bytes, 5 * 1024 * 1024, 'log_max_bytes')
  assert.equals(config.options.log_retention_days, nil, 'log_retention_days')
  add_at(1)
  add_at(2)
  assert.length(rotated(), 0, 'not rotated')
end)

assert.run_test('rotation keeps the state and the trash, and the new log is a checkpoint', function()
  reset()
  add_at(1, 'ISSUE')
  add_at(2)
  add_at(3)
  add_at(4)
  qf.delete_comment({ 2, 2 })
  local store = require('quickfix-review.store')
  local keep = store.all()[3].id
  store.remove_if(function(c) return c.id ~= keep end) -- two deletes
  qf.clear_review() -- then a clear of the last one
  add_at(5, 'ISSUE')
  local before = {
    all = ids_of(store.all()), trash = vim.tbl_keys(store.trash()),
    list = trash_ids(store.trash_list()), last = table.concat(store.last_removal().ids, ','),
  }
  table.sort(before.trash)
  local old_log = vim.fn.readfile(log_file)

  -- A tiny limit: the next change rotates
  qf, store = restart({ log_max_bytes = 1 })
  add_at(1, 'PRAISE')
  local files = rotated()
  assert.length(files, 1, 'one rotated log')
  assert.matches(files[1], '%.log%.%d+%.jsonl$', 'named <log>.<ms>.jsonl')
  local kept = vim.fn.readfile(files[1])
  assert.equals(#kept, #old_log + 1, 'the rotated log is the old one and the change')
  assert.equals(kept[1], old_log[1], 'with its header')
  local records = test_helper.log_records(log_file)
  assert.length(records, 2, 'the new log: a header and a checkpoint')
  assert.equals(records[1].op, 'header', 'header')
  assert.not_equals(records[1].log_id, vim.json.decode(old_log[1]).log_id, 'a new log_id')
  assert.equals(records[2].op, 'checkpoint', 'checkpoint')
  local doc = vim.json.decode(table.concat(vim.fn.readfile(test_helper.state_path()), '\n'))
  assert.equals(doc.log_id, records[1].log_id, 'state.json is keyed to the new log')
  assert.length(vim.fn.glob(log_file .. '.rotating-*', true, true), 0, 'no temp file left')

  local after_add = ids_of(store.all())
  assert.equals(after_add, before.all .. ',' .. store.all()[#store.all()].id, 'the new comment added')
  local function check(label)
    local trash = vim.tbl_keys(store.trash())
    table.sort(trash)
    assert.equals(ids_of(store.all()), after_add, label .. ': comments')
    assert.equals(table.concat(trash, ','), table.concat(before.trash, ','), label .. ': trash')
    assert.equals(trash_ids(store.trash_list()), before.list, label .. ': trash order')
    assert.equals(table.concat(store.last_removal().ids, ','), before.last, label .. ': last removal')
  end
  check('after rotation')
  qf, store = restart()
  check('restarted from the cache')
  os.remove(test_helper.state_path())
  qf, store = restart({}, true)
  check('restarted from the checkpoint')

  -- The trash is restorable from the checkpoint
  local calls = capture_notify(function() qf.restore_comment(keep) end)
  assert.truthy(store.get(keep), 'restored: ' .. vim.inspect(calls))
end)

assert.run_test('a rotated log is not taken for a torn one next to comments.json', function()
  reset()
  add_at(1)
  qf = restart({ log_max_bytes = 1 })
  add_at(2)
  assert.length(test_helper.log_records(log_file), 2, 'header and checkpoint only')
  local fh = io.open(storage_file, 'wb')
  fh:write(vim.json.encode({ version = 2, comments = {} }))
  fh:close()
  os.remove(test_helper.state_path())
  local store
  capture_notify(function()
    qf, store = restart({}, true)
    store.all()
  end)
  assert.length(vim.fn.glob(log_file .. '.torn-*', true, true), 0, 'not moved aside')
  assert.length(store.all(), 2, 'both comments')
  os.remove(storage_file)
end)

assert.run_test('a crashed migration is still finished after a rotation', function()
  reset()
  local raw = vim.json.encode({ version = 2, comments = {
    { id = '00000000000000c1', filename = abs, lnum = 1, end_lnum = 1, kind = 'issue', body = 'one',
      created_at = 1700000000 },
  } })
  local fh = io.open(storage_file, 'wb')
  fh:write(raw)
  fh:close()
  local store
  qf, store = restart({ log_max_bytes = 1 }, true)
  assert.length(store.all(), 1, 'migrated')
  assert.equals(vim.fn.filereadable(storage_file .. '.pre-log.bak'), 1, 'backed up')
  add_at(2) -- rotates
  assert.length(rotated(), 1, 'rotated')
  -- The migration "crashed" before its rename: comments.json is back
  os.rename(storage_file .. '.pre-log.bak', storage_file)
  os.remove(test_helper.state_path())
  local calls = capture_notify(function()
    qf, store = restart({}, true)
    store.all()
  end)
  assert.length(mentioning(calls, 'reappeared'), 0, 'no reappeared warning: ' .. vim.inspect(calls))
  assert.equals(vim.fn.filereadable(storage_file), 0, 'renamed away')
  assert.equals(vim.fn.filereadable(storage_file .. '.pre-log.bak'), 1, 'to the backup')
  assert.length(store.all(), 2, 'no duplicates')
end)

assert.run_test('history reads rotated logs; the checkpoint is no row', function()
  reset()
  add_at(2, 'ISSUE')
  local store = require('quickfix-review.store')
  local id = store.all()[1].id
  qf, store = restart({ log_max_bytes = 1 })
  add_at(4) -- rotates, with the first add in the rotated log
  assert.equals(store.edit(id, 'new body'), 'edited', 'edited after the rotation')
  local rows = qf.history_rows(id)
  local ops = {}
  for i, r in ipairs(rows) do ops[i] = r.op end
  assert.equals(table.concat(ops, ','), 'add,update', 'the add from the rotated log, then the update')
  assert.equals(rows[2].kind, 'issue', 'the update knows its kind')
  assert.truthy(rows[2].text:find('test_file.txt:2', 1, true), 'and its place: ' .. rows[2].text)
  local all = qf.history_rows()
  for _, r in ipairs(all) do
    assert.not_equals(r.op, 'checkpoint', 'no checkpoint row')
    assert.not_equals(r.op, 'header', 'no header row')
  end
  local all_ops = {}
  for i, r in ipairs(all) do all_ops[i] = r.op end
  assert.equals(table.concat(all_ops, ','), 'add,add,update', 'every event once: ' .. table.concat(all_ops, ','))
  -- A comment added after the last rotation: older logs are not read for it
  qf, store = restart()
  add_at(5)
  local newest = store.all()[3].id
  local reads = 0
  local log = require('quickfix-review.log')
  local original_read = log.read
  log.read = function(path, ...)
    reads = reads + 1
    return original_read(path, ...)
  end
  local ok, newest_rows = pcall(qf.history_rows, newest)
  log.read = original_read
  assert.truthy(ok, tostring(newest_rows))
  assert.length(newest_rows, 1, 'its add only')
  assert.equals(reads, 1, 'only the current log read')
end)

assert.run_test('retention deletes only this review\'s rotated logs older than N days', function()
  reset()
  add_at(1)
  add_at(2)
  local store = require('quickfix-review.store')
  local deleted = store.all()[2].id
  qf.delete_comment({ 2, 2 })
  qf, store = restart({ log_max_bytes = 1 })
  add_at(3) -- rotates: the delete is only in the rotated log and the checkpoint
  local real = rotated()
  assert.length(real, 1, 'rotated')
  local now = os.time() * 1000
  local old = storage_file .. '.log.' .. (now - 10 * 86400000) .. '.jsonl'
  assert.truthy(os.rename(real[1], old), 'made old')
  local recent = storage_file .. '.log.' .. (now - 3600000) .. '.jsonl'
  vim.fn.writefile({ 'recent' }, recent)
  local torn = log_file .. '.torn-' .. (os.time() - 30 * 86400)
  vim.fn.writefile({ 'torn' }, torn)
  local other = vim.fn.tempname() .. '-other.json'
  local other_old = other .. '.log.' .. (now - 10 * 86400000) .. '.jsonl'
  vim.fn.writefile({ 'other review' }, other_old)
  assert.equals(vim.fn.fnamemodify(other_old, ':h'), vim.fn.fnamemodify(old, ':h'), 'one directory')

  qf, store = restart({ log_retention_days = 1 })
  local calls = capture_notify(function() store.all() end)
  assert.equals(vim.fn.filereadable(old), 0, 'the old rotated log is deleted: ' .. vim.inspect(calls))
  assert.equals(vim.fn.filereadable(recent), 1, 'a recent one is kept')
  assert.equals(vim.fn.filereadable(torn), 1, 'a torn log is kept')
  assert.equals(vim.fn.filereadable(other_old), 1, 'another review\'s is kept')
  assert.equals(vim.fn.filereadable(log_file), 1, 'the log is kept')
  assert.truthy(store.trash()[deleted], 'the trash survives')
  qf.restore_comment(deleted)
  assert.truthy(store.get(deleted), 'and is restorable')
  os.remove(recent)
  os.remove(torn)
  os.remove(other_old)
end)

assert.run_test('retention in a storage dir, and bad option values fall back', function()
  local data = vim.fn.tempname() .. '-data'
  vim.fn.mkdir(data, 'p')
  vim.env.XDG_DATA_HOME = data
  local dir = vim.fn.tempname() .. '-review'
  vim.fn.mkdir(dir, 'p')
  local store
  qf, store = restart({ storage_dir = dir, log_max_bytes = 1 }, true)
  assert.truthy(store.add({ filename = abs, lnum = 1, kind = 'note', body = 'a' }), 'added')
  assert.truthy(store.add({ filename = abs, lnum = 2, kind = 'note', body = 'b' }), 'added, rotating')
  local real = vim.fn.glob(dir .. '/log.*.jsonl', true, true)
  assert.truthy(#real >= 1, 'rotated in the dir: ' .. vim.inspect(vim.fn.readdir(dir)))
  local now = os.time() * 1000
  local old = dir .. '/log.' .. (now - 5 * 86400000) .. '.jsonl'
  vim.fn.writefile({ 'old' }, old)
  local stranger = dir .. '/other.log.' .. (now - 5 * 86400000) .. '.jsonl'
  vim.fn.writefile({ 'x' }, stranger)

  local calls = capture_notify(function()
    qf, store = restart({ storage_dir = dir, log_retention_days = 'soon', log_max_bytes = -3 }, true)
  end)
  assert.length(mentioning(calls, 'log_retention_days'), 1, 'bad retention warned about')
  assert.length(mentioning(calls, 'log_max_bytes'), 1, 'bad max warned about')
  local config = require('quickfix-review.config')
  assert.equals(config.options.log_retention_days, nil, 'keeps rotated logs')
  assert.equals(config.options.log_max_bytes, 5 * 1024 * 1024, 'the default limit')
  store.all()
  assert.equals(vim.fn.filereadable(old), 1, 'nothing deleted without retention')

  qf, store = restart({ storage_dir = dir, log_retention_days = 2 }, true)
  store.all()
  assert.equals(vim.fn.filereadable(old), 0, 'old rotated log deleted')
  for _, p in ipairs(real) do assert.equals(vim.fn.filereadable(p), 1, 'recent rotated log kept') end
  assert.equals(vim.fn.filereadable(stranger), 1, 'a file of another name kept')
  assert.length(store.all(), 2, 'the review intact')
  vim.fn.delete(dir, 'rf')
  vim.fn.delete(data, 'rf')
  vim.env.XDG_DATA_HOME = original_data_home
  qf = restart({}, true)
end)

assert.run_test('two Neovims appending while rotating lose and duplicate nothing', function()
  local file = vim.fn.tempname() .. '-rotating.json'
  local script = vim.fn.tempname() .. '-writer.lua'
  vim.fn.writefile({
    'local who = ...',
    string.format('require("quickfix-review").setup({ storage_file = %q, log_max_bytes = 20000 })', file),
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
    local files = rotated(file)
    assert.truthy(#files >= 1, 'rotated at least once')
    table.insert(files, test_helper.log_path(file))
    local eids, adds = {}, { one = 0, two = 0 }
    for _, path in ipairs(files) do
      local records = test_helper.log_records(path)
      assert.equals(records[1].op, 'header', path .. ' starts with a header')
      for i = 2, #records do
        local ev = records[i]
        if ev.op ~= 'checkpoint' then
          assert.falsy(eids[ev.eid], 'eid ' .. tostring(ev.eid) .. ' logged once')
          eids[ev.eid] = true
          assert.equals(ev.op, 'add', 'an add')
          local who = ev.comment.body:match('^(%a+) ')
          adds[who] = adds[who] + 1
        else
          assert.equals(i, 2, 'a checkpoint only follows the header')
        end
      end
    end
    assert.equals(adds.one, 50, 'every add of writer one, once')
    assert.equals(adds.two, 50, 'every add of writer two, once')
    local current = test_helper.log_records(test_helper.log_path(file))
    assert.equals(current[2].op, 'checkpoint', 'the log starts from a checkpoint')
    assert.length(test_helper.saved(test_helper.log_path(file)), 100, '100 live comments')
    assert.equals(vim.fn.isdirectory(test_helper.lock_path(file)), 0, 'no lock left behind')
    assert.length(vim.fn.glob(test_helper.log_path(file) .. '.rotating-*', true, true), 0, 'no temp file')
  end)
  test_helper.remove_storage(file)
  os.remove(script)
  if not ok then error(err, 0) end
end)

local function now_ms()
  local sec, usec = uv.gettimeofday()
  return sec * 1000 + math.floor(usec / 1000)
end

-- Rewrite the log's header with format version `v`, keeping its log_id
local function set_version(v)
  local lines = vim.fn.readfile(log_file, 'b')
  local header = vim.json.decode(lines[1])
  header.v = v
  lines[1] = vim.json.encode(header)
  vim.fn.writefile(lines, log_file, 'b')
end

assert.run_test('a checkpoint above log_max_bytes does not rotate on every change', function()
  reset()
  for l = 1, 4 do add_at(l) end
  local store
  qf, store = restart({ log_max_bytes = 1 })
  local ids = ids_of(store.all())
  for i = 1, 5 do assert.equals(store.edit(store.all()[1].id, 'body ' .. i), 'edited', 'edit ' .. i) end
  local after_edits = #rotated()
  assert.truthy(after_edits >= 1, 'the first change still rotates')
  assert.truthy(after_edits <= 2, '5 changes, not 5 rotations: ' .. after_edits)
  -- A restart does not know the checkpoint's size yet: still bounded
  qf, store = restart({ log_max_bytes = 1 })
  for i = 6, 10 do assert.equals(store.edit(store.all()[1].id, 'body ' .. i), 'edited', 'edit ' .. i) end
  assert.truthy(#rotated() <= after_edits + 1, '5 more changes after a restart: ' .. #rotated())
  assert.equals(ids_of(store.all()), ids, 'every comment kept')
  assert.equals(store.all()[1].body, 'body 10', 'the last edit')
  os.remove(test_helper.state_path())
  qf, store = restart({}, true)
  assert.equals(ids_of(store.all()), ids, 'replayed from the log alone')
end)

assert.run_test('a rotated log hard-linked to the live log shows its events once', function()
  reset()
  add_at(1)
  local store
  qf, store = restart({ log_max_bytes = 1 })
  add_at(2) -- rotates
  assert.length(rotated(), 1, 'rotated')
  local id = store.all()[1].id
  assert.equals(store.edit(id, 'edited'), 'edited', 'edited')
  local function ops()
    local rows = qf.history_rows()
    local out, seen = {}, {}
    for i, r in ipairs(rows) do
      out[i] = r.op
      local key = tostring(r.ts) .. r.op .. tostring(r.id) .. r.changes
      assert.falsy(seen[key], 'row shown once: ' .. r.text)
      seen[key] = true
    end
    return table.concat(out, ',')
  end
  local before = ops()
  assert.equals(before, 'add,add,update', 'history before the link')
  -- A rotation that crashed between its link and its rename
  uv.sleep(2)
  assert.truthy(uv.fs_link(log_file, storage_file .. '.log.' .. now_ms() .. '.jsonl'), 'linked')
  assert.length(rotated(), 2, 'two rotated names')
  assert.equals(ops(), before, 'each event once after the crash')
  assert.equals(#qf.history_rows(id), 2, 'the comment\'s add and update once')
  -- Rotated again: both rotated names of that log are the same inode now
  uv.sleep(2)
  local n = #rotated()
  for i = 1, 100 do
    if #rotated() > n then break end
    assert.equals(store.edit(id, 'again ' .. i), 'edited', 'edit ' .. i)
  end
  assert.equals(#rotated(), n + 1, 'rotated again')
  local after = ops()
  assert.equals(after:sub(1, #before), before, 'each event once after another rotation: ' .. after)
  local _, updates = after:gsub('update', '')
  assert.equals(#vim.split(after, ','), 2 + updates, 'no event twice')
end)

assert.run_test('history of a log with no complete header line does not raise', function()
  reset()
  add_at(1)
  qf = restart({ log_max_bytes = 1 })
  add_at(2) -- rotates, so an older log exists
  assert.length(rotated(), 1, 'rotated')
  local function check(label)
    local ok, rows, err = pcall(qf.history_rows)
    assert.truthy(ok, label .. ': no error raised: ' .. tostring(rows))
    if rows then
      assert.length(rows, 0, label .. ': no rows')
    else
      assert.truthy(err, label .. ': an error message')
    end
  end
  vim.fn.writefile({}, log_file, 'b') -- a 0-byte log
  check('empty log')
  local f = io.open(log_file, 'wb')
  assert.truthy(f, 'opened')
  f:write('{"op":"header","v":2')
  f:close()
  check('torn header')
end)

assert.run_test('a stray .rotating file of a dead process is removed at rotation', function()
  reset()
  add_at(1)
  local child = vim.system({ 'true' })
  child:wait()
  local dead = log_file .. '.rotating-' .. child.pid
  local live = log_file .. '.rotating-' .. uv.os_getppid()
  vim.fn.writefile({ 'stray' }, dead)
  vim.fn.writefile({ 'in flight' }, live)
  qf = restart({ log_max_bytes = 1 })
  add_at(2) -- rotates
  assert.length(rotated(), 1, 'rotated')
  assert.equals(vim.fn.filereadable(dead), 0, 'the dead process\'s temp file is removed')
  assert.equals(vim.fn.filereadable(live), 1, 'a live process\'s is kept')
  os.remove(live)
end)

assert.run_test('a stray .rotating-<pid>-old copy of a dead process is removed at rotation', function()
  reset()
  add_at(1)
  local child = vim.system({ 'true' })
  child:wait()
  local dead = log_file .. '.rotating-' .. child.pid .. '-old'
  local live = log_file .. '.rotating-' .. uv.os_getppid() .. '-old'
  vim.fn.writefile({ 'stray' }, dead)
  vim.fn.writefile({ 'in flight' }, live)
  qf = restart({ log_max_bytes = 1 })
  add_at(2) -- rotates
  assert.length(rotated(), 1, 'rotated')
  assert.equals(vim.fn.filereadable(dead), 0, 'the dead process\'s copy is removed')
  assert.equals(vim.fn.filereadable(live), 1, 'a live process\'s is kept')
  os.remove(live)
end)

assert.run_test('rotation without hard links never shows a partly copied rotated log', function()
  reset()
  local store = require('quickfix-review.store')
  local snapshots = require('quickfix-review.snapshots')
  local day_ago = os.time() - 25 * 3600
  local snap_dir = storage_file .. '.snapshots'
  add_at(1)
  -- Named only at the end of the log (a torn record, not carried into the
  -- checkpoint): lost if a GC read the rotated log half-copied
  local tail = snapshots.put({ 'tail' })
  local fh = io.open(log_file, 'ab')
  fh:write('{"op":"add","comment":{"anchor":{"sha":"' .. tail .. '"')
  fh:close()
  uv.fs_utime(snap_dir .. '/' .. tail, day_ago, day_ago)

  local original_link, original_copy = uv.fs_link, uv.fs_copyfile
  local copies, seen, source_bytes = 0, {}, nil
  uv.fs_link = function() return nil, 'EXDEV: cross-device link not permitted' end
  uv.fs_copyfile = function(src, dst, flags)
    copies = copies + 1
    source_bytes = table.concat(vim.fn.readfile(src, 'b'), '\n')
    -- Half copied: nothing a GC (or :ReviewHistory) lists may name it yet
    local f = io.open(dst, 'wb')
    f:write(source_bytes:sub(1, math.floor(#source_bytes / 2)))
    f:close()
    table.insert(seen, { dst = dst, rotated = #rotated(), listed = #store.rotated_logs() })
    os.remove(dst)
    return original_copy(src, dst, flags)
  end
  local ok, err = pcall(function()
    capture_notify(function()
      qf, store = restart({ log_max_bytes = 1 })
      add_at(2) -- rotates by copying
    end)
  end)
  uv.fs_link, uv.fs_copyfile = original_link, original_copy
  assert.truthy(ok, 'rotated: ' .. tostring(err))

  assert.equals(copies, 1, 'copied once')
  assert.falsy(seen[1].dst:match('%.jsonl$'), 'copied to a temp name: ' .. seen[1].dst)
  assert.equals(seen[1].rotated, 0, 'no rotated log while copying')
  assert.equals(seen[1].listed, 0, 'none listed while copying')
  local logs = rotated()
  assert.length(logs, 1, 'one rotated log')
  assert.equals(table.concat(vim.fn.readfile(logs[1], 'b'), '\n'), source_bytes, 'the whole log was kept')
  assert.length(vim.fn.glob(log_file .. '.rotating-*', true, true), 0, 'no temp files left')
  vim.wait(50, function() return false end, 10) -- the GC the rotation scheduled
  store.gc_snapshots()
  assert.truthy(uv.fs_stat(snap_dir .. '/' .. tail), 'the snapshot named by the rotated log is kept')
end)

assert.run_test('rotation collects unreferenced old snapshots, keeping ones rotated logs name', function()
  reset()
  local store = require('quickfix-review.store')
  local snapshots = require('quickfix-review.snapshots')
  local day_ago = os.time() - 25 * 3600
  local snap_dir = storage_file .. '.snapshots'
  local function path(sha) return snap_dir .. '/' .. sha end

  local trashed = snapshots.put({ 'trashed' })
  assert.truthy(store.add({ filename = abs, lnum = 1, kind = 'note', body = 't',
    anchor = { sha = trashed, lnum = 1, end_lnum = 1 } }), 'added')
  assert.equals(store.remove(store.all()[1].id), 1, 'deleted')
  -- Named only by a torn record, which stays in the rotated log alone
  local torn = snapshots.put({ 'torn' })
  local fh = io.open(log_file, 'ab')
  fh:write('{"op":"add","comment":{"anchor":{"sha":"' .. torn .. '"')
  fh:close()
  local old = snapshots.put({ 'old' })
  for _, sha in ipairs({ trashed, torn, old }) do uv.fs_utime(path(sha), day_ago, day_ago) end

  -- Another storage_file review's snapshots, in the same directory
  local other = vim.fn.tempname() .. '-other.json'
  vim.fn.mkdir(other .. '.snapshots', 'p')
  local foreign = other .. '.snapshots/' .. string.rep('a', 64)
  vim.fn.writefile({ 'x' }, foreign)
  uv.fs_utime(foreign, day_ago, day_ago)

  capture_notify(function()
    qf, store = restart({ log_max_bytes = 1 })
    add_at(2) -- rotates, then collects
    assert.length(rotated(), 1, 'rotated')
    assert.truthy(vim.wait(2000, function() return not uv.fs_stat(path(old)) end, 10), 'unreferenced old deleted')
  end)
  assert.truthy(uv.fs_stat(path(trashed)), 'a trash entry\'s kept')
  assert.truthy(uv.fs_stat(path(torn)), 'named only by the rotated log: kept')
  assert.truthy(uv.fs_stat(foreign), 'another review\'s untouched')
  assert.equals(store.gc_snapshots(), 0, 'nothing more to collect')
  vim.fn.delete(other .. '.snapshots', 'rf')
end)

assert.run_test('gc reads rotated logs outside the lock, so a concurrent change isn\'t kept waiting', function()
  reset()
  local store = require('quickfix-review.store')
  local snapshots = require('quickfix-review.snapshots')
  local day_ago = os.time() - 25 * 3600
  local snap_dir = storage_file .. '.snapshots'
  local function path(sha) return snap_dir .. '/' .. sha end

  -- Named by the logs (the add event, then each rotation's checkpoint)
  local named = snapshots.put({ 'named' })
  assert.truthy(store.add({ filename = abs, lnum = 1, kind = 'note', body = 'n',
    anchor = { sha = named, lnum = 1, end_lnum = 1 } }), 'added')
  capture_notify(function()
    qf, store = restart({ log_max_bytes = 1 })
    add_at(2)
    add_at(3)
    add_at(4)
    -- The GCs the rotations scheduled
    vim.wait(50, function() return false end, 10)
  end)
  local logs = rotated()
  assert.truthy(#logs >= 2, 'several rotated logs: ' .. #logs)
  local old = snapshots.put({ 'old' })
  for _, sha in ipairs({ named, old }) do uv.fs_utime(path(sha), day_ago, day_ago) end

  local log = require('quickfix-review.log')
  local original_lock, original_open = log.with_lock, io.open
  local in_lock, opened = false, {}
  log.with_lock = function(lock, fn)
    return original_lock(lock, function(...)
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
  log.with_lock, io.open = original_lock, original_open
  assert.truthy(ok, 'gc ran: ' .. tostring(removed))

  assert.equals(removed, 1, 'one snapshot collected')
  assert.falsy(uv.fs_stat(path(old)), 'unreferenced old deleted')
  assert.truthy(uv.fs_stat(path(named)), 'a referenced one kept')
  local under_lock = {}
  for _, f in ipairs(opened) do under_lock[f] = true end
  assert.truthy(under_lock[vim.fn.fnamemodify(log_file, ':p')], 'the current log is read under the lock')
  for _, r in ipairs(logs) do
    assert.falsy(under_lock[vim.fn.fnamemodify(r, ':p')], 'not read under the lock: ' .. r)
  end
end)

assert.run_test('a log from a newer version is refused, not shown empty', function()
  local log = require('quickfix-review.log')
  assert.equals(log.VERSION, 2, 'the log format is v2')
  reset()
  add_at(1)
  local store
  qf, store = restart() -- caches state.json for this log
  assert.equals(test_helper.log_records(log_file)[1].v, 2, 'new logs are v2')
  set_version(log.VERSION + 1)
  local bytes = table.concat(vim.fn.readfile(log_file, 'b'), '\n')
  local function check(label)
    local calls = capture_notify(function()
      qf, store = restart({}, true)
      store.all()
      assert.falsy(store.add({ filename = abs, lnum = 2, kind = 'note', body = 'x' }), label .. ': add refused')
    end)
    local errors = mentioning(calls, 'newer version')
    assert.truthy(#errors >= 1, label .. ': an error: ' .. vim.inspect(calls))
    assert.equals(errors[1].level, vim.log.levels.ERROR, label .. ': an ERROR')
    assert.truthy(errors[1].msg:find('upgrade', 1, true), label .. ': says to upgrade')
    assert.equals(table.concat(vim.fn.readfile(log_file, 'b'), '\n'), bytes, label .. ': the log is unchanged')
    assert.length(vim.fn.glob(log_file .. '.torn-*', true, true), 0, label .. ': not moved aside')
  end
  check('cached')
  os.remove(test_helper.state_path())
  check('uncached')

  -- A v1 log that holds a checkpoint still reads
  set_version(1)
  qf, store = restart({ log_max_bytes = 1 }, true)
  add_at(2) -- rotates
  assert.equals(test_helper.log_records(log_file)[2].op, 'checkpoint', 'rotated')
  set_version(1)
  os.remove(test_helper.state_path())
  qf, store = restart({}, true)
  assert.length(store.all(), 2, 'a v1 log with a checkpoint reads')
end)

qf = restart({}, true)
test_helper.cleanup_test_environment()

return assert
