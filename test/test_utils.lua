-- Tests for utility functions
local assert = dofile('test/assertions.lua')

print('\nRunning utility tests...')

-- Add current directory to runtime path
vim.opt.runtimepath:prepend(vim.fn.getcwd())

-- Clear cached modules
package.loaded['quickfix-review.utils'] = nil

local utils = require('quickfix-review.utils')

assert.run_test('files_match with identical paths', function()
  local result = utils.files_match('/home/user/file.txt', '/home/user/file.txt')
  assert.truthy(result, 'identical paths match')
end)

assert.run_test('files_match with different paths', function()
  local result = utils.files_match('/home/user/file1.txt', '/home/user/file2.txt')
  assert.falsy(result, 'different paths do not match')
end)

assert.run_test('files_match normalizes relative and absolute', function()
  -- Create a test file
  local test_file = 'test_utils_file.txt'
  local f = io.open(test_file, 'w')
  if f then
    f:write('test')
    f:close()
  end

  local cwd = vim.fn.getcwd()
  local abs_path = cwd .. '/' .. test_file
  local result = utils.files_match(test_file, abs_path)

  os.remove(test_file)
  assert.truthy(result, 'relative and absolute paths match')
end)

assert.run_test('is_special_buffer returns false for regular files', function()
  -- Create and open a regular file
  local test_file = 'test_regular_file.txt'
  local f = io.open(test_file, 'w')
  if f then
    f:write('test content')
    f:close()
  end
  vim.cmd('edit ' .. test_file)

  local result = utils.is_special_buffer()
  os.remove(test_file)

  assert.falsy(result, 'regular file is not special buffer')
end)

assert.run_test('get_real_filepath returns path for regular files', function()
  local test_file = 'test_filepath.txt'
  local f = io.open(test_file, 'w')
  if f then
    f:write('test')
    f:close()
  end
  vim.cmd('edit ' .. test_file)

  local result = utils.get_real_filepath()
  os.remove(test_file)

  assert.matches(result, 'test_filepath%.txt', 'returns file path')
end)

-- Resolve `name` through a scratch buffer while a different buffer is current
local function real_path_for_name(name)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, name)
  local ok, result = pcall(utils.get_real_filepath, buf)
  vim.cmd('bwipeout! ' .. buf)
  assert.truthy(ok, 'get_real_filepath did not error for ' .. name)
  return result
end

local repo_root = vim.fn.getcwd()
local expected_real = repo_root .. '/lua/quickfix-review/utils.lua'

assert.run_test('git_toplevel returns repo root for the repo dir', function()
  assert.equals(utils.git_toplevel(repo_root), repo_root, 'toplevel of repo root')
end)

assert.run_test('git_toplevel accepts a file path', function()
  assert.equals(utils.git_toplevel(expected_real), repo_root, 'toplevel of a file in the repo')
end)

assert.run_test('git_toplevel returns nil outside git', function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  local result = utils.git_toplevel(dir)
  vim.fn.delete(dir, 'rf')
  assert.equals(result, nil, 'no toplevel outside git')
end)

-- vim.system replaced by one that counts calls and, while `fail` is set,
-- answers like a git killed by its timeout
local function with_counted_git(fn)
  local original = vim.system
  local state = { calls = 0, fail = false }
  vim.system = function(cmd, opts)
    state.calls = state.calls + 1
    if state.fail then
      return { wait = function() return { code = 124, signal = 15, stdout = '', stderr = '' } end }
    end
    return original(cmd, opts)
  end
  local ok, err = pcall(fn, state)
  vim.system = original
  if not ok then error(err, 0) end
end

assert.run_test('git_toplevel does not cache a failed or timed-out git', function()
  -- A dir not asked about yet, inside the repo
  local sub = repo_root .. '/test'
  with_counted_git(function(git)
    git.fail = true
    local root, transient = utils.git_toplevel(sub)
    assert.equals(root, nil, 'no root while git fails')
    assert.equals(transient, true, 'reported as transient')
    git.fail = false
    utils._set_retry_ns(0)
    root, transient = utils.git_toplevel(sub)
    assert.equals(root, repo_root, 'asked again once git answers')
    assert.equals(transient, false, 'a definitive answer')
    local calls = git.calls
    assert.equals(utils.git_toplevel(sub), repo_root, 'cached')
    assert.equals(git.calls, calls, 'a cached root spawns no git')
  end)
  utils._set_retry_ns(5e9)
end)

