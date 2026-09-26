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

assert.run_test('anchor lines drop every trailing CR, as a snapshot does', function()
  local a = context.anchor(2, 2, 0, { lines = { 'a\r\r', 'x\r\r', 'b\r' }, sha = string.rep('0', 64) })
  assert.equals(table.concat(a.lines, '|'), 'x', 'commented line')
  assert.equals(table.concat(a.before, '|'), 'a', 'before')
  assert.equals(table.concat(a.after, '|'), 'b', 'after')
end)

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

assert.run_test('capture in a dir created after the first lookup gets the commit', function()
  local repo = make_repo({ 'x' })
  local file = repo .. '/newdir/f.txt'
  pcall(context.capture, file, 1, 1)
  vim.fn.mkdir(repo .. '/newdir', 'p')
  write_file(file, { 'one', 'two' })
  local bufnr = open(file)
  local ok, ctx = pcall(context.capture, file, 1, 1, bufnr)
  wipe(bufnr)
  local head = git(repo, 'rev-parse', 'HEAD')
  vim.fn.delete(repo, 'rf')
  assert.truthy(ok, 'capture does not error: ' .. tostring(ctx))
  assert.equals(ctx.commit, head, 'commit captured')
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

-- literal_env: the user's GIT_LITERAL_PATHSPECS during capture (nil: unset)
local function check_glob_path_capture(literal_env)
  -- As a glob pathspec, app/[id]/page.txt also matches the sibling
  -- app/d/page.txt. Its own file changes at line 1, the sibling at line 9;
  -- a comment on line 9 must not pick up the sibling's hunk.
  local repo = make_repo({ 'x' })
  vim.fn.mkdir(repo .. '/app/[id]', 'p')
  vim.fn.mkdir(repo .. '/app/d', 'p')
  local base = { '1', '2', '3', '4', '5', '6', '7', '8', '9', '10' }
  write_file(repo .. '/app/[id]/page.txt', base)
  write_file(repo .. '/app/d/page.txt', base)
  git(repo, 'add', '-A')
  git(repo, 'commit', '-q', '-m', 'pages')
  local own, sibling = vim.deepcopy(base), vim.deepcopy(base)
  own[1] = 'own'
  sibling[9] = 'sibling'
  write_file(repo .. '/app/[id]/page.txt', own)
  write_file(repo .. '/app/d/page.txt', sibling)
  git(repo, 'commit', '-q', '-am', 'change')
  local file = repo .. '/app/[id]/page.txt'
  local bufnr = open(file)
  local saved = vim.env.GIT_LITERAL_PATHSPECS
  vim.env.GIT_LITERAL_PATHSPECS = literal_env
  local ok, at9, at1 = pcall(function()
    return context.capture(file, 9, 9), context.capture(file, 1, 1)
  end)
  vim.env.GIT_LITERAL_PATHSPECS = saved
  if not ok then error(at9, 0) end
  wipe(bufnr)
  vim.fn.delete(repo, 'rf')
  assert.falsy(vim.tbl_contains(at9.snippet, '+sibling'), 'not the sibling hunk')
  assert.equals(at9.snippet_source, 'buffer', 'no own hunk at line 9')
  assert.equals(at1.snippet_source, 'diff', 'own hunk at line 1')
  assert.contains(at1.snippet, '+own', 'own hunk content')
end

assert.run_test('capture of a path with glob characters diffs only that file', function()
  check_glob_path_capture(nil)
end)

assert.run_test('capture diffs the file when the user sets GIT_LITERAL_PATHSPECS=1', function()
  check_glob_path_capture('1')
end)

-- A repo whose HEAD~1..HEAD diff has a hunk at line 2, and a buffer named
-- `name(repo)` holding an old revision of file.txt
local function capture_from_revision_buffer(name)
  local repo = make_repo({ 'r1', 'r2', 'r3' })
  write_file(repo .. '/file.txt', { 'r1', 'changed', 'r3' })
  git(repo, 'commit', '-q', '-am', 'change')
  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(bufnr, name(repo))
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'r1', 'r2', 'r3' })
  vim.bo[bufnr].modified = false
  local ok, ctx = pcall(context.capture, repo .. '/file.txt', 2, 2, bufnr)
  wipe(bufnr)
  vim.fn.delete(repo, 'rf')
  assert.truthy(ok, 'capture does not error: ' .. tostring(ctx))
  assert.equals(ctx.snippet_source, 'buffer', 'buffer snippet, not the working-tree diff')
  assert.contains(ctx.snippet, '   2  r2', 'snippet is the revision buffer\'s line')
  assert.truthy(ctx.commit, 'commit still recorded')
