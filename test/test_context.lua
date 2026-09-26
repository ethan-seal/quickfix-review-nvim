-- Tests for context capture (git commit + snippet at comment time)
local assert = dofile('test/assertions.lua')

print('\nRunning context tests...')

vim.opt.runtimepath:prepend(vim.fn.getcwd())
package.loaded['quickfix-review.context'] = nil
local context = require('quickfix-review.context')

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
      '-c', 'commit.gpgsign=false' },
    { ... }))
end

local function write_file(path, lines)
  vim.fn.writefile(lines, path)
end

-- Temp repo with one commit of `file.txt` containing `lines`
local function make_repo(lines)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  git(dir, 'init', '-q')
  write_file(dir .. '/file.txt', lines)
  git(dir, 'add', 'file.txt')
  git(dir, 'commit', '-q', '-m', 'init')
  return dir
end

-- Run fn with nvim's cwd set to dir, restoring it afterwards
local function with_cwd(dir, fn)
  local prev = vim.fn.getcwd()
  vim.fn.chdir(dir)
  local ok, err = pcall(fn)
  vim.fn.chdir(prev)
  if not ok then error(err, 0) end
end

local function open(path)
  vim.cmd('edit! ' .. vim.fn.fnameescape(path))
  return vim.api.nvim_get_current_buf()
end