assert.run_test('git_toplevel leaves an always-slow git alone within the retry window', function()
  local sub = repo_root .. '/lua'
  with_counted_git(function(git)
    git.fail = true
    local root, transient = utils.git_toplevel(sub)
    assert.equals(root, nil, 'no root while git times out')
    assert.equals(transient, true, 'reported as transient')
    root, transient = utils.git_toplevel(sub)
    assert.equals(root, nil, 'still no root')
    assert.equals(transient, true, 'still transient (not "no repo")')
    assert.equals(git.calls, 1, 'git spawned once within the window')
    utils._set_retry_ns(0)
    git.fail = false
    root, transient = utils.git_toplevel(sub)
    assert.equals(root, repo_root, 'asked again after the window')
    assert.equals(transient, false, 'a definitive answer')
    assert.equals(git.calls, 2, 'one more spawn')
  end)
  utils._set_retry_ns(5e9)
end)

-- vim.system replaced by one that counts calls and throws `msg` like a
-- failed spawn (error() at level 1, so with a location prefix, as nvim does)
local function with_throwing_git(msg, fn)
  local original = vim.system
  local state = { calls = 0 }
  vim.system = function()
    state.calls = state.calls + 1
    error(msg)
  end
  local ok, err = pcall(fn, state)
  vim.system = original
  if not ok then error(err, 0) end
end

assert.run_test('git_toplevel treats a missing git (ENOENT) as "no repo" and caches it', function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  with_throwing_git("ENOENT: no such file or directory (cmd): 'git'", function(git)
    local root, transient = utils.git_toplevel(dir)
    assert.equals(root, nil, 'no toplevel without git')
    assert.equals(transient, false, 'a definitive answer')
    assert.equals(git.calls, 1, 'git spawned once')
    utils.git_toplevel(dir)
    assert.equals(git.calls, 1, 'not spawned again')
  end)
  vim.fn.delete(dir, 'rf')
end)

assert.run_test('git_toplevel treats another spawn error as transient', function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  with_throwing_git('EMFILE: too many open files', function(git)
    local root, transient = utils.git_toplevel(dir)
    assert.equals(root, nil, 'no toplevel')
    assert.equals(transient, true, 'transient')
    utils._set_retry_ns(0)
    utils.git_toplevel(dir)
    assert.equals(git.calls, 2, 'asked again after the window')
  end)
  utils._set_retry_ns(5e9)
  vim.fn.delete(dir, 'rf')
end)

assert.run_test('git_toplevel caches "not a git repo" without a transient flag', function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  with_counted_git(function(git)
    local root, transient = utils.git_toplevel(dir)
    assert.equals(root, nil, 'no toplevel outside git')
    assert.equals(transient, false, 'a definitive answer')
    local calls = git.calls
    utils.git_toplevel(dir)
    assert.equals(git.calls, calls, 'the miss is cached')
  end)
  vim.fn.delete(dir, 'rf')
end)

assert.run_test('get_real_filepath resolves diffview names (single slash)', function()
  local result = real_path_for_name('diffview://' .. repo_root .. '/.git/abc123/lua/quickfix-review/utils.lua')
  assert.equals(result, expected_real, 'diffview single-slash form')
end)

assert.run_test('get_real_filepath resolves diffview names (double slash)', function()
  local result = real_path_for_name('diffview://' .. repo_root .. '/.git//:0:/lua/quickfix-review/utils.lua')
  assert.equals(result, expected_real, 'diffview double-slash form')
end)

assert.run_test('get_real_filepath resolves fugitive names', function()
  local result = real_path_for_name('fugitive://' .. repo_root .. '/.git//0/lua/quickfix-review/utils.lua')
  assert.equals(result, expected_real, 'fugitive form')
end)

assert.run_test('get_real_filepath resolves codediff names', function()
  -- The two shapes the existing extraction accepts: a leading segment before
  -- the repo-relative path, or a `//:<rev>/` marker
  local result = real_path_for_name('codediff:///abc123/lua/quickfix-review/utils.lua')
  assert.equals(result, expected_real, 'codediff <rev>/<path> form')
  result = real_path_for_name('codediff:///x//:0/lua/quickfix-review/utils.lua')
  assert.equals(result, expected_real, 'codediff //:<rev>/<path> form')
end)

assert.run_test('get_real_filepath uses the repo root from a subdirectory cwd', function()
  vim.cmd('lcd lua')
  local ok, result = pcall(real_path_for_name,
    'fugitive://' .. repo_root .. '/.git//0/lua/quickfix-review/utils.lua')
  vim.cmd('lcd ' .. vim.fn.fnameescape(repo_root))
  assert.truthy(ok, 'resolution did not error')
  assert.equals(result, expected_real, 'fugitive path resolved against repo root, not cwd')
end)

