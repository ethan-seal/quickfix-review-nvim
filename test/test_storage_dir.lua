-- Tests for the per-project storage directory: project roots, :cd switching,
-- the one-time import from the legacy global file, and the deprecated
-- storage_file option
local test_helper = dofile('test/init.lua')
local assert = dofile('test/assertions.lua')

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
  assert.equals(store.state_path(), expected .. '/state.json', 'cache')
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
  assert.length(test_helper.log_ops(store.log_path(), 'import'), 1, 'an empty import logged, so no re-scan')
  assert.length(saved(store.log_path()), 0, 'nothing live')
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

  local legacy_log = legacy .. '.log.jsonl'
  local log_bytes = read_bytes(legacy_log)
  assert.truthy(log_bytes, 'the explicit review has a log')
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
  assert.length(mentioning(calls, 'imported 1 comments from ' .. legacy .. '.log.jsonl'), 1, 'names the log')
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
  local calls = capture_notify(function() restart() end)
  local _, store = mods()
  assert.length(store.all(), 0, 'not attached to the open buffer\'s file')
  local warns = mentioning(calls, 'not importing 1 comment')
  assert.length(warns, 1, 'warned about the dropped record')
  assert.equals(warns[1].level, vim.log.levels.WARN, 'at WARN level')
  assert.equals(read_bytes(legacy), content .. '\n', 'legacy file unchanged')
  vim.cmd('bwipeout! ' .. buf)
end)

-- Put the test configuration back for the files that run after this one
cd(original_cwd)
vim.env.XDG_DATA_HOME = original_data_home
test_helper.cleanup_test_environment()

return assert
