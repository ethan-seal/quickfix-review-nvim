-- Tests for the per-project storage directory: project roots, :cd switching,
-- the one-time import from the legacy global file, and the deprecated
-- storage_file option
local test_helper = dofile((vim.env.QFR_TEST_ROOT or '.') .. '/test/init.lua')
local assert = dofile(test_helper.root .. '/test/assertions.lua')

print('\nRunning storage dir tests...')

local qf = test_helper.setup_test_environment()
local original_cwd = vim.fn.getcwd(-1, -1)
local original_data_home = vim.env.XDG_DATA_HOME

local function mods()
  return require('quickfix-review.config'), require('quickfix-review.store'), require('quickfix-review.utils')
end

-- Point stdpath('data') at an empty temp dir, so the legacy file and the
-- default storage dirs are this test's alone
local function fresh_data()
  local dir = vim.fn.tempname() .. '-data'
  vim.fn.mkdir(dir, 'p')
  vim.env.XDG_DATA_HOME = dir
  return dir
end

local function git_init(dir)
  local r = vim.system({ 'git', 'init', '-q', dir }, { text = true }):wait()
  assert.equals(r.code, 0, 'git init ' .. dir)
end

-- A temp git repo holding one file; returns its real path and the file.
-- git init runs before the plugin ever asks for the toplevel (it caches).
local function make_repo(name)
  local dir = vim.fn.tempname() .. '-' .. name
  vim.fn.mkdir(dir, 'p')
  git_init(dir)
  local real = vim.uv.fs_realpath(dir)
  local file = real .. '/' .. name .. '.txt'
  vim.fn.writefile({ 'line 1', 'line 2', 'line 3' }, file)
  return real, file
end

local function cd(dir)
  vim.cmd('cd ' .. vim.fn.fnameescape(dir))
end

-- Simulate quitting and reopening Neovim in the current cwd, with no
-- storage_file (the per-project mode)
local function restart(opts)
  for name, _ in pairs(package.loaded) do
    if name:match('^quickfix%-review') then package.loaded[name] = nil end
  end
  qf = require('quickfix-review')
  qf.setup(vim.tbl_extend('force', { keymaps = { add_issue = false } }, opts or {}))
  return qf
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
    if c.msg:find(text, 1, true) then table.insert(found, c) end
  end
  return found
end

local function read_bytes(path)
  local fh = io.open(path, 'rb')
  if not fh then return nil end
  local content = fh:read('*a')
  fh:close()
  return content
end

local function stamp(path)
  local s = vim.uv.fs_stat(path)
  return s.mtime.sec .. '.' .. s.mtime.nsec
end

-- The live records in the event log at `log_path`
local function saved(log_path)
  return test_helper.saved(log_path)
end

local function note(file, body)
  local _, store = mods()
  assert.truthy(store.add({ filename = file, lnum = 1, kind = 'note', body = body }), 'added ' .. body)
end

local function extmarks(buf)
  local _, _, utils = mods()
  return #vim.api.nvim_buf_get_extmarks(buf, utils.get_ns_id(), 0, -1, {})
end

-- Every test starts from a fresh data dir, back in the original cwd, and
-- leaves the same way. It starts on an explicit storage_file, so its first :cd
-- doesn't already switch (and import) under the previous test's setup.
local function storage_test(name, fn)
  assert.run_test(name, function()
    fresh_data()
    cd(original_cwd)
    restart({ storage_file = test_helper.storage_file })
    local ok, err = pcall(fn)
    vim.fn.setqflist({}, 'f')
    cd(original_cwd)
    vim.env.XDG_DATA_HOME = original_data_home
    if not ok then error(err, 0) end
  end)
end

storage_test('the default dir is stdpath(data)/quickfix-review/<basename>-<sha256 prefix>', function()
  local data = fresh_data()
  local a = make_repo('proj')
  cd(a)
  restart()
  local _, store = mods()
  local expected = data .. '/nvim/quickfix-review/' .. vim.fn.fnamemodify(a, ':t') .. '-'
    .. vim.fn.sha256(a):sub(1, 12)
  assert.equals(store.dir(), expected, 'storage dir')
  assert.equals(store.path(), expected .. '/comments.json', 'storage file')
  assert.equals(store.log_path(), expected .. '/log.jsonl', 'event log')
  assert.equals(store.events_dir(), expected .. '/events', 'journal')
  assert.equals(store.checkpoints_dir(), expected .. '/checkpoints', 'checkpoints')
  assert.equals(store.root(), a, 'project root')
end)

storage_test('two repos get different dirs and their comments stay apart', function()
  local a, file_a = make_repo('alpha')
  local b, file_b = make_repo('beta')
  cd(a)
  restart()
  local _, store = mods()
  note(file_a, 'in alpha')
  local path_a = store.log_path()

  cd(b)
  local path_b = store.log_path()
  assert.not_equals(path_b, path_a, 'different storage files')
  assert.length(store.all(), 0, 'alpha comment not visible in beta')
  note(file_b, 'in beta')

  local on_a, on_b = saved(path_a), saved(path_b)
  assert.length(on_a, 1, 'alpha file holds one comment')
  assert.equals(on_a[1].body, 'in alpha', 'alpha holds its own')
  assert.length(on_b, 1, 'beta file holds one comment')
  assert.equals(on_b[1].body, 'in beta', 'beta holds its own')
end)

storage_test(':cd into the other repo switches the list and the signs', function()
  local a, file_a = make_repo('gamma')
  local b = make_repo('delta')
  cd(a)
  restart()
  local _, store = mods()
  vim.cmd('edit ' .. vim.fn.fnameescape(file_a))
  local buf = vim.api.nvim_get_current_buf()
  note(file_a, 'gamma note')
  store.show()
  local qf_id = vim.fn.getqflist({ id = 0 }).id
  assert.truthy(extmarks(buf) > 0, 'sign placed in gamma')

  cd(b)
  assert.equals(extmarks(buf), 0, 'sign gone after :cd to delta')
  assert.length(vim.fn.getqflist({ id = qf_id, items = 0 }).items, 0, 'list view emptied')

  cd(a)
  assert.truthy(extmarks(buf) > 0, 'sign back after :cd to gamma')
  assert.length(vim.fn.getqflist({ id = qf_id, items = 0 }).items, 1, 'list view refilled')
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
end)

-- track memoises path keys: a relative name must resolve against the new
-- cwd after a :cd, with no restart in between
storage_test('after a :cd, a relative filename resolves against the new cwd', function()
  local track = require('quickfix-review.track')
  local signs = require('quickfix-review.signs')
  local _, store = mods()
  local dirs, ids = {}, {}
  for _, name in ipairs({ 'A', 'B' }) do
    local dir = vim.fn.tempname() .. '-' .. name
    vim.fn.mkdir(dir, 'p')
    dir = vim.uv.fs_realpath(dir)
    vim.fn.writefile({ 'line 1', 'line 2' }, dir .. '/rel.txt')
    note(dir .. '/rel.txt', 'in ' .. name)
    dirs[name] = dir
  end
  for _, c in ipairs(store.all()) do
    if c.body == 'in A' then ids.A = c.id elseif c.body == 'in B' then ids.B = c.id end
  end
  assert.truthy(ids.A and ids.B, 'both comments listed')

  cd(dirs.A)
  local at_a = track.positions('rel.txt')
  assert.truthy(at_a[ids.A], "A's comment in A")
  assert.falsy(at_a[ids.B], "B's comment not in A")

  cd(dirs.B)
  local at_b = track.positions('rel.txt')
  assert.truthy(at_b[ids.B], "B's comment in B")
  assert.falsy(at_b[ids.A], "A's comment not in B")

  vim.cmd('edit ' .. vim.fn.fnameescape(dirs.B .. '/rel.txt'))
  local buf = vim.api.nvim_get_current_buf()
  signs.draw_file(buf, 'rel.txt')
  assert.truthy(extmarks(buf) > 0, "B's sign placed")
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
end)