-- Worktree and submodule git dirs live under the main repo's .git, not in the
-- work tree they belong to
do
  local function run(cmd)
    local r = vim.system(cmd, { text = true }):wait()
    if r.code ~= 0 then
      error('command failed: ' .. table.concat(cmd, ' ') .. ': ' .. (r.stderr or ''))
    end
    return vim.trim(r.stdout or '')
  end
  local function git(dir, ...)
    return run(vim.list_extend(
      { 'git', '-C', dir, '-c', 'user.name=Test', '-c', 'user.email=test@example.com',
        '-c', 'commit.gpgsign=false', '-c', 'protocol.file.allow=always' },
      { ... }))
  end
  local function make_repo(dir)
    vim.fn.mkdir(dir, 'p')
    git(dir, 'init', '-q')
    vim.fn.writefile({ 'hello' }, dir .. '/file.txt')
    git(dir, 'add', 'file.txt')
    git(dir, 'commit', '-q', '-m', 'init')
    return dir
  end
  local function real(p) return vim.fn.resolve(vim.fn.fnamemodify(p, ':p')) end

  local tmp = vim.fn.resolve(vim.fn.tempname())
  local ok_setup, setup_err = pcall(function()
    make_repo(tmp .. '/main')
    make_repo(tmp .. '/src')
    git(tmp .. '/main', 'worktree', 'add', '-q', tmp .. '/wt')
    git(tmp .. '/main', 'submodule', 'add', '-q', tmp .. '/src', 'sub')
  end)
  local main, wt = tmp .. '/main', tmp .. '/wt'

  assert.run_test('get_real_filepath resolves worktree git-dir names to the worktree', function()
    assert.truthy(ok_setup, 'repo setup: ' .. tostring(setup_err))
    local want = real(wt .. '/file.txt')
    assert.equals(real(real_path_for_name('fugitive://' .. main .. '/.git/worktrees/wt//0/file.txt')),
      want, 'fugitive worktree name')
    assert.equals(real(real_path_for_name('diffview://' .. main .. '/.git/worktrees/wt/abc123/file.txt')),
      want, 'diffview worktree name')
  end)

  assert.run_test('get_real_filepath resolves submodule git-dir names to the submodule', function()
    assert.truthy(ok_setup, 'repo setup: ' .. tostring(setup_err))
    local want = real(main .. '/sub/file.txt')
    assert.equals(real(real_path_for_name('fugitive://' .. main .. '/.git/modules/sub//0/file.txt')),
      want, 'fugitive submodule name')
    assert.equals(real(real_path_for_name('diffview://' .. main .. '/.git/modules/sub/abc123/file.txt')),
      want, 'diffview submodule name')
  end)

  assert.run_test('get_real_filepath caches the git-dir work tree', function()
    assert.truthy(ok_setup, 'repo setup: ' .. tostring(setup_err))
    local name = 'fugitive://' .. main .. '/.git/modules/sub//0/file.txt'
    real_path_for_name(name)
    local orig, calls = vim.system, 0
    vim.system = function(...) calls = calls + 1 return orig(...) end
    local ok, err = pcall(real_path_for_name, name)
    vim.system = orig
    assert.truthy(ok, tostring(err))
    assert.equals(calls, 0, 'no git call on a repeat resolution')
  end)

  assert.run_test('get_real_filepath leaves an always-slow submodule git alone within the retry window', function()
    assert.truthy(ok_setup, 'repo setup: ' .. tostring(setup_err))
    -- A git dir not resolved yet, so its work tree is not cached
    local gitdir = main .. '/.git/modules/slow'
    vim.fn.mkdir(gitdir, 'p')
    local name = 'fugitive://' .. gitdir .. '//0/file.txt'
    with_counted_git(function(git)
      git.fail = true
      local ok, err = pcall(real_path_for_name, name)
      assert.truthy(ok, tostring(err))
      ok, err = pcall(real_path_for_name, name)
      assert.truthy(ok, tostring(err))
      assert.equals(git.calls, 1, 'git spawned once within the window')
    end)
  end)

  assert.run_test('get_real_filepath leaves fugitive summary and commit names unresolved', function()
    assert.equals(real_path_for_name('fugitive://' .. repo_root .. '/.git//'),
      'fugitive://' .. repo_root .. '/.git//', 'summary name unchanged')
    local commit = 'fugitive://' .. repo_root .. '/.git//0123456789abcdef'
    assert.equals(real_path_for_name(commit), commit, 'commit name unchanged')
    assert.truthy(utils.is_unresolved(commit), 'commit name is unresolved')
    assert.equals(real_path_for_name('diffview://null'), 'diffview://null', 'diffview://null unchanged')
  end)

  vim.fn.delete(tmp, 'rf')
end

assert.run_test('files_match treats a symlink and its target as the same file', function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  local real = dir .. '/real.txt'
  local link = dir .. '/link.txt'
  local f = io.open(real, 'w')
  if f then
    f:write('x')
    f:close()
  end
  local linked = vim.uv.fs_symlink(real, link)
  local result = utils.files_match(link, real)
  vim.fn.delete(dir, 'rf')
  assert.truthy(linked, 'symlink created')
  assert.truthy(result, 'symlink matches its target')
end)

return assert