local function wipe(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end
end

-- _parse_hunks / _find_hunk_for_line

local multi_diff = {
  'diff --git a/f b/f',
  'index 1..2 100644',
  '--- a/f',
  '+++ b/f',
  '@@ -1,3 +1,4 @@',
  ' a',
  '+b',
  ' c',
  ' d',
  '@@ -10,2 +11,3 @@ func',
  ' x',
  '-y',
  '+y2',
  '+z',
}

assert.run_test('_parse_hunks parses a single hunk', function()
  local hunks = context._parse_hunks({ '--- a/f', '+++ b/f', '@@ -5,2 +5,3 @@', ' a', '+b', ' c' })
  assert.length(hunks, 1, 'hunk count')
  assert.equals(hunks[1].new_start, 5, 'new_start')
  assert.equals(hunks[1].new_count, 3, 'new_count')
  assert.length(hunks[1].lines, 4, 'header + 3 body lines')
end)

assert.run_test('_parse_hunks parses multiple hunks, ignoring file headers', function()
  local hunks = context._parse_hunks(multi_diff)
  assert.length(hunks, 2, 'hunk count')
  assert.equals(hunks[1].new_start, 1, 'first new_start')
  assert.equals(hunks[1].new_count, 4, 'first new_count')
  assert.length(hunks[1].lines, 5, 'first hunk lines')
  assert.equals(hunks[2].new_start, 11, 'second new_start')
  assert.equals(hunks[2].new_count, 3, 'second new_count')
  assert.equals(hunks[2].lines[1], '@@ -10,2 +11,3 @@ func', 'second header')
end)

assert.run_test('_parse_hunks defaults an omitted count to 1', function()
  local hunks = context._parse_hunks({ '@@ -3 +3 @@', '-a', '+b' })
  assert.equals(hunks[1].new_count, 1, 'new_count')
end)

assert.run_test('_find_hunk_for_line finds the hunk covering a line', function()
  local hunks = context._parse_hunks(multi_diff)
  assert.equals(context._find_hunk_for_line(hunks, 1), hunks[1], 'first line of hunk 1')
  assert.equals(context._find_hunk_for_line(hunks, 4), hunks[1], 'last line of hunk 1')
  assert.equals(context._find_hunk_for_line(hunks, 12), hunks[2], 'inside hunk 2')
  assert.equals(context._find_hunk_for_line(hunks, 13), hunks[2], 'last line of hunk 2')
end)

assert.run_test('_find_hunk_for_line returns nil outside any hunk', function()
  local hunks = context._parse_hunks(multi_diff)
  assert.falsy(context._find_hunk_for_line(hunks, 5), 'between hunks')
  assert.falsy(context._find_hunk_for_line(hunks, 14), 'after last hunk')
  assert.falsy(context._find_hunk_for_line({}, 1), 'no hunks')
end)

assert.run_test('_find_hunk_for_line handles a pure insertion hunk', function()
  local hunks = context._parse_hunks({ '@@ -4,0 +5,2 @@', '+new1', '+new2' })
  assert.equals(hunks[1].new_start, 5, 'new_start')
  assert.equals(hunks[1].new_count, 2, 'new_count')
  assert.equals(context._find_hunk_for_line(hunks, 5), hunks[1], 'first inserted line')
  assert.equals(context._find_hunk_for_line(hunks, 6), hunks[1], 'second inserted line')
  assert.falsy(context._find_hunk_for_line(hunks, 4), 'line before insertion')
  assert.falsy(context._find_hunk_for_line(hunks, 7), 'line after insertion')
end)

-- capture

assert.run_test('capture uses the file\'s repo, not nvim\'s cwd repo', function()
  local repo_a = make_repo({ 'a1', 'a2' })
  local repo_b = make_repo({ 'b1', 'b2', 'b3' })
  -- Second commit in B so HEAD~1 exists and the diff path is exercised
  write_file(repo_b .. '/file.txt', { 'b1', 'changed', 'b3' })
  git(repo_b, 'commit', '-q', '-am', 'change')
  local head_a = git(repo_a, 'rev-parse', 'HEAD')
  local head_b = git(repo_b, 'rev-parse', 'HEAD')
  assert.not_equals(head_a, head_b, 'repos have distinct HEADs')

  with_cwd(repo_a, function()
    local file = repo_b .. '/file.txt'
    local bufnr = open(file)
    local ctx = context.capture(file, 2, 2)
    wipe(bufnr)
    assert.equals(ctx.commit, head_b, 'commit is repo B HEAD')
    assert.equals(ctx.commit_short, head_b:sub(1, 8), 'commit_short')
    assert.equals(ctx.snippet_source, 'diff', 'snippet from the diff')
    assert.contains(ctx.snippet, '+changed', 'hunk contains the change')
    assert.falsy(ctx.buffer_modified, 'buffer not modified')
  end)
  vim.fn.delete(repo_a, 'rf')
  vim.fn.delete(repo_b, 'rf')
end)

assert.run_test('capture of a non-git file has no commit and a buffer snippet', function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  local file = dir .. '/plain.txt'
  write_file(file, { 'one', 'two', 'three' })
  local bufnr = open(file)
  local ok, ctx = pcall(context.capture, file, 2, 2)
  wipe(bufnr)
  vim.fn.delete(dir, 'rf')
  assert.truthy(ok, 'capture does not error')
  assert.falsy(ctx.commit, 'no commit')
  assert.falsy(ctx.commit_short, 'no commit_short')
  assert.equals(ctx.snippet_source, 'buffer', 'buffer snippet')
  assert.length(ctx.snippet, 3, 'snippet covers the file')
  assert.equals(ctx.snippet[2], '   2  two', 'snippet line 2')
end)

assert.run_test('capture with unsaved edits snippets the buffer lines', function()
  local repo = make_repo({ 'l1', 'l2', 'l3', 'l4' })
  local file = repo .. '/file.txt'
  local bufnr = open(file)
  -- Insert a line above: on disk line 3 is 'l3', in the buffer it is 'l2'
  vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { 'inserted' })
  local ctx = context.capture(file, 3, 3, bufnr)
  wipe(bufnr)
  local head = git(repo, 'rev-parse', 'HEAD')
  vim.fn.delete(repo, 'rf')
  assert.equals(ctx.commit, head, 'commit still recorded')
  assert.equals(ctx.snippet_source, 'buffer', 'buffer snippet')
  assert.truthy(ctx.buffer_modified, 'buffer_modified recorded')
  assert.contains(ctx.snippet, '   3  l2', 'commented line matches the buffer')
  assert.contains(ctx.snippet, '   1  inserted', 'unsaved line present')
end)

return assert