-- :cd into a project whose review can't be read: the other project's comments
-- must not stay visible, and nothing may be written into the bad review
for _, case in ipairs({ 'log', 'comments.json' }) do
  storage_test(':cd into a project with an unreadable ' .. case .. ' empties the view and refuses writes', function()
    local a, file_a = make_repo('pi')
    local b, file_b = make_repo('rho')
    local base = vim.fn.tempname() .. '-dirs'
    local function dir_of(root) return base .. '/' .. vim.fn.fnamemodify(root, ':t') end
    local dir_b = dir_of(b)
    vim.fn.mkdir(dir_b, 'p')
    local bad_log = '{"op":"add","not":"a header"}\n'
    if case == 'log' then
      local fh = io.open(dir_b .. '/log.jsonl', 'wb')
      assert.truthy(fh, 'bad log opened')
      fh:write(bad_log)
      fh:close()
    else
      vim.fn.writefile({ '{ not json' }, dir_b .. '/comments.json')
    end

    cd(a)
    restart({ storage_dir = dir_of })
    local _, store = mods()
    vim.cmd('edit ' .. vim.fn.fnameescape(file_a))
    local buf = vim.api.nvim_get_current_buf()
    note(file_a, 'pi note')
    store.show()
    local qf_id = vim.fn.getqflist({ id = 0 }).id
    assert.truthy(extmarks(buf) > 0, 'sign placed in pi')

    local calls = capture_notify(function() cd(b) end)
    assert.length(store.all(), 0, 'pi comment not visible in rho')
    assert.equals(extmarks(buf), 0, 'pi sign gone')
    assert.length(vim.fn.getqflist({ id = qf_id, items = 0 }).items, 0, 'list view emptied')
    local errors = mentioning(calls, 'will not be modified')
    assert.length(errors, 1, 'one error notice')
    assert.equals(errors[1].level, vim.log.levels.ERROR, 'at ERROR level')

    calls = capture_notify(function()
      assert.falsy(store.add({ filename = file_b, lnum = 1, kind = 'note', body = 'rho note' }), 'add refused')
      assert.length(store.all(), 0, 'still empty')
    end)
    assert.length(mentioning(calls, 'will not be modified'), 0, 'not reported again')
    if case == 'log' then
      assert.equals(read_bytes(dir_b .. '/log.jsonl'), bad_log, 'bad log untouched')
    else
      assert.equals(vim.fn.filereadable(dir_b .. '/log.jsonl'), 0, 'no log created')
    end

    cd(a)
    local list = store.all()
    assert.length(list, 1, 'pi comment back')
    assert.equals(list[1].body, 'pi note', 'its own comment')
    assert.truthy(extmarks(buf) > 0, 'sign back after :cd to pi')
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end)
end

storage_test(':lcd does not switch the project', function()
  local a, file_a = make_repo('eps')
  local b = make_repo('zeta')
  cd(a)
  restart()
  local _, store = mods()
  note(file_a, 'eps note')
  local path = store.path()
  vim.cmd('lcd ' .. vim.fn.fnameescape(b))
  assert.equals(store.path(), path, 'same storage file after :lcd')
  assert.length(store.all(), 1, 'same comments')
end)

storage_test('storage_dir as a function gets the resolved root', function()
  local a = make_repo('eta')
  local link = vim.fn.tempname() .. '-eta-link'
  assert.truthy(vim.uv.fs_symlink(a, link), 'symlink created')
  local got
  local target = vim.fn.tempname() .. '-custom'
  cd(link)
  restart({ storage_dir = function(root) got = root return target end })
  local _, store = mods()
  assert.equals(got, a, 'root passed with symlinks resolved')
  assert.equals(store.path(), target .. '/comments.json', 'custom dir used')
  os.remove(link)
end)

storage_test('storage_dir as a string is used as-is, created on first write', function()
  local a, file_a = make_repo('theta')
  local target = vim.fn.tempname() .. '-custom/nested'
  cd(a)
  restart({ storage_dir = target })
  local _, store = mods()
  assert.equals(store.path(), target .. '/comments.json', 'string dir used')
  note(file_a, 'theta note')
  assert.length(saved(target .. '/log.jsonl'), 1, 'written into the new dir')
end)

storage_test('outside git the root is the cwd', function()
  local dir = vim.fn.tempname() .. '-plain'
  vim.fn.mkdir(dir, 'p')
  local _, _, utils = mods()
  assert.equals(utils.git_toplevel(dir), nil, 'not a git repo')
  cd(dir)
  restart()
  local _, store = mods()
  assert.equals(store.root(), vim.uv.fs_realpath(dir), 'root is the cwd')
end)

-- The legacy global file, with comments in repo a, repo b and a sibling of a
-- whose path has a as a prefix
-- Storage dir of the project whose root is `root`, under stdpath('data')
local function default_dir(root)
  return vim.env.XDG_DATA_HOME .. '/nvim/quickfix-review/' .. vim.fn.fnamemodify(root, ':t') .. '-'
    .. vim.fn.sha256(root):sub(1, 12)
end

local function seed_legacy(a, b, v1)
  local config = mods()
  local legacy = config.legacy_storage_file()
  vim.fn.mkdir(vim.fn.fnamemodify(legacy, ':h'), 'p')
  local content
  if v1 then
    content = vim.json.encode({
      { filename = a .. '/a.txt', lnum = 1, col = 1, text = '[ISSUE] from a' },
      { filename = b .. '/b.txt', lnum = 2, col = 1, text = '[NOTE] from b' },
      { filename = a .. '2/c.txt', lnum = 3, col = 1, text = '[NOTE] from sibling' },
    })
  else
    content = vim.json.encode({ version = 2, comments = {
      { id = '0000000000000001', filename = a .. '/a.txt', lnum = 1, kind = 'issue', body = 'from a',
        created_at = 1, text = '[ISSUE] from a | Response: ok', custom = 'kept' },
      { id = '0000000000000002', filename = b .. '/b.txt', lnum = 2, kind = 'note', body = 'from b', created_at = 2 },
      { id = '0000000000000003', filename = a .. '2/c.txt', lnum = 3, kind = 'note', body = 'from sibling',
        created_at = 3 },
    } })
  end
  vim.fn.writefile({ content }, legacy)
  return legacy
end

for _, v1 in ipairs({ true, false }) do
  local label = v1 and 'v1' or 'v2'
  storage_test('legacy ' .. label .. ' file: each project imports only its own, the file untouched', function()
    local a = make_repo('iota')
    local b = make_repo('kappa')
    vim.fn.mkdir(a .. '2', 'p')
    local legacy = seed_legacy(a, b, v1)
    local bytes, before = read_bytes(legacy), stamp(legacy)
    vim.uv.sleep(10)

    cd(a)
    local calls = capture_notify(function() restart() end)
    local _, store = mods()
    local list = store.all()
    assert.length(list, 1, 'a imports one comment')
    assert.equals(list[1].body, 'from a', 'its own comment')
    assert.equals(list[1].kind, 'issue', 'kind kept')
    local imported = mentioning(calls, 'imported 1 comments from ' .. legacy)
    assert.length(imported, 1, 'one import notice')
    local on_disk = saved(store.log_path())
    assert.length(on_disk, 1, 'one comment in the log')
    assert.length(test_helper.log_ops(store.log_path(), 'import'), 1, 'as one import event')
    assert.equals(on_disk[1].text, nil, 'no legacy text field written')
    if not v1 then
      assert.equals(on_disk[1].id, '0000000000000001', 'id kept')
      assert.equals(on_disk[1].response, 'ok', 'legacy text response merged')
      assert.equals(on_disk[1].custom, 'kept', 'unknown field kept')
    end

    calls = capture_notify(function() cd(b) end)
    list = store.all()
    assert.length(list, 1, 'b imports one comment')
    assert.equals(list[1].body, 'from b', 'b gets its own comment')
    assert.length(mentioning(calls, 'imported 1 comments'), 1, 'one import notice for b')

    assert.equals(read_bytes(legacy), bytes, 'legacy bytes unchanged')
    assert.equals(stamp(legacy), before, 'legacy mtime unchanged')
    assert.equals(vim.fn.filereadable(legacy .. '.pre-log.bak'), 0, 'legacy not moved aside')
  end)
end

for _, v1 in ipairs({ true, false }) do
  local label = v1 and 'v1' or 'v2'
  storage_test('legacy ' .. label .. ' file with a string storage_dir: every comment imported once', function()
    local a = make_repo('upsilon')
    local b = make_repo('phi')
    vim.fn.mkdir(a .. '2', 'p')
    local legacy = seed_legacy(a, b, v1)
    local bytes = read_bytes(legacy)
    local target = vim.fn.tempname() .. '-shared'

    cd(a)
    local calls = capture_notify(function() restart({ storage_dir = target }) end)
    local _, store = mods()
    assert.length(store.all(), 3, 'every comment imported')
    assert.length(mentioning(calls, 'imported 3 comments from ' .. legacy), 1, 'one import notice')
    assert.length(test_helper.log_ops(store.log_path(), 'import'), 1, 'one import event')

    calls = capture_notify(function() cd(b) end)
    assert.length(store.all(), 3, 'same shared review in b')
    assert.length(mentioning(calls, 'imported'), 0, 'no second import notice')
    assert.length(test_helper.log_ops(store.log_path(), 'import'), 1, 'still one import event')
    assert.equals(read_bytes(legacy), bytes, 'legacy bytes unchanged')
  end)
end

storage_test('a legacy file is not imported into a review rooted at $HOME', function()
  -- A fake HOME (a temp dir, not a git repo): the real one is never touched
  local original_home = vim.env.HOME
  local dir = vim.fn.tempname() .. '-home'
  vim.fn.mkdir(dir .. '/proj', 'p')
  local home = vim.uv.fs_realpath(dir)
  vim.env.HOME = home
  local ok, err = pcall(function()
    local config = mods()
    local legacy = config.legacy_storage_file()
    vim.fn.mkdir(vim.fn.fnamemodify(legacy, ':h'), 'p')
    vim.fn.writefile({ vim.json.encode({ version = 2, comments = {
      { id = '0000000000000001', filename = home .. '/proj/a.txt', lnum = 1, kind = 'issue', body = 'one',
        created_at = 1 },
      { id = '0000000000000002', filename = home .. '/b.txt', lnum = 2, kind = 'note', body = 'two',
        created_at = 2 },
    } }) }, legacy)
    local bytes = read_bytes(legacy)

    cd(home)
    local calls = capture_notify(function()
      restart()
      local _, store = mods()
      assert.equals(store.root(), home, 'the review is rooted at the fake HOME')
      assert.length(store.all(), 0, 'nothing imported')
      assert.length(store.all(), 0, 'nothing imported at the next sync')
    end)
    assert.length(mentioning(calls, 'imported'), 0, 'no import notice')
    local warns = {}
    for _, c in ipairs(calls) do
      if c.level == vim.log.levels.WARN then table.insert(warns, c) end
    end
    assert.length(warns, 1, 'one warning')
    assert.truthy(warns[1].msg:find(legacy, 1, true), 'the warning names the legacy file: ' .. warns[1].msg)
    assert.length(vim.fn.glob(default_dir(home) .. '/events/*', false, true), 0, 'no journal started')
    assert.equals(read_bytes(legacy), bytes, 'legacy bytes unchanged')
  end)
  vim.env.HOME = original_home
  vim.fn.delete(dir, 'rf')
  if not ok then error(err, 0) end
end)

