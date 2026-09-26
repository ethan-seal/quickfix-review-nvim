-- Tests for utility functions
local assert = dofile('test/assertions.lua')

print('\nRunning utility tests...')

-- Add current directory to runtime path
vim.opt.runtimepath:prepend(vim.fn.getcwd())

-- Clear cached modules
package.loaded['quickfix-review.utils'] = nil

local utils = require('quickfix-review.utils')

assert.run_test('parse_comment_type extracts ISSUE', function()
  local result = utils.parse_comment_type('[ISSUE] Some text')
  assert.equals(result, 'ISSUE', 'parse basic ISSUE')
end)

assert.run_test('parse_comment_type extracts SUGGESTION', function()
  local result = utils.parse_comment_type('[SUGGESTION] Some text')
  assert.equals(result, 'SUGGESTION', 'parse SUGGESTION')
end)

assert.run_test('parse_comment_type extracts NOTE', function()
  local result = utils.parse_comment_type('[NOTE] Some text')
  assert.equals(result, 'NOTE', 'parse NOTE')
end)

assert.run_test('parse_comment_type extracts PRAISE', function()
  local result = utils.parse_comment_type('[PRAISE] Some text')
  assert.equals(result, 'PRAISE', 'parse PRAISE')
end)

assert.run_test('parse_comment_type extracts QUESTION', function()
  local result = utils.parse_comment_type('[QUESTION] Some text')
  assert.equals(result, 'QUESTION', 'parse QUESTION')
end)

assert.run_test('parse_comment_type extracts INSIGHT', function()
  local result = utils.parse_comment_type('[INSIGHT] Some text')
  assert.equals(result, 'INSIGHT', 'parse INSIGHT')
end)

assert.run_test('parse_comment_type handles multiline format', function()
  local result = utils.parse_comment_type('[ISSUE:L3-7] Some text')
  assert.equals(result, 'ISSUE', 'parse multiline ISSUE')
end)

assert.run_test('parse_comment_type defaults to NOTE', function()
  local result = utils.parse_comment_type('No brackets here')
  assert.equals(result, 'NOTE', 'defaults to NOTE')
end)

assert.run_test('parse_comment_type handles empty string', function()
  local result = utils.parse_comment_type('')
  assert.equals(result, 'NOTE', 'empty string defaults to NOTE')
end)

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
