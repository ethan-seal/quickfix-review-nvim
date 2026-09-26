-- Tests for relocating comments when their file changes: tracking extmarks,
-- relocation on reload and from disk, and the outdated state
local test_helper = dofile('test/init.lua')
local assert = dofile('test/assertions.lua')

print('\nRunning relocation tests...')

local qf = test_helper.setup_test_environment()
local store = require('quickfix-review.store')
local utils = require('quickfix-review.utils')
local track = require('quickfix-review.track')
local export = require('quickfix-review.export')

local TEN = {}
for i = 1, 10 do TEN[i] = 'line ' .. i end

local test_file = test_helper.create_test_file(table.concat(TEN, '\n') .. '\n')
local abs = vim.fn.fnamemodify(test_file, ':p')
local file_buf = vim.fn.bufnr(test_file)

-- Put `lines` in the test file on disk and reload its buffer
local function rewrite(lines)
  vim.fn.writefile(lines, abs)
  vim.api.nvim_set_current_buf(file_buf)
  vim.cmd('silent edit!')
end

-- A fresh review with the test file as TEN, loaded
local function fresh()
  qf.clear_review()
  rewrite(TEN)
end

local function log_size()
  return #test_helper.log_records(test_helper.log_path())
end

-- The review signs on 1-based `line` of `buf`
local function signs_on(buf, line)
  local found = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, utils.get_ns_id(), 0, -1, { details = true })) do
    if m[2] == line - 1 then table.insert(found, m[4]) end
  end
  return found
end

-- The lines of the float view_comment opens at `line`
local function float_lines(line)
  vim.fn.cursor(line, 1)
  local before = {}
  for _, w in ipairs(vim.api.nvim_list_wins()) do before[w] = true end
  qf.view_comment()
  local float
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if not before[w] and vim.api.nvim_win_get_config(w).relative ~= '' then float = w end
  end
  if not float then return {} end
  local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(float), 0, -1, false)
  vim.api.nvim_exec_autocmds('CursorMoved', {})
  return lines
end

assert.run_test('lines inserted above on disk: the comment follows, shifted', function()
  fresh()
  vim.fn.cursor(5, 1)
  qf.add_comment('ISSUE')
  local logged = log_size()

  local lines = { 'new 1', 'new 2' }
  vim.list_extend(lines, TEN)
  rewrite(lines)

  local c = qf.comments()[1]
  local lnum, end_lnum = store.range(c)
  assert.equals(lnum, 7, 'lnum')
  assert.equals(end_lnum, 7, 'end_lnum')
  assert.equals(c.pos.state, 'shifted', 'state')
  assert.length(signs_on(file_buf, 7), 1, 'sign on line 7')
  assert.length(signs_on(file_buf, 5), 0, 'no sign left on line 5')
  assert.equals(c.anchor.lnum, 5, 'the anchor is unchanged')
  assert.equals(log_size(), logged, 'nothing logged')

  -- BufEnter redraws from the tracked position: no snap back to line 5
  vim.api.nvim_exec_autocmds('BufEnter', { buffer = file_buf })
  assert.length(signs_on(file_buf, 7), 1, 'sign still on line 7 after BufEnter')
  qf.show_list()
  assert.equals(vim.fn.getqflist()[1].lnum, 7, 'qf row on line 7')
  vim.fn.setqflist({}, 'f')
end)

assert.run_test('in-session edits move the comment and BufEnter does not snap it back', function()
  fresh()
  vim.fn.cursor(5, 1)
  qf.add_comment('NOTE')
  local logged = log_size()
  vim.api.nvim_buf_set_lines(file_buf, 0, 0, false, { 'a', 'b' })
  vim.api.nvim_exec_autocmds('BufEnter', { buffer = file_buf })
  local lnum = store.range(qf.comments()[1])
  assert.equals(lnum, 7, 'followed the edit')
  assert.length(signs_on(file_buf, 7), 1, 'sign on line 7')
  assert.equals(log_size(), logged, 'nothing logged')

  -- Deleting the whole range makes it outdated
  vim.api.nvim_buf_set_lines(file_buf, 6, 7, false, {})
  assert.equals(store.pos(qf.comments()[1]).state, 'outdated', 'whole range deleted')
  vim.cmd('silent edit!')
end)