storage_test('a storage_dir that cannot be created: setup and add report an error, never throw', function()
  local a, file_a = make_repo('sigma')
  local b = make_repo('tau')
  seed_legacy(a, b, false)
  local blocker = vim.fn.tempname() .. '-blocker'
  vim.fn.writefile({ 'a file, not a dir' }, blocker)
  local target = blocker .. '/sub/dir'
  cd(a)
  local ok, err
  local calls = capture_notify(function()
    ok, err = pcall(restart, { storage_dir = target })
  end)
  assert.truthy(ok, 'setup did not throw: ' .. tostring(err))
  assert.truthy(#mentioning(calls, target) > 0, 'import failure names the dir')
  local _, store = mods()
  local added
  calls = capture_notify(function()
    ok, err = pcall(function()
      added = store.add({ filename = file_a, lnum = 1, kind = 'note', body = 'sigma note' })
    end)
  end)
  assert.truthy(ok, 'add did not throw: ' .. tostring(err))
  assert.falsy(added, 'add failed')
  local named = mentioning(calls, target)
  assert.truthy(#named > 0, 'error names the dir')
  assert.equals(named[1].level, vim.log.levels.ERROR, 'at ERROR level')
  assert.length(store.all(), 0, 'nothing added')
  assert.equals(vim.fn.isdirectory(target), 0, 'dir not created')
end)

storage_test('import happens once: a cleared review is not re-imported', function()
  local a = make_repo('lambda')
  local b = make_repo('mu')
  local c = make_repo('nu')
  seed_legacy(a, b, false)
  cd(a)
  capture_notify(function() restart() end)
  local _, store = mods()
  assert.length(store.all(), 1, 'imported')
  store.clear()

  local calls = capture_notify(function() restart() end)
  _, store = mods()
  assert.length(store.all(), 0, 'nothing re-imported after restart')
  assert.length(mentioning(calls, 'imported'), 0, 'no import notice')
  assert.length(test_helper.log_ops(store.log_path(), 'import'), 1, 'one import event in the log')

  calls = capture_notify(function() cd(c) end)
  assert.length(store.all(), 0, 'no comments for an unrelated project')
  assert.length(mentioning(calls, 'imported'), 0, 'no notice for 0 imported')
  -- An empty import starts no journal: the dir stays empty (so :ReviewAdopt
  -- can fill it)
  assert.equals(vim.fn.glob(store.events_dir() .. '/*.jsonl'), '', 'no journal for an empty import')
  assert.equals(vim.fn.filereadable(store.log_path()), 0, 'no tombstone for an empty import')
end)

storage_test('a failed legacy import is retried, not marked done by the next change', function()
  local a, file_a = make_repo('chi')
  local b = make_repo('psi')
  local c = make_repo('omega')
  seed_legacy(a, b, false)
  cd(c)
  capture_notify(function() restart() end)
  local _, store = mods()
  local dir_a = default_dir(a)
  local segment = require('quickfix-review.store.segment')
  local original_create = segment.create
  segment.create = function(dir, ...)
    if vim.startswith(dir, dir_a .. '/') then return nil, 'ENOSPC' end
    return original_create(dir, ...)
  end
  local ok, err = pcall(function()
    local calls = capture_notify(function()
      cd(a)
      store.all()
    end)
    local failed = mentioning(calls, 'import from')
    assert.truthy(#failed > 0, 'import failure reported')
    assert.equals(failed[1].level, vim.log.levels.ERROR, 'at ERROR level')
    assert.falsy(vim.uv.fs_stat(dir_a .. '/events/000001.jsonl'), 'no segment')
  end)
  segment.create = original_create
  if not ok then error(err, 0) end

  capture_notify(function()
    assert.truthy(store.add({ filename = file_a, lnum = 2, kind = 'note', body = 'after' }), 'added')
  end)
  local bodies = {}
  for _, cm in ipairs(store.all()) do bodies[cm.body] = true end
  assert.truthy(bodies['from a'], 'legacy comment imported')
  assert.truthy(bodies['after'], 'the change kept')
  local records = test_helper.log_records(store.log_path())
  assert.equals(records[2] and records[2].op, 'import', 'the import is the first event')
  assert.length(test_helper.log_ops(store.log_path(), 'import'), 1, 'one import event')

  capture_notify(function() restart() end)
  _, store = mods()
  assert.length(store.all(), 2, 'both after a restart')
  assert.length(test_helper.log_ops(store.log_path(), 'import'), 1, 'still one import event')
end)

storage_test('a torn legacy import is moved aside and imported again', function()
  local a = make_repo('alef')
  local b = make_repo('bet')
  seed_legacy(a, b, false)
  local dir_a = default_dir(a)
  vim.fn.mkdir(dir_a, 'p')
  local log = require('quickfix-review.log')
  local fh = io.open(dir_a .. '/log.jsonl', 'wb')
  fh:write(vim.json.encode(log.v2_header()) .. '\n{"op":"imp')
  fh:close()
  cd(a)
  local calls = capture_notify(function() restart() end)
  local _, store = mods()
  assert.equals(store.dir(), dir_a, 'a\'s dir')
  local list = store.all()
  assert.length(list, 1, 'imported')
  assert.equals(list[1].body, 'from a', 'the legacy comment')
  assert.length(test_helper.log_ops(store.log_path(), 'import'), 1, 'one import event')
  assert.length(vim.fn.glob(dir_a .. '/log.jsonl.torn-*', true, true), 1, 'torn log moved aside')
  assert.truthy(#mentioning(calls, 'was incomplete') > 0, 'warned about the torn log')
end)

storage_test('an import interrupted in this session leaves no journal and is imported again', function()
  local a = make_repo('gimel')
  local b = make_repo('dalet')
  local c = make_repo('he')
  seed_legacy(a, b, false)
  cd(c)
  capture_notify(function() restart() end)
  local _, store = mods()
  local dir_a = default_dir(a)
  local segment = require('quickfix-review.store.segment')
  local original_create = segment.create
  local torn = 0
  -- A crash after the temp file's partial write, before its link: the
  -- segment never exists, only a stray temp file
  segment.create = function(dir, n, events, ...)
    if dir == dir_a .. '/events' and torn == 0 then
      torn = 1
      local fh = io.open(dir .. '.tmp.1', 'wb')
      fh:write(vim.json.encode(events[1]) .. '\n{"op":"imp')
      fh:close()
      return nil, 'short write'
    end
    return original_create(dir, n, events, ...)
  end
  local ok, err = pcall(function()
    capture_notify(function()
      cd(a)
      store.all()
    end)
  end)
  segment.create = original_create
  if not ok then error(err, 0) end
  assert.equals(torn, 1, 'the import was interrupted')
  capture_notify(function() store.all() end)
  assert.length(test_helper.segments_of(store.log_path()), 1, 'one segment')
  local list = store.all()
  assert.length(list, 1, 'imported')
  assert.equals(list[1].body, 'from a', 'the legacy comment')
  assert.length(test_helper.log_ops(store.log_path(), 'import'), 1, 'one import event')
end)

storage_test('a symlinked checkout imports comments saved under the real path', function()
  local a = make_repo('xi')
  local b = make_repo('omicron')
  local link = vim.fn.tempname() .. '-xi-link'
  assert.truthy(vim.uv.fs_symlink(a, link), 'symlink created')
  seed_legacy(a, b, true)
  cd(link)
  capture_notify(function() restart() end)
  local _, store = mods()
  assert.length(store.all(), 1, 'imported through the symlink')
  os.remove(link)
end)

storage_test('an invalid legacy file writes nothing and stays untouched', function()
  local a = make_repo('pi')
  local config = mods()
  local legacy = config.legacy_storage_file()
  vim.fn.mkdir(vim.fn.fnamemodify(legacy, ':h'), 'p')
  vim.fn.writefile({ '{not json' }, legacy)
  local bytes = read_bytes(legacy)
  cd(a)
  local calls = capture_notify(function() restart() end)
  local _, store = mods()
  assert.length(store.all(), 0, 'nothing imported')
  assert.equals(vim.fn.filereadable(store.path()), 0, 'no comments.json')
  assert.equals(vim.fn.filereadable(store.log_path()), 0, 'no log.jsonl')
  assert.length(mentioning(calls, 'not importing'), 1, 'warned once')
  store.all()
  assert.equals(read_bytes(legacy), bytes, 'legacy untouched')
end)

storage_test('an explicit storage_file behaves as before: one file, no dirs, no import', function()
  local data = fresh_data()
  local a = make_repo('rho')
  local b, file_b = make_repo('sigma')
  seed_legacy(a, b, false)
  local file = vim.fn.tempname() .. '-explicit.json'
  cd(a)
  local calls = capture_notify(function() restart({ storage_file = file }) end)
  local _, store = mods()
  assert.equals(store.path(), file, 'explicit file used')
  assert.length(mentioning(calls, 'imported'), 0, 'no import')
  assert.length(store.all(), 0, 'nothing imported')
  cd(b)
  assert.equals(store.path(), file, 'unchanged after :cd')
  note(file_b, 'global')
  cd(a)
  assert.length(store.all(), 1, 'same global review in every project')
  assert.equals(vim.fn.isdirectory(data .. '/nvim/quickfix-review'), 0, 'no storage dirs created')
  os.remove(file)
end)

-- vim.system replaced by one whose `git rev-parse` fails like a git killed
-- by its timeout while `state.fail` is set; restored afterwards
local function with_failing_git(fn)
  local original = vim.system
  local state = { fail = true }
  vim.system = function(cmd, opts)
    if state.fail and vim.tbl_contains(cmd, 'rev-parse') then
      return { wait = function() return { code = 124, signal = 15, stdout = '', stderr = '' } end }
    end
    return original(cmd, opts)
  end
  local ok, err = pcall(fn, state)
  vim.system = original
  if not ok then error(err, 0) end
end

storage_test('a failed git rev-parse is retried: the review ends up in the root\'s dir', function()
  local data = fresh_data()
  local a = make_repo('tau')
  local sub = a .. '/sub'
  vim.fn.mkdir(sub, 'p')
  cd(sub)
  local expected = data .. '/nvim/quickfix-review/' .. vim.fn.fnamemodify(a, ':t') .. '-'
    .. vim.fn.sha256(a):sub(1, 12)
  with_failing_git(function(git)
    local calls = capture_notify(function() restart() end)
    local _, store = mods()
    local dir
    calls = vim.list_extend(calls, capture_notify(function() dir = store.dir() end))
    assert.truthy(dir ~= expected, 'falls back to the cwd while git fails')
    local warns = mentioning(calls, 'git rev-parse failed in ' .. sub)
    assert.length(warns, 1, 'warned once about the fallback')
    assert.equals(warns[1].level, vim.log.levels.WARN, 'at WARN level')

    git.fail = false
    store._set_retry_ns(0)
    assert.equals(store.dir(), expected, 'the root\'s dir once git answers')
    assert.equals(store.root(), a, 'project root')
  end)
end)

-- In a subdir of a repo, with git failing (the review is in the fallback
-- dir) and the retry window 0: runs `change` with git answering again from
-- the moment the change takes its lock, i.e. after it resolved the project
-- but before its syncs would resolve it again; then `check`, with git
-- failing again so the review is still the fallback dir's.
local function with_window_expiring_mid_change(a, seed, change, check)
  local sub = a .. '/sub'
  vim.fn.mkdir(sub, 'p')
  cd(sub)
  local fallback
  with_failing_git(function(git)
    capture_notify(function() restart() end)
    local _, store = mods()
    fallback = store.dir()
    assert.truthy(fallback ~= default_dir(a), 'in the fallback dir while git fails')
    if seed then seed(store) end
    store._set_retry_ns(0)
    local lock = require('quickfix-review.store.lock')
    local original_lock = lock.with_lock
    lock.with_lock = function(...)
      git.fail = false
      return original_lock(...)
    end
    local ok, err = pcall(change, store)
    lock.with_lock = original_lock
    -- Failing again: the review stays in the fallback dir, to be looked at
    git.fail = true
    if not ok then error(err, 0) end
    assert.equals(store.dir(), fallback, 'still the fallback dir')
    check(store, fallback)
  end)
end

storage_test('a retry window expiring mid-change still writes to the project resolved first', function()
  local a, file_a = make_repo('upsilon')
  with_window_expiring_mid_change(a, nil, function(store)
    assert.truthy(store.add({ filename = file_a, lnum = 1, kind = 'note', body = 'mid' }), 'added')
  end, function(store, fallback)
    local list = store.all()
    assert.length(list, 1, 'the add is visible')
    assert.equals(list[1].body, 'mid', 'the comment added')
    assert.length(test_helper.log_ops(fallback .. '/log.jsonl', 'add'), 1, 'add event in the fallback log')
    assert.equals(vim.fn.filereadable(default_dir(a) .. '/log.jsonl'), 0, 'nothing written to the root\'s dir')
  end)
end)

storage_test('a retry window expiring mid-change still removes from the project resolved first', function()
  local a, file_a = make_repo('phi')
  local id
  with_window_expiring_mid_change(a, function(store)
    assert.truthy(store.add({ filename = file_a, lnum = 1, kind = 'note', body = 'doomed' }), 'seeded')
    id = store.all()[1].id
  end, function(store)
    assert.equals(store.remove(id), 1, 'one removed')
  end, function(store)
    assert.length(store.all(), 0, 'gone')
  end)
end)

storage_test('a cwd outside git is not warned about', function()
  local dir = vim.fn.tempname() .. '-nogit'
  vim.fn.mkdir(dir, 'p')
  cd(dir)
  local calls = capture_notify(function()
    restart()
    local _, store = mods()
    store.all()
  end)
  assert.length(mentioning(calls, 'rev-parse'), 0, 'no warning')
  local _, store = mods()
  assert.equals(store.root(), vim.uv.fs_realpath(dir), 'the cwd is the root')
end)

storage_test('a missing git (ENOENT) is "no repo": no warning and no respawn', function()
  local a = make_repo('sigma')
  cd(a)
  local original = vim.system
  local spawns = 0
  vim.system = function(cmd, opts)
    if vim.tbl_contains(cmd, 'rev-parse') then
      spawns = spawns + 1
      error("ENOENT: no such file or directory (cmd): 'git'")
    end
    return original(cmd, opts)
  end
  local ok, err = pcall(function()
    local calls = capture_notify(function()
      restart()
      local _, store = mods()
      store.all()
    end)
    assert.length(mentioning(calls, 'rev-parse'), 0, 'no rev-parse warning')
    local _, store = mods()
    assert.equals(store.root(), a, 'the cwd is the root')
    local before = spawns
    assert.truthy(before > 0, 'git was tried')
    store._set_retry_ns(0)
    capture_notify(function() store.dir() end)
    assert.equals(spawns, before, 'git not spawned again')
  end)
  vim.system = original
  if not ok then error(err, 0) end
end)

storage_test('storage_file set to the legacy global file leaves it in place for per-project import', function()
  local a, file_a = make_repo('upsilon')
  local b = make_repo('phi')
  local config = mods()
  local legacy = seed_legacy(a, b, false)
  local bytes = read_bytes(legacy)
  cd(a)
  local calls = capture_notify(function()
    restart({ storage_file = config.legacy_storage_file() })
    local _, store = mods()
    assert.length(store.all(), 3, 'the explicit review holds every comment')
  end)
  assert.equals(read_bytes(legacy), bytes, 'the legacy file is left in place')
  assert.equals(vim.fn.filereadable(legacy .. '.pre-log.bak'), 0, 'not renamed to .pre-log.bak')

  -- A change and a sync: comments.json next to the log is looked at again
  calls = capture_notify(function()
    note(file_a, 'explicit note')
    vim.api.nvim_exec_autocmds('CursorHold', {})
    local _, store = mods()
    store.all()
  end)
  assert.equals(read_bytes(legacy), bytes, 'still in place after a sync')
  assert.length(mentioning(calls, 'reappeared'), 0, 'no "reappeared" warning')

  local legacy_log = legacy .. '.events/000001.jsonl'
  local log_bytes = read_bytes(legacy_log)
  assert.truthy(log_bytes, 'the explicit review has a journal')
  local had_state = vim.fn.filereadable(legacy .. '.state.json') == 1
  local state_bytes = read_bytes(legacy .. '.state.json')

  capture_notify(function() restart() end)
  local _, store = mods()
  local list = store.all()
  local bodies = vim.tbl_map(function(c) return c.body end, list)
  table.sort(bodies)
  assert.equals(table.concat(bodies, '|'), 'explicit note|from a', 'a imports its comments, the explicit-mode one too, once each')
  cd(b)
  list = store.all()
  assert.length(list, 1, 'b imports its comment')
  assert.equals(list[1].body, 'from b', 'its own comment')
  assert.equals(read_bytes(legacy_log), log_bytes, 'the legacy log is only read')
  assert.equals(vim.fn.filereadable(legacy .. '.state.json') == 1, had_state, 'no legacy state.json created')
  assert.equals(read_bytes(legacy .. '.state.json'), state_bytes, 'the legacy state.json is untouched')
  assert.equals(read_bytes(legacy), bytes, 'the legacy file is untouched')
end)

storage_test('id-less legacy records are imported once after the legacy file changes', function()
  local a = make_repo('rho')
  local b = make_repo('sigma')
  local config = mods()
  local legacy = seed_legacy(a, b, true)
  cd(a)
  capture_notify(function()
    restart({ storage_file = config.legacy_storage_file() })
    local _, store = mods()
    assert.length(store.all(), 3, 'the legacy log imports the file')
  end)
  -- The file changes after the log imported it (its sha no longer matches)
  local content = vim.json.encode({
    { filename = a .. '/a.txt', lnum = 1, col = 1, text = '[ISSUE] from a' },
    { filename = b .. '/b.txt', lnum = 2, col = 1, text = '[NOTE] from b' },
    { filename = a .. '2/c.txt', lnum = 3, col = 1, text = '[NOTE] from sibling' },
    { filename = a .. '/a.txt', lnum = 2, col = 1, text = '[NOTE] added later' },
  })
  vim.fn.writefile({ content }, legacy)
  local bytes = read_bytes(legacy)
  capture_notify(function() restart() end)
  local _, store = mods()
  local bodies = vim.tbl_map(function(c) return c.body end, store.all())
  table.sort(bodies)
  assert.equals(table.concat(bodies, '|'), 'added later|from a', 'each comment imported once')
  assert.equals(read_bytes(legacy), bytes, 'the legacy file is untouched')
end)

storage_test('a comment deleted while storage_file pointed at the legacy file is not imported', function()
  local a = make_repo('eta')
  local b = make_repo('theta')
  local config = mods()
  seed_legacy(a, b, false)
  cd(a)
  capture_notify(function()
    restart({ storage_file = config.legacy_storage_file() })
    local _, store = mods()
    assert.equals(store.remove('0000000000000001'), 1, 'deleted "from a"')
  end)
  capture_notify(function() restart() end)
  local _, store = mods()
  assert.length(store.all(), 0, 'the deleted comment stays deleted')
end)

storage_test('a legacy log with no legacy file is imported per project', function()
  local a, file_a = make_repo('iota')
  local config = mods()
  local legacy = config.legacy_storage_file()
  vim.fn.mkdir(vim.fn.fnamemodify(legacy, ':h'), 'p')
  cd(a)
  capture_notify(function()
    restart({ storage_file = legacy })
    note(file_a, 'log only')
  end)
  assert.equals(vim.fn.filereadable(legacy), 0, 'no legacy JSON file')
  local calls = capture_notify(function() restart() end)
  local _, store = mods()
  local list = store.all()
  assert.length(list, 1, 'the explicit-mode note is imported')
  assert.equals(list[1].body, 'log only', 'its body')
  assert.length(mentioning(calls, 'imported 1 comments from ' .. legacy .. '.events'), 1, 'names the journal')
end)

storage_test('a legacy file renamed to .pre-log.bak by an older version is still imported', function()
  local a = make_repo('chi')
  local b = make_repo('psi')
  local legacy = seed_legacy(a, b, false)
  assert.truthy(vim.uv.fs_rename(legacy, legacy .. '.pre-log.bak'), 'renamed as the old code did')
  cd(a)
  local calls = capture_notify(function() restart() end)
  local _, store = mods()
  local list = store.all()
  assert.length(list, 1, 'imported from the .pre-log.bak')
  assert.equals(list[1].body, 'from a', 'its own comment')
  assert.length(mentioning(calls, 'imported 1 comments from ' .. legacy .. '.pre-log.bak'), 1, 'names the source')
end)

storage_test('a legacy record with only a bufnr is not imported onto an open buffer', function()
  local a, file_a = make_repo('omega')
  local config = mods()
  local legacy = config.legacy_storage_file()
  vim.fn.mkdir(vim.fn.fnamemodify(legacy, ':h'), 'p')
  -- A buffer under repo a, whose number the old record happens to name
  local buf = vim.fn.bufadd(file_a)
  vim.fn.bufload(buf)
  local content = vim.json.encode({ { bufnr = buf, lnum = 1, col = 1, text = '[NOTE] orphan' } })
  vim.fn.writefile({ content }, legacy)
  cd(a)
  local store
  local calls = capture_notify(function()
    restart()
    _, store = mods()
    assert.length(store.all(), 0, 'not attached to the open buffer\'s file')
  end)
  -- It names no file, so no project's: warned about only beside an import
  assert.length(mentioning(calls, 'not importing'), 0, 'nothing imported, nothing warned')
  assert.equals(read_bytes(legacy), content .. '\n', 'legacy file unchanged')
  vim.cmd('bwipeout! ' .. buf)
end)

storage_test('another project\'s invalid legacy records are not warned about', function()
  local a = make_repo('omega2')
  local b = make_repo('omega3')
  local config = mods()
  local legacy = config.legacy_storage_file()
  vim.fn.mkdir(vim.fn.fnamemodify(legacy, ':h'), 'p')
  vim.fn.writefile({ vim.json.encode({
    { filename = b .. '/omega3.txt', lnum = 'x', col = 1, text = '[NOTE] bad' },
    { filename = b .. '/omega3.txt', lnum = 1, col = 1, text = '[NOTE] good' },
  }) }, legacy)
  for _ = 1, 2 do
    local store
    local calls = capture_notify(function()
      cd(a) -- a :cd syncs too
      restart()
      _, store = mods()
      assert.length(store.all(), 0, 'nothing for repo a')
    end)
    assert.length(mentioning(calls, 'not importing'), 0, 'b\'s record not warned about in a')
  end
  local store
  local calls = capture_notify(function()
    cd(b) -- a :cd syncs too
    restart()
    _, store = mods()
    assert.length(store.all(), 1, 'b imports its valid record')
  end)
  local warns = mentioning(calls, 'not importing 1 comment')
  assert.length(warns, 1, 'b warned about its dropped record')
  assert.equals(warns[1].level, vim.log.levels.WARN, 'at WARN level')
end)

storage_test('an import warns only about its own project\'s invalid records', function()
  local a, file_a = make_repo('omega4')
  local b = make_repo('omega5')
  local config = mods()
  local legacy = config.legacy_storage_file()
  vim.fn.mkdir(vim.fn.fnamemodify(legacy, ':h'), 'p')
  vim.fn.writefile({ vim.json.encode({
    { filename = file_a, lnum = 1, col = 1, text = '[NOTE] from a' },
    { filename = b .. '/omega5.txt', lnum = 'x', col = 1, text = '[NOTE] bad' },
  }) }, legacy)
  cd(a)
  local calls = capture_notify(function()
    restart()
    local _, store = mods()
    assert.length(store.all(), 1, 'a imports its record')
  end)
  assert.length(mentioning(calls, 'not importing'), 0, 'b\'s record not warned about')
end)

-- log.append failing for every path under `dir` while fn runs
-- Run fn with the review journal under `dir` failing to start
local function with_failing_append(dir, fn)
  local segment = require('quickfix-review.store.segment')
  local original_create = segment.create
  segment.create = function(path, ...)
    if vim.startswith(path, dir .. '/') then return nil, 'ENOSPC' end
    return original_create(path, ...)
  end
  local ok, err = pcall(fn)
  segment.create = original_create
  if not ok then error(err, 0) end
end

storage_test('a failing legacy import warns once, not at every sync', function()
  local a = make_repo('kappa')
  local c = make_repo('lambda')
  local config = mods()
  local legacy = config.legacy_storage_file()
  vim.fn.mkdir(vim.fn.fnamemodify(legacy, ':h'), 'p')
  vim.fn.writefile({ vim.json.encode({
    { filename = a .. '/a.txt', lnum = 1, col = 1, text = '[NOTE] kept' },
    { lnum = 1, col = 1, text = '[NOTE] no file' },
  }) }, legacy)
  cd(c)
  capture_notify(function() restart() end)
  local _, store = mods()
  with_failing_append(default_dir(a), function()
    local calls = capture_notify(function()
      cd(a)
      for _ = 1, 3 do store.all() end
    end)
    assert.length(mentioning(calls, 'not importing 1 comment'), 1, 'the dropped record warned about once')
    assert.length(mentioning(calls, 'import from'), 1, 'the failure reported once')
  end)
end)

storage_test('an unreadable legacy log is warned about once while the import keeps failing', function()
  local a = make_repo('mu')
  local b = make_repo('nu')
  local c = make_repo('xi')
  local legacy = seed_legacy(a, b, false)
  vim.fn.writefile({ '{"op":"header","v":99}' }, legacy .. '.log.jsonl')
  cd(c)
  capture_notify(function() restart() end)
  local _, store = mods()
  with_failing_append(default_dir(a), function()
    local calls = capture_notify(function()
      cd(a)
      for _ = 1, 3 do store.all() end
    end)
    assert.length(mentioning(calls, 'not importing from ' .. legacy .. '.log.jsonl'), 1, 'warned once')
  end)
end)

storage_test('a failed import retried by a change does not start the log without it', function()
  local a, file_a = make_repo('rho2')
  local b = make_repo('sigma2')
  local c = make_repo('tau2')
  seed_legacy(a, b, false)
  cd(c)
  capture_notify(function() restart() end)
  local _, store = mods()
  local segment = require('quickfix-review.store.segment')
  local original_create = segment.create
  segment.create = function(dir, n, events, ...)
    for _, ev in ipairs(events) do
      if ev.op == 'import' then return nil, 'ENOSPC' end
    end
    return original_create(dir, n, events, ...)
  end
  local ok, err = pcall(function()
    capture_notify(function()
      cd(a)
      assert.falsy(store.add({ filename = file_a, lnum = 2, kind = 'note', body = 'first' }), 'the add refused')
    end)
    assert.falsy(vim.uv.fs_stat(store.events_dir()), 'no journal started without the import')
    assert.falsy(vim.uv.fs_stat(store.log_path()), 'no log.jsonl either')
  end)
  segment.create = original_create
  if not ok then error(err, 0) end

  local bodies = {}
  capture_notify(function()
    for _, cm in ipairs(store.all()) do bodies[cm.body] = true end
  end)
  assert.truthy(bodies['from a'], 'the legacy comment imported once the import works')
  capture_notify(function() restart() end)
  _, store = mods()
  bodies = {}
  for _, cm in ipairs(store.all()) do bodies[cm.body] = true end
  assert.truthy(bodies['from a'], 'still there after a restart')
  assert.length(test_helper.log_ops(store.log_path(), 'import'), 1, 'one import event')
end)

storage_test('a retry window expiring between the snapshot and the add keeps both in one dir', function()
  local a, file_a = make_repo('chi2')
  local sub = a .. '/sub'
  vim.fn.mkdir(sub, 'p')
  cd(sub)
  with_failing_git(function(git)
    capture_notify(function() restart() end)
    local _, store = mods()
    local fallback = store.dir()
    assert.truthy(fallback ~= default_dir(a), 'in the fallback dir while git fails')
    store._set_retry_ns(0)
    local snapshots = require('quickfix-review.snapshots')
    local original_put, original_input = snapshots.put, vim.fn.input
    snapshots.put = function(...)
      local sha, perr = original_put(...)
      git.fail = false -- the window expires right after the snapshot
      return sha, perr
    end
    vim.fn.input = function() return 'split' end
    local buf
    local ok, err = pcall(function()
      vim.cmd('edit ' .. vim.fn.fnameescape(file_a))
      buf = vim.api.nvim_get_current_buf()
      vim.fn.cursor(2, 1)
      capture_notify(function() qf.add_comment('NOTE') end)
    end)
    snapshots.put, vim.fn.input = original_put, original_input
    git.fail = true
    if buf then vim.cmd('bwipeout! ' .. buf) end
    if not ok then error(err, 0) end

    local adds = test_helper.log_records(fallback .. '/log.jsonl')
    local sha
    for _, r in ipairs(adds) do
      if r.op == 'add' then sha = r.comment.anchor and r.comment.anchor.sha end
    end
    assert.truthy(sha, 'the add event, with its anchor, in the fallback log')
    assert.truthy(vim.uv.fs_stat(fallback .. '/snapshots/' .. sha), 'its snapshot in the same dir')
    local other = default_dir(a)
    assert.equals(vim.fn.filereadable(other .. '/log.jsonl'), 0, 'no log in the root\'s dir')
    assert.falsy(vim.uv.fs_stat(other .. '/snapshots/' .. sha), 'no snapshot in the root\'s dir')
  end)
end)

-- Repo-relative filenames and :ReviewAdopt (bean fgb6)

local function ino(path)
  local st = vim.uv.fs_stat(path)
  return st and st.ino
end

-- The segment files in a storage dir's events/, by name
local function segment_files(dir)
  local out = {}
  for _, name in ipairs(vim.fn.readdir(dir .. '/events') or {}) do
    if name:match('^%d+%.jsonl$') then table.insert(out, name) end
  end
  table.sort(out)
  return out
end

storage_test('a file under the root is logged repo-relative, and shown absolute', function()
  local a, file = make_repo('rel')
  vim.fn.mkdir(a .. '/sub', 'p')
  local nested = a .. '/sub/nested.txt'
  vim.fn.writefile({ 'x' }, nested)
  cd(a)
  restart()
  local _, store = mods()
  note(file, 'top')
  note(nested, 'nested')
  local raw = saved(store.log_path())
  assert.equals(raw[1].filename, 'rel.txt', 'logged relative to the root')
  assert.equals(raw[2].filename, 'sub/nested.txt', 'with forward slashes and no ./')
  local all = store.all()
  assert.equals(all[1].filename, file, 'shown absolute')
  assert.equals(all[2].filename, nested, 'shown absolute')
  assert.equals(qf.comments()[1].filename, file, 'comments() gives absolute filenames')
end)

storage_test('store.get returns the listed comment, absolute and anchored', function()
  local a, file = make_repo('getid')
  cd(a)
  restart()
  local _, store = mods()
  note(file, 'one')
  note(file, 'two')
  for _, c in ipairs(store.all()) do
    local got = store.get(c.id)
    assert.truthy(rawequal(got, c), 'the same table store.all() lists: ' .. c.body)
    assert.equals(got.filename, file, 'absolute filename')
    assert.truthy(got.anchor, 'anchored')
  end
  assert.equals(store.get('no-such-id'), nil, 'nil for an unknown id')
  note(file, 'three')
  local last = store.all()[3]
  assert.truthy(rawequal(store.get(last.id), last), 'a comment added later is found')
end)

storage_test('a file outside the root (or in a sibling sharing its prefix) stays absolute', function()
  local a = make_repo('pi')
  local sibling = a .. '2'
  vim.fn.mkdir(sibling, 'p')
  local sfile = sibling .. '/s.txt'
  vim.fn.writefile({ 'x' }, sfile)
  local outside_dir = vim.fn.tempname() .. '-outside'
  vim.fn.mkdir(outside_dir, 'p')
  local outside = vim.uv.fs_realpath(outside_dir) .. '/o.txt'
  vim.fn.writefile({ 'x' }, outside)
  cd(a)
  restart()
  local _, store = mods()
  note(sfile, 'sibling')
  note(outside, 'outside')
  local raw = saved(store.log_path())
  assert.equals(raw[1].filename, sfile, 'sibling with the root as a prefix stays absolute')
  assert.equals(raw[2].filename, outside, 'file outside the root stays absolute')
  local all = store.all()
  assert.equals(all[1].filename, sfile, 'shown as logged')
  assert.equals(all[2].filename, outside, 'shown as logged')
end)

storage_test('relative filenames resolve against the root, not the cwd', function()
  local a, file = make_repo('rho')
  vim.fn.mkdir(a .. '/deep', 'p')
  cd(a)
  restart()
  local _, store = mods()
  note(file, 'at root')
  cd(a .. '/deep')
  restart()
  _, store = mods()
  assert.equals(store.root(), a, 'same project from a subdir')
  local all = store.all()
  assert.length(all, 1, 'the comment is there')
  assert.equals(all[1].filename, file, 'resolved against the root, not the cwd')
end)

storage_test(':ReviewHistory shows filenames relative to the cwd, not the root', function()
  local a, file = make_repo('rho3')
  vim.fn.mkdir(a .. '/deep', 'p')
  local deep_file = a .. '/deep/inner.txt'
  vim.fn.writefile({ 'x' }, deep_file)
  cd(a)
  restart()
  note(file, 'at root')
  note(deep_file, 'in deep')
  cd(a .. '/deep')
  restart()
  local rows = require('quickfix-review').history_rows()
  assert.length(rows, 2, 'two events')
  assert.equals(rows[2].where, 'inner.txt:1', 'relative to the cwd, not the root')
  -- Outside the cwd, so shown absolute (as :. does), not as if in the cwd
  assert.equals(rows[1].where, file .. ':1', 'resolved against the root, not the cwd')
  assert.truthy(rows[1].text:find(file .. ':1', 1, true), 'shown in the line')
end)

storage_test('a log written with absolute filenames loads unchanged, its bytes untouched', function()
  local a, file = make_repo('sigma')
  cd(a)
  restart()
  local _, store = mods()
  -- A review as written before filenames were relative: segment 1 by hand
  local log = require('quickfix-review.log')
  local jid = log.new_journal_id()
  local events = {
    log.segment_header(jid, 1),
    log.event('add', { comment = { id = 'abs1', filename = file, kind = 'note', body = 'old', lnum = 2,
      end_lnum = 2, created_at = 1 } }),
  }
  local lines = {}
  for i, ev in ipairs(events) do lines[i] = vim.json.encode(ev) end
  local dir = store.dir()
  vim.fn.mkdir(dir .. '/events', 'p')
  local seg = dir .. '/events/000001.jsonl'
  vim.fn.writefile(lines, seg)
  local before = read_bytes(seg)
  restart()
  _, store = mods()
  local all = store.all()
  assert.length(all, 1, 'loaded')
  assert.equals(all[1].filename, file, 'the absolute filename, as before')
  assert.equals(all[1].lnum, 2, 'at its line')
  note(file, 'new')
  assert.equals(read_bytes(seg):sub(1, #before), before, 'the existing events are not rewritten')
  local raw = saved(store.log_path())
  assert.equals(raw[1].filename, file, 'the old record stays absolute')
  assert.equals(raw[2].filename, 'sigma.txt', 'the new one is relative')
end)

storage_test(':ReviewAdopt after moving the project: the comment is at the same file and line', function()
  local a, file = make_repo('mu')
  cd(a)
  restart()
  local _, store = mods()
  assert.truthy(store.add({ filename = file, lnum = 2, kind = 'issue', body = 'moved' }), 'added')
  local old = default_dir(a)
  assert.equals(store.dir(), old, 'in the default dir')
  -- A snapshot, to check it is copied along
  local sha = ('ab'):rep(32)
  vim.fn.mkdir(old .. '/snapshots', 'p')
  vim.fn.writefile({ 'snap' }, old .. '/snapshots/' .. sha)
  store.save()
  cd(original_cwd)
  local moved = a .. '-moved'
  assert.truthy(vim.uv.fs_rename(a, moved), 'project moved')
  moved = vim.uv.fs_realpath(moved)
  cd(moved)
  restart()
  _, store = mods()
  assert.length(store.all(), 0, 'the moved project starts with an empty review')
  local new = store.dir()
  assert.not_equals(new, old, 'in another dir')
  local calls = capture_notify(function() vim.cmd('ReviewAdopt ' .. vim.fn.fnameescape(old)) end)
  assert.length(mentioning(calls, 'Adopted'), 1, 'reported')
  assert.truthy(vim.fn.glob(old .. '/checkpoints/*') ~= '', 'the old review has a checkpoint')
  assert.equals(vim.fn.glob(new .. '/checkpoints/*'), '', 'checkpoints are not copied (rebuilt)')
  local all = store.all()
  assert.length(all, 1, 'the comment is adopted')
  assert.equals(all[1].filename, moved .. '/mu.txt', 'at the same file, in its new place')
  assert.equals(all[1].lnum, 2, 'at the same line')
  assert.equals(saved(store.log_path())[1].filename, 'mu.txt', 'logged relative')
  -- Copies, never links: the adopted segments are new inodes
  local names = segment_files(old)
  assert.truthy(#names > 0, 'the old review has segments')
  assert.equals(table.concat(segment_files(new), ","), table.concat(names, ","), 'every segment copied')
  for _, name in ipairs(names) do
    assert.equals(read_bytes(new .. '/events/' .. name), read_bytes(old .. '/events/' .. name), name .. ' bytes')
    assert.not_equals(ino(new .. '/events/' .. name), ino(old .. '/events/' .. name), name .. ' is a copy')
  end
  assert.truthy(vim.uv.fs_stat(new .. '/snapshots/' .. sha), 'snapshots copied')
  local tomb = vim.json.decode(vim.fn.readfile(new .. '/log.jsonl')[1])
  assert.equals(tomb.moved_to, 'events/', 'the tombstone is written')
  -- Writes go to the adopted copy only
  local before = read_bytes(old .. '/events/' .. names[#names])
  note(moved .. '/mu.txt', 'after adopt')
  assert.length(store.all(), 2, 'added to the adopted review')
  assert.equals(read_bytes(old .. '/events/' .. names[#names]), before, 'the old review is unchanged')
  assert.length(saved(old .. '/log.jsonl'), 1, 'the old review still holds one comment')
end)

storage_test(':ReviewAdopt after moving the project, with a legacy global file to import from', function()
  local a, file = make_repo('omi')
  local x = make_repo('omx')
  local y = make_repo('omy')
  -- Comments only outside the project: nothing to import into it
  local legacy = seed_legacy(x, y, false)
  cd(a)
  restart()
  local _, store = mods()
  assert.truthy(store.add({ filename = file, lnum = 3, kind = 'note', body = 'legacy moved' }), 'added')
  local old = default_dir(a)
  assert.equals(store.dir(), old, 'in the default dir')
  store.save()
  cd(original_cwd)
  local moved = a .. '-moved'
  assert.truthy(vim.uv.fs_rename(a, moved), 'project moved')
  moved = vim.uv.fs_realpath(moved)
  cd(moved)
  restart()
  _, store = mods()
  assert.length(store.all(), 0, 'the moved project starts with an empty review')
  local new = store.dir()
  assert.not_equals(new, old, 'in another dir')
  -- The legacy import ran and found nothing: the dir holds no journal
  assert.length(segment_files(new), 0, 'no journal started by an empty import')
  assert.equals(vim.fn.filereadable(new .. '/log.jsonl'), 0, 'no tombstone written by an empty import')
  local calls = capture_notify(function() vim.cmd('ReviewAdopt ' .. vim.fn.fnameescape(old)) end)
  assert.length(mentioning(calls, 'Adopted'), 1, 'adopted')
  local all = store.all()
  assert.length(all, 1, 'the comment is adopted')
  assert.equals(all[1].filename, moved .. '/omi.txt', 'at the same file, in its new place')
  assert.equals(all[1].lnum, 3, 'at the same line')
  assert.equals(all[1].body, 'legacy moved', 'the comment')
  assert.truthy(vim.fn.filereadable(legacy) == 1, 'the legacy file is still there')
end)

storage_test(':ReviewAdopt refuses when the current project already has a review', function()
  local a, file_a = make_repo('nu')
  local b, file_b = make_repo('xi2')
  cd(a)
  restart()
  local _, store = mods()
  note(file_a, 'in a')
  local old = store.dir()
  cd(b)
  note(file_b, 'in b')
  local new = store.dir()
  local before = read_bytes(new .. '/events/000001.jsonl')
  local old_before = read_bytes(old .. '/events/000001.jsonl')
  local ok, msg
  local calls = capture_notify(function() ok, msg = qf.adopt(old) end)
  assert.falsy(ok, 'refused')
  assert.truthy(msg:find('already has a review', 1, true), 'saying why: ' .. tostring(msg))
  assert.length(mentioning(calls, 'already has a review'), 1, 'reported')
  assert.equals(read_bytes(new .. '/events/000001.jsonl'), before, 'the current review is unchanged')
  assert.equals(read_bytes(old .. '/events/000001.jsonl'), old_before, 'the old review is unchanged')
  local all = store.all()
  assert.length(all, 1, 'still only its own comment')
  assert.equals(all[1].body, 'in b', 'its own')
end)

storage_test(':ReviewAdopt refuses its own dir, a dir with no review, and a storage_file setup', function()
  local a = make_repo('omega')
  local empty = vim.fn.tempname() .. '-empty'
  vim.fn.mkdir(empty, 'p')
  cd(a)
  restart()
  local _, store = mods()
  capture_notify(function()
    local ok, msg = store.adopt(empty)
    assert.falsy(ok, 'a dir with no review is refused')
    assert.truthy(msg:find('no v3 review', 1, true), 'saying why: ' .. msg)
    vim.fn.mkdir(store.dir(), 'p')
    ok, msg = store.adopt(store.dir())
    assert.falsy(ok, 'its own dir is refused')
    assert.truthy(msg:find('own storage dir', 1, true), 'saying why: ' .. msg)
  end)
  restart({ storage_file = test_helper.storage_file })
  _, store = mods()
  local ok, msg = store.adopt(empty)
  assert.falsy(ok, 'refused with an explicit storage_file')
  assert.truthy(msg:find('per-project', 1, true), 'saying why: ' .. msg)
end)

-- Pre-relative absolute filenames and :ReviewAdopt (bean 6t6e)

-- Write, by hand, a review as it was logged before filenames were relative
-- into the storage dir `dir`: segment 1 with an add of each record (absolute
-- filenames) and the tombstone log.jsonl. Returns the journal id.
local function write_absolute_review(dir, records)
  local log = require('quickfix-review.log')
  local jid = log.new_journal_id()
  local lines = { vim.json.encode(log.segment_header(jid, 1)) }
  for _, r in ipairs(records) do
    local c = vim.tbl_extend('force', { kind = 'note', body = r.id, end_lnum = r.lnum, created_at = 1 }, r)
    table.insert(lines, vim.json.encode(log.event('add', { comment = c })))
  end
  vim.fn.mkdir(dir .. '/events', 'p')
  vim.fn.writefile(lines, dir .. '/events/000001.jsonl')
  vim.fn.writefile({ vim.json.encode(log.tombstone(jid)) }, dir .. '/log.jsonl')
  return jid
end

-- Move the project `a` to `a-moved`, open it and adopt the review in `old`
-- Returns: the moved root, its storage dir, and the store module
local function move_and_adopt(a, old)
  cd(original_cwd)
  local moved = a .. '-moved'
  assert.truthy(vim.uv.fs_rename(a, moved), 'project moved')
  moved = vim.uv.fs_realpath(moved)
  cd(moved)
  restart()
  local _, store = mods()
  assert.length(store.all(), 0, 'the moved project starts with an empty review')
  local calls = capture_notify(function() vim.cmd('ReviewAdopt ' .. vim.fn.fnameescape(old)) end)
  assert.length(mentioning(calls, 'Adopted'), 1, 'adopted')
  return moved, store.dir(), store
end

-- The decoded lines of the file at `path`
local function lines_of(path)
  local out = {}
  for _, l in ipairs(vim.fn.readfile(path)) do
    if l ~= '' then table.insert(out, vim.json.decode(l)) end
  end
  return out
end

-- The rebase events in the segments of the storage dir `dir`
local function rebases_in(dir)
  local out = {}
  for _, name in ipairs(segment_files(dir)) do
    for _, ev in ipairs(lines_of(dir .. '/events/' .. name)) do
      if ev.op == 'rebase' then table.insert(out, ev) end
    end
  end
  return out
end

local function by_id(list)
  local out = {}
  for _, c in ipairs(list) do out[c.id] = c end
  return out
end

storage_test(':ReviewAdopt remaps absolute filenames logged before they were relative', function()
  local a, file = make_repo('tau')
  local old = default_dir(a)
  write_absolute_review(old, { { id = 'abs1', filename = file, lnum = 2 } })
  local old_seg = read_bytes(old .. '/events/000001.jsonl')
  local moved, new, store = move_and_adopt(a, old)
  local all = store.all()
  assert.length(all, 1, 'the comment is adopted')
  assert.equals(all[1].filename, moved .. '/tau.txt', 'at the same file, in its new place')
  assert.equals(all[1].lnum, 2, 'at the same line')
  local here = require('quickfix-review.track').positions(moved .. '/tau.txt')
  assert.truthy(here.abs1, 'positions of the moved file list the adopted comment')
  local seg = read_bytes(new .. '/events/000001.jsonl')
  assert.equals(seg:sub(1, #old_seg), old_seg, 'the copied events are not rewritten')
  assert.equals(read_bytes(old .. '/events/000001.jsonl'), old_seg, 'the old review is unchanged')
  assert.equals(saved(store.log_path())[1].filename, file, 'the record still names the old path')
  local evs = lines_of(new .. '/events/000001.jsonl')
  assert.equals(evs[#evs].op, 'rebase', 'a rebase event is appended')
  assert.equals(evs[#evs].from_root, a, 'from the old root')
  assert.length(rebases_in(old), 0, 'none in the old review')
  store.save()
  assert.truthy(vim.fn.glob(new .. '/checkpoints/*.json') ~= '', 'a checkpoint is written')
  restart()
  _, store = mods()
  all = store.all()
  assert.length(all, 1, 'loaded from the checkpoint')
  assert.equals(all[1].filename, moved .. '/tau.txt', 'still remapped after a restart')
  local rows = require('quickfix-review').history_rows('abs1')
  assert.equals(rows[1].where, 'tau.txt:2', 'history shows it under the new root')
end)

storage_test('an absolute path outside the old root is unchanged after adopt', function()
  local a, file = make_repo('ups')
  local sibling = a .. '2'
  vim.fn.mkdir(sibling, 'p')
  vim.fn.writefile({ 'x', 'y' }, sibling .. '/s.txt')
  local outside = vim.uv.fs_realpath(vim.fn.fnamemodify(vim.fn.tempname(), ':h')) .. '/ups-out.txt'
  vim.fn.writefile({ 'x', 'y' }, outside)
  local old = default_dir(a)
  write_absolute_review(old, {
    { id = 'under', filename = file, lnum = 1 },
    { id = 'sib', filename = sibling .. '/s.txt', lnum = 2 },
    { id = 'out', filename = outside, lnum = 2 },
  })
  local moved, new, store = move_and_adopt(a, old)
  local all = by_id(store.all())
  assert.equals(all.under.filename, moved .. '/ups.txt', 'a file under the old root is remapped')
  assert.equals(all.sib.filename, sibling .. '/s.txt', 'a sibling sharing the prefix is unchanged')
  assert.equals(all.out.filename, outside, 'a file outside the tree is unchanged')
  assert.length(rebases_in(new), 1, 'one rebase event')
end)

storage_test('a review with only relative filenames gets no rebase event', function()
  local a, file = make_repo('phi')
  cd(a)
  restart()
  local _, store = mods()
  note(file, 'relative')
  local old = store.dir()
  local _, new = move_and_adopt(a, old)
  assert.length(rebases_in(new), 0, 'no rebase event')
end)

storage_test('a dir whose journal holds only an empty import is accepted by adopt', function()
  local a, file = make_repo('chi')
  cd(a)
  restart()
  local _, store = mods()
  note(file, 'to adopt')
  local old = store.dir()
  store.save()
  local old_jid = vim.json.decode(vim.fn.readfile(old .. '/events/000001.jsonl')[1]).journal_id
  cd(original_cwd)
  local moved = a .. '-moved'
  assert.truthy(vim.uv.fs_rename(a, moved), 'project moved')
  moved = vim.uv.fs_realpath(moved)
  -- A journal holding only an empty import, as reviews created before empty
  -- imports were skipped have
  local new = default_dir(moved)
  local log = require('quickfix-review.log')
  local jid = log.new_journal_id()
  vim.fn.mkdir(new .. '/events', 'p')
  vim.fn.writefile({
    vim.json.encode(log.segment_header(jid, 1)),
    vim.json.encode(log.event('import', { comments = {}, source_sha256 = ('0'):rep(64) })),
  }, new .. '/events/000001.jsonl')
  vim.fn.writefile({ vim.json.encode(log.tombstone(jid)) }, new .. '/log.jsonl')
  cd(moved)
  restart()
  _, store = mods()
  assert.equals(store.dir(), new, 'the planted dir')
  assert.length(store.all(), 0, 'empty')
  local ok, msg = store.adopt(old)
  assert.truthy(ok, 'adopted: ' .. tostring(msg))
  local all = store.all()
  assert.length(all, 1, 'the comment is adopted')
  assert.equals(all[1].body, 'to adopt', 'the comment')
  assert.equals(vim.json.decode(vim.fn.readfile(new .. '/events/000001.jsonl')[1]).journal_id, old_jid,
    'segment 1 is the old journal\'s')
  assert.equals(vim.json.decode(vim.fn.readfile(new .. '/log.jsonl')[1]).log_id, old_jid,
    'the tombstone names the adopted journal')
  assert.equals(vim.fn.glob(new .. '/events.replaced-*'), '', 'the empty journal is gone')
  assert.equals(vim.fn.glob(new .. '/events.adopt-*'), '', 'no staging dir is left')

  -- A cleared review is still a review
  local c, file_c = make_repo('psi')
  cd(c)
  note(file_c, 'cleared')
  store.clear()
  local before = read_bytes(store.dir() .. '/events/000001.jsonl')
  capture_notify(function()
    ok, msg = store.adopt(old)
  end)
  assert.falsy(ok, 'a cleared review is refused')
  assert.truthy(msg:find('already has a review', 1, true), 'saying why: ' .. tostring(msg))
  assert.equals(read_bytes(store.dir() .. '/events/000001.jsonl'), before, 'unchanged')
end)

storage_test('a checkpoint from before the STATE_VERSION bump is ignored and rebuilt', function()
  local a, file = make_repo('omg')
  local old = default_dir(a)
  write_absolute_review(old, { { id = 'abs1', filename = file, lnum = 2 } })
  local moved, new, store = move_and_adopt(a, old)
  local reduce = require('quickfix-review.reduce')
  local seg = new .. '/events/000001.jsonl'
  local jid = vim.json.decode(vim.fn.readfile(seg)[1]).journal_id
  local size = vim.uv.fs_stat(seg).size
  vim.fn.mkdir(new .. '/checkpoints', 'p')
  vim.fn.writefile({ vim.json.encode({
    v = 3, state_v = reduce.STATE_VERSION - 1, journal_id = jid, seg = 1, offset = size, lines = 3,
    state = { comments = { { id = 'marker', filename = moved .. '/omg.txt', lnum = 1, kind = 'note',
      body = 'marker' } }, trash = vim.empty_dict(), removed = {} },
    imports = {},
  }) }, new .. '/checkpoints/' .. string.format('%06d-%012d.json', 1, size))
  restart()
  _, store = mods()
  local all = store.all()
  assert.length(all, 1, 'rebuilt from the events')
  assert.equals(all[1].id, 'abs1', 'the marker is not loaded')
  assert.equals(all[1].filename, moved .. '/omg.txt', 'remapped')
  store.save()
  local current = 0
  for _, path in ipairs(vim.fn.glob(new .. '/checkpoints/*.json', false, true)) do
    local doc = vim.json.decode(read_bytes(path))
    if doc.state_v == reduce.STATE_VERSION then
      current = current + 1
      assert.equals(doc.state.rebases[1], a, 'the checkpoint holds the rebase')
    end
  end
  assert.equals(current, 1, 'a checkpoint of the current STATE_VERSION is written')
end)

storage_test('chained adopts: absolute filenames from the first root follow to the last', function()
  local a, file = make_repo('kap')
  local old = default_dir(a)
  write_absolute_review(old, { { id = 'abs1', filename = file, lnum = 3 } })
  local b, b_dir, store = move_and_adopt(a, old)
  note(b .. '/kap.txt', 'in b')
  store.save()
  local c, c_dir
  c, c_dir, store = move_and_adopt(b, b_dir)
  local all = by_id(store.all())
  assert.equals(all.abs1.filename, c .. '/kap.txt', 'the first root\'s comment is under the last root')
  assert.equals(all.abs1.lnum, 3, 'at its line')
  local rebases = rebases_in(c_dir)
  assert.length(rebases, 1, 'one rebase event')
  assert.equals(rebases[1].from_root, a, 'the first root\'s')
end)

-- Put the test configuration back for the files that run after this one
cd(original_cwd)
vim.env.XDG_DATA_HOME = original_data_home
test_helper.cleanup_test_environment()

return assert