end

assert.run_test('capture from a fugitive revision buffer uses the buffer snippet', function()
  capture_from_revision_buffer(function(repo)
    return 'fugitive://' .. repo .. '/.git//0123456789abcdef/file.txt'
  end)
end)

assert.run_test('capture from a diffview revision buffer uses the buffer snippet', function()
  capture_from_revision_buffer(function(repo)
    return 'diffview://' .. repo .. '/.git/0123456789abcdef/file.txt'
  end)
end)

-- export fences

local export = require('quickfix-review.export')

local function export_one(filename, ctx)
  local md = export.to_markdown(
    { { filename = filename, lnum = 1, kind = 'note', body = 'b', context = ctx } },
    { export = { header = '', type_legend = '' } })
  return vim.split(md, '\n', { plain = true })
end

assert.run_test('export fences a buffer snippet by filetype, not as diff', function()
  local lines = export_one('/tmp/x.lua', { snippet_source = 'buffer', snippet = { '   1  local x' } })
  assert.contains(lines, '   ```lua', 'lua fence')
  assert.falsy(vim.tbl_contains(lines, '   ```diff'), 'no diff fence')
  assert.falsy(vim.tbl_contains(lines, '   - (unsaved buffer)'), 'no unsaved marker')
end)

assert.run_test('export fences a buffer snippet of an unknown type plainly', function()
  local lines = export_one('/tmp/noext_zzqq', {
    snippet_source = 'buffer', snippet = { '   1  x' }, buffer_modified = true,
  })
  assert.contains(lines, '   ```', 'plain fence')
  assert.falsy(vim.tbl_contains(lines, '   ```diff'), 'no diff fence')
  assert.contains(lines, '   - (unsaved buffer)', 'unsaved marker')
end)

assert.run_test('export fences a diff snippet as diff', function()
  local lines = export_one('/tmp/x.lua', { snippet_source = 'diff', snippet = { '@@ -1 +1 @@', '+x' } })
  assert.contains(lines, '   ```diff', 'diff fence')
end)

assert.run_test('export fence outlasts backtick runs in the snippet', function()
  local lines = export_one('/tmp/x.md', { snippet_source = 'diff', snippet = { '@@ -1,2 +1,2 @@', ' ```', '+````lua' } })
  assert.contains(lines, '   `````diff', 'opening fence longer than any run')
  assert.equals(lines[#lines], '   `````', 'closing fence matches')
  assert.contains(lines, '    ```', 'content line kept')
end)

assert.run_test('export indents a multi-line body under its list item', function()
  local md = export.to_markdown(
    { { filename = '/tmp/x.lua', lnum = 1, kind = 'note', body = 'first\nsecond\n\nthird', response = 'r1\nr2' } },
    { export = { header = '', type_legend = '' } })
  local lines = vim.split(md, '\n', { plain = true })
  assert.equals(lines[3], '1. **[NOTE]** `/tmp/x.lua:1` - first', 'item line')
  assert.equals(lines[4], '   second', 'continuation indented')
  assert.equals(lines[5], '', 'blank line kept blank')
  assert.equals(lines[6], '   third | Response: r1', 'later line indented')
  assert.equals(lines[7], '   r2', 'response continuation indented')
  assert.length(lines, 7, 'nothing else')
end)

return assert