assert.run_test('a commented line changed on disk: outdated everywhere', function()
  fresh()
  vim.fn.cursor(5, 1)
  qf.add_comment('ISSUE')
  local logged = log_size()

  local lines = vim.deepcopy(TEN)
  lines[5] = 'line 5 rewritten'
  rewrite(lines)

  local c = qf.comments()[1]
  assert.equals(store.pos(c).state, 'outdated', 'state')
  assert.equals((store.range(c)), 5, 'still on line 5')
  local signs = signs_on(file_buf, 5)
  assert.length(signs, 1, 'sign on line 5')
  assert.equals(signs[1] and signs[1].sign_hl_group, 'QuickfixReviewOutdated', 'outdated sign highlight')
  local hl = vim.api.nvim_get_hl(0, { name = 'QuickfixReviewOutdated' })
  assert.equals(hl.link, 'DiagnosticWarn', 'linked to DiagnosticWarn by default')

  qf.show_list()
  local row = vim.fn.getqflist()[1]
  vim.fn.setqflist({}, 'f')
  assert.truthy(vim.startswith(row.text, '[outdated] '), 'qf row prefixed: ' .. row.text)

  local float = float_lines(5)
  assert.equals(float[1], 'outdated — code changed since comment', 'float header')

  local md = export.to_markdown(qf.comments(), qf.config.options)
  assert.truthy(md:find('test_file.txt:5 (outdated)', 1, true), 'export marks it: ' .. md)
  assert.equals(log_size(), logged, 'nothing logged')
end)

assert.run_test('a current comment has no outdated marks', function()
  fresh()
  vim.fn.cursor(3, 1)
  qf.add_comment('ISSUE')
  qf.show_list()
  local row = vim.fn.getqflist()[1]
  vim.fn.setqflist({}, 'f')
  assert.equals(row.text, '[ISSUE] Test comment', 'qf row')
  assert.equals(float_lines(3)[1], '[ISSUE] Test comment', 'float starts with the headline')
  local md = export.to_markdown(qf.comments(), qf.config.options)
  assert.falsy(md:find('(outdated)', 1, true), 'export does not mark it')
  assert.equals(signs_on(file_buf, 3)[1].sign_hl_group, 'DiagnosticError', 'type highlight')
end)

