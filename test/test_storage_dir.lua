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

local function saved(path)
  local doc = vim.json.decode(read_bytes(path), { luanil = { object = true, array = true } })
  assert.equals(doc.version, 2, 'saved as version 2')
  return doc.comments
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
  assert.equals(store.root(), a, 'project root')
end)

storage_test('two repos get different dirs and their comments stay apart', function()
  local a, file_a = make_repo('alpha')
  local b, file_b = make_repo('beta')
  cd(a)
  restart()
  local _, store = mods()
  note(file_a, 'in alpha')
  local path_a = store.path()

  cd(b)
  local path_b = store.path()
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
  assert.length(saved(target .. '/comments.json'), 1, 'written into the new dir')
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
    local on_disk = saved(store.path())
    assert.length(on_disk, 1, 'one comment in comments.json')
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
    assert.equals(vim.fn.filereadable(legacy .. '.pre-v2.bak'), 0, 'no upgrade backup')
    assert.equals(vim.fn.filereadable(legacy .. '.pre-repair.bak'), 0, 'no repair backup')
  end)
end

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

  calls = capture_notify(function() cd(c) end)
  assert.length(store.all(), 0, 'no comments for an unrelated project')
  assert.length(mentioning(calls, 'imported'), 0, 'no notice for 0 imported')
  assert.length(saved(store.path()), 0, 'empty comments.json written, so no re-scan')
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

-- Put the test configuration back for the files that run after this one
cd(original_cwd)
vim.env.XDG_DATA_HOME = original_data_home
test_helper.cleanup_test_environment()

return assert