assert.run_test('relocation from disk for a file that is not loaded, cached by size and mtime', function()
  local path = vim.fn.tempname() .. '-unloaded.txt'
  vim.fn.writefile(TEN, path)
  vim.cmd('edit ' .. vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()
  local ok, err = pcall(function()
    qf.clear_review()
    vim.fn.cursor(4, 1)
    qf.add_comment('NOTE')
    vim.api.nvim_set_current_buf(file_buf)
    vim.cmd('bwipeout! ' .. buf)
    local c = qf.comments()[1]
    assert.equals(store.pos(c).state, 'current', 'unchanged on disk')

    local lines = { 'x' }
    vim.list_extend(lines, TEN)
    vim.fn.writefile(lines, path)
    assert.equals((store.range(c)), 5, 'shifted on disk')
    assert.equals(c.pos.state, 'shifted', 'state')

    -- Same size, new content: a later mtime is seen
    lines[5] = 'line 9'
    vim.fn.writefile(lines, path)
    local later = os.time() + 5
    vim.uv.fs_utime(path, later, later)
    assert.equals(store.pos(c).state, 'outdated', 'changed on disk')

    qf.show_list()
    local row = vim.fn.getqflist()[1]
    vim.fn.setqflist({}, 'f')
    assert.truthy(vim.startswith(row.text, '[outdated] '), 'qf row prefixed')

    os.remove(path)
    assert.equals(store.pos(c).state, 'outdated', 'missing file')
  end)
  os.remove(path)
  qf.clear_review()
  if not ok then error(err, 0) end
end)

-- A file with `content` (raw bytes), opened with `edit_cmd`, commented on
-- line 2, then reloaded and, unloaded, read back from disk
local function check_eol(name, content, edit_cmd)
  assert.run_test(name, function()
    local path = vim.fn.tempname() .. '-eol.txt'
    local fh = io.open(path, 'wb')
    fh:write(content)
    fh:close()
    local ok, err = pcall(function()
      qf.clear_review()
      vim.cmd(edit_cmd .. ' ' .. vim.fn.fnameescape(path))
      local buf = vim.api.nvim_get_current_buf()
      vim.fn.cursor(2, 1)
      qf.add_comment('NOTE')
      vim.cmd('silent edit!')
      local c = qf.comments()[1]
      assert.equals(store.pos(c).state, 'current', 'current after reload')
      vim.api.nvim_set_current_buf(file_buf)
      vim.cmd('bwipeout! ' .. buf)
      assert.equals(store.pos(c).state, 'current', 'current read from disk')
      assert.equals((store.range(c)), 2, 'line 2')
    end)
    os.remove(path)
    vim.api.nvim_set_current_buf(file_buf)
    qf.clear_review()
    if not ok then error(err, 0) end
  end)
end

check_eol('a CRLF file is not outdated', 'a\r\nb\r\nc\r\n', 'edit')
check_eol('a CRLF file read as unix (CRs in the buffer) is not outdated', 'a\r\nb\r\nc\r\n', 'edit ++ff=unix')
check_eol('a file without a final newline is not outdated', 'a\nb\nc', 'edit')
check_eol('a CRLF file without a final newline is not outdated', 'a\r\nb\r\nc', 'edit')

assert.run_test('opening a diff buffer with other lines never moves the comment', function()
  fresh()
  vim.fn.cursor(5, 1)
  qf.add_comment('ISSUE')
  local c = qf.comments()[1]
  local before = vim.deepcopy(store.pos(c))
  local logged = log_size()

  local lines = { 'old 1', 'old 2' }
  vim.list_extend(lines, TEN)
  local fugbuf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(fugbuf, 0, -1, false, lines)
  vim.api.nvim_buf_set_name(fugbuf, 'fugitive://' .. vim.fn.getcwd() .. '/.git//0/' .. test_file)
  vim.cmd('buffer ' .. fugbuf)
  vim.api.nvim_exec_autocmds('BufReadPost', { buffer = fugbuf })
  vim.api.nvim_exec_autocmds('FileChangedShellPost', { buffer = fugbuf })
  vim.cmd('buffer ' .. file_buf)
  vim.cmd('bwipeout! ' .. fugbuf)

  local after = store.pos(qf.comments()[1])
  assert.equals(after.lnum, before.lnum, 'lnum unchanged')
  assert.equals(after.end_lnum, before.end_lnum, 'end_lnum unchanged')
  assert.equals(after.state, 'current', 'still current')
  assert.equals(log_size(), logged, 'nothing logged')
end)

assert.run_test('a legacy comment with no snapshot stays current at its line', function()
  fresh()
  store.add({ filename = abs, lnum = 4, end_lnum = 5, kind = 'note', body = 'legacy' })
  local lines = { 'x', 'y' }
  vim.list_extend(lines, TEN)
  rewrite(lines)
  local c = qf.comments()[1]
  assert.equals(c.anchor.sha, nil, 'no sha')
  assert.equals(store.pos(c).state, 'current', 'not outdated')
  assert.equals((store.range(c)), 4, 'at its stored line')
end)

assert.run_test('a comment whose snapshot is missing is outdated at its anchor', function()
  fresh()
  vim.fn.cursor(6, 1)
  qf.add_comment('NOTE')
  local c = qf.comments()[1]
  os.remove(store.snapshots_dir() .. '/' .. c.anchor.sha)
  require('quickfix-review.snapshots')._clear_cache()
  local lines = vim.deepcopy(TEN)
  table.insert(lines, 1, 'top')
  rewrite(lines)
  c = qf.comments()[1]
  assert.equals(store.pos(c).state, 'outdated', 'outdated')
  assert.equals((store.range(c)), 6, 'at its anchor line')
end)

assert.run_test('deleting and clearing comments removes their tracking extmarks', function()
  fresh()
  vim.fn.cursor(2, 1)
  qf.add_comment('NOTE')
  vim.fn.cursor(4, 1)
  qf.add_comment('NOTE')
  local function marks()
    return #vim.api.nvim_buf_get_extmarks(file_buf, track.ns(), 0, -1, {})
  end
  assert.equals(marks(), 2, 'one tracking extmark per comment')
  vim.fn.cursor(2, 1)
  qf.delete_comment()
  assert.equals(marks(), 1, 'deleted comment has no extmark')
  qf.clear_review()
  assert.equals(marks(), 0, 'no tracking extmarks after clear_review')
end)

assert.run_test('restored comments get their tracking extmarks back', function()
  fresh()
  vim.fn.cursor(2, 1)
  qf.add_comment('NOTE')
  vim.fn.cursor(4, 1)
  qf.add_comment('NOTE')
  local function marks()
    return #vim.api.nvim_buf_get_extmarks(file_buf, track.ns(), 0, -1, {})
  end
  assert.equals(marks(), 2, 'one tracking extmark per comment')
  vim.fn.cursor(2, 1)
  qf.delete_comment()
  assert.equals(marks(), 1, 'deleted comment has no extmark')
  qf.restore_comment()
  assert.equals(marks(), 2, 'restored after delete')
  qf.clear_review()
  assert.equals(marks(), 0, 'none after clear')
  local original = vim.fn.confirm
  vim.fn.confirm = function() return 1 end
  local ok, err = pcall(qf.restore_comment)
  vim.fn.confirm = original
  if not ok then error(err, 0) end
  assert.equals(marks(), 2, 'restored after clear')
  -- Restored comments follow edits like any other
  vim.api.nvim_buf_set_lines(file_buf, 0, 0, false, { 'new top' })
  local lines = {}
  for i, c in ipairs(qf.comments()) do lines[i] = (store.range(c)) end
  table.sort(lines)
  assert.equals(table.concat(lines, ','), '3,5', 'tracked after an insert above')
  vim.cmd('silent edit!')
  qf.clear_review()
end)

rewrite(TEN)
test_helper.cleanup_test_environment()

return assert
