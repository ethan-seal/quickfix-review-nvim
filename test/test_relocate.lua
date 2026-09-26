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

-- A NOTE on line 6 of TEN whose snapshot is then deleted
local function snapshotless_comment()
  fresh()
  vim.fn.cursor(6, 1)
  qf.add_comment('NOTE')
  local c = qf.comments()[1]
  os.remove(store.snapshots_dir() .. '/' .. c.anchor.sha)
  require('quickfix-review.snapshots')._clear_cache()
end

assert.run_test('a comment whose snapshot is missing is found by its lines, shifted', function()
  snapshotless_comment()
  local lines = vim.deepcopy(TEN)
  for _ = 1, 3 do table.insert(lines, 1, 'top') end
  rewrite(lines)
  local c = qf.comments()[1]
  assert.equals(store.pos(c).state, 'shifted', 'shifted')
  assert.equals((store.range(c)), 9, 'moved down 3')
end)

assert.run_test('a comment whose snapshot is missing and whose lines are gone is outdated', function()
  snapshotless_comment()
  local lines = vim.deepcopy(TEN)
  table.remove(lines, 6)
  rewrite(lines)
  local c = qf.comments()[1]
  assert.equals(store.pos(c).state, 'outdated', 'outdated')
  assert.equals((store.range(c)), 6, 'at its anchor line')
end)

assert.run_test('a comment whose snapshot is missing is found from disk too', function()
  local path = vim.fn.tempname() .. '-nosnap.txt'
  vim.fn.writefile(TEN, path)
  vim.cmd('edit ' .. vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()
  local ok, err = pcall(function()
    qf.clear_review()
    vim.fn.cursor(6, 1)
    qf.add_comment('NOTE')
    local c = qf.comments()[1]
    os.remove(store.snapshots_dir() .. '/' .. c.anchor.sha)
    require('quickfix-review.snapshots')._clear_cache()
    vim.api.nvim_set_current_buf(file_buf)
    vim.cmd('bwipeout! ' .. buf)

    local lines = vim.deepcopy(TEN)
    for _ = 1, 3 do table.insert(lines, 1, 'top') end
    vim.fn.writefile(lines, path)
    assert.equals(store.pos(c).state, 'shifted', 'shifted')
    assert.equals((store.range(c)), 9, 'moved down 3')
  end)
  os.remove(path)
  qf.clear_review()
  if not ok then error(err, 0) end
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

-- Write-back on save and :ReviewReanchor ------------------------------------

-- Simulate quitting and reopening Neovim: forget every tracked position,
-- replay the whole log (fresh records, whose pos starts at their anchor) and
-- re-read the test file
local function restart()
  track._reset()
  assert.truthy(store.reload(), 'review reloaded')
  vim.api.nvim_set_current_buf(file_buf)
  vim.cmd('silent edit!')
end

local function updates()
  return test_helper.log_ops(test_helper.log_path(), 'update')
end

-- Save the test file's buffer
local function save()
  vim.api.nvim_set_current_buf(file_buf)
  vim.cmd('silent write')
end

local function sha_on_disk()
  return require('quickfix-review.snapshots').hash(vim.fn.readfile(abs))
end

assert.run_test('an edit above a comment, saved: the anchor is written back, no double shift', function()
  fresh()
  vim.fn.cursor(5, 1)
  qf.add_comment('ISSUE')
  local before = #updates()
  vim.api.nvim_buf_set_lines(file_buf, 0, 0, false, { 'new 1', 'new 2' })
  save()

  local ups = updates()
  assert.equals(#ups, before + 1, 'one update logged')
  local ev = ups[#ups]
  assert.equals(ev.set.anchor.sha, sha_on_disk(), 'anchored to the saved content')
  assert.equals(ev.set.anchor.lnum, 7, 'anchor lnum')
  assert.equals(ev.set.anchor.end_lnum, 7, 'anchor end_lnum')
  assert.equals(table.concat(ev.set.anchor.lines, '|'), 'line 5', 'anchor lines')
  assert.equals(ev.set.pos, nil, 'pos is never logged')
  assert.equals(ev.set.lnum, 7, 'top-level lnum kept in sync')
  assert.equals(ev.prev.anchor.lnum, 5, 'prev anchor')
  local saved = test_helper.saved()[1]
  assert.equals(saved.lnum, saved.anchor.lnum, 'record lnum matches its anchor')

  local c = qf.comments()[1]
  assert.equals(store.pos(c).state, 'current', 'current in the session')
  assert.equals((store.range(c)), 7, 'on line 7 in the session')

  restart()
  c = qf.comments()[1]
  assert.equals(store.pos(c).state, 'current', 'current after a restart')
  assert.equals((store.range(c)), 7, 'on line 7 after a restart')
  assert.length(signs_on(file_buf, 7), 1, 'sign on line 7')
  assert.length(signs_on(file_buf, 9), 0, 'no double shift')
  rewrite(TEN)
end)

assert.run_test('unsaved edits never change the stored anchor', function()
  fresh()
  vim.fn.cursor(5, 1)
  qf.add_comment('ISSUE')
  local anchor = vim.deepcopy(test_helper.saved()[1].anchor)
  local logged = log_size()
  vim.api.nvim_buf_set_lines(file_buf, 0, 0, false, { 'new 1', 'new 2' })
  for _, ev in ipairs({ 'BufLeave', 'BufEnter', 'FocusGained', 'CursorHold', 'VimLeavePre' }) do
    vim.api.nvim_exec_autocmds(ev, { buffer = file_buf })
  end
  vim.cmd('silent edit!')
  assert.equals(log_size(), logged, 'nothing logged')
  assert.truthy(vim.deep_equal(test_helper.saved()[1].anchor, anchor), 'anchor unchanged')
  restart()
  local c = qf.comments()[1]
  assert.equals((store.range(c)), 5, 'on line 5 after a restart')
  assert.equals(store.pos(c).state, 'current', 'current')
end)

assert.run_test('saving with no edits logs nothing', function()
  fresh()
  vim.fn.cursor(5, 1)
  qf.add_comment('ISSUE')
  local logged = log_size()
  save()
  save()
  assert.equals(log_size(), logged, 'nothing logged')
end)

assert.run_test('an edit inside a range, saved: outdated, the anchor kept', function()
  fresh()
  vim.fn.cursor(5, 1)
  qf.add_comment('ISSUE')
  local anchor = vim.deepcopy(test_helper.saved()[1].anchor)
  local logged = log_size()
  vim.api.nvim_buf_set_lines(file_buf, 4, 5, false, { 'line 5 changed' })
  save()
  assert.equals(log_size(), logged, 'nothing logged')
  assert.truthy(vim.deep_equal(test_helper.saved()[1].anchor, anchor), 'anchor unchanged')
  assert.equals(store.pos(qf.comments()[1]).state, 'outdated', 'outdated')
  rewrite(TEN)
end)

assert.run_test('comments above the edit are re-anchored to the new file too', function()
  fresh()
  vim.fn.cursor(2, 1)
  qf.add_comment('NOTE')
  local logged = log_size()
  vim.api.nvim_buf_set_lines(file_buf, 8, 8, false, { 'below' })
  save()
  assert.equals(log_size(), logged + 1, 'one update')
  local a = test_helper.saved()[1].anchor
  assert.equals(a.sha, sha_on_disk(), 'new sha')
  assert.equals(a.lnum, 2, 'same line')
  rewrite(TEN)
end)

assert.run_test('comments on other files, and diff buffers, are left alone on a write', function()
  fresh()
  store.add({ filename = vim.fn.getcwd() .. '/other_file.txt', lnum = 1, kind = 'note', body = 'x' })
  vim.fn.cursor(5, 1)
  qf.add_comment('NOTE')
  local logged = log_size()

  local path = vim.fn.tempname() .. '-nofile.txt'
  local nofile = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(nofile, 0, -1, false, { 'a', 'b', 'c', 'd', 'e', 'f' })
  vim.api.nvim_buf_set_name(nofile, 'fugitive://' .. vim.fn.getcwd() .. '/.git//0/' .. test_file)
  vim.api.nvim_exec_autocmds('BufWritePost', { buffer = nofile })
  vim.cmd('bwipeout! ' .. nofile)

  -- A write of the file's buffer to another file
  vim.api.nvim_set_current_buf(file_buf)
  vim.api.nvim_buf_set_lines(file_buf, 0, 0, false, { 'top' })
  vim.cmd('silent write ' .. vim.fn.fnameescape(path))
  os.remove(path)
  assert.equals(log_size(), logged, 'nothing logged')
  vim.cmd('silent edit!')
end)

assert.run_test('a legacy comment gets a snapshot-backed anchor on save', function()
  fresh()
  store.add({ filename = abs, lnum = 4, end_lnum = 5, kind = 'note', body = 'legacy' })
  vim.api.nvim_buf_set_lines(file_buf, 0, 0, false, { 'top' })
  save()
  local a = test_helper.saved()[1].anchor
  assert.equals(a.sha, sha_on_disk(), 'sha')
  assert.equals(a.lnum, 5, 'followed the edit')
  assert.equals(a.end_lnum, 6, 'end')
  assert.equals(table.concat(a.lines, '|'), 'line 4|line 5', 'lines')
  assert.equals(store.pos(qf.comments()[1]).state, 'current', 'current')
  rewrite(TEN)
end)

-- A file with `content`, commented on line 2, a line inserted at the top and
-- saved: re-anchored once, current after a reload and from disk
local function check_eol_write(name, content, edit_cmd)
  assert.run_test(name, function()
    local path = vim.fn.tempname() .. '-eolw.txt'
    local fh = io.open(path, 'wb')
    fh:write(content)
    fh:close()
    local ok, err = pcall(function()
      qf.clear_review()
      vim.cmd(edit_cmd .. ' ' .. vim.fn.fnameescape(path))
      local buf = vim.api.nvim_get_current_buf()
      vim.fn.cursor(2, 1)
      qf.add_comment('NOTE')
      local before = #updates()
      vim.api.nvim_buf_set_lines(buf, 0, 0, false, { 'top' })
      vim.cmd('silent write')
      assert.equals(#updates(), before + 1, 'one update')
      vim.cmd('silent edit!')
      vim.cmd('silent write')
      assert.equals(#updates(), before + 1, 'no second update')
      local c = qf.comments()[1]
      assert.equals(store.pos(c).state, 'current', 'current after reload')
      vim.api.nvim_set_current_buf(file_buf)
      vim.cmd('bwipeout! ' .. buf)
      assert.equals(store.pos(c).state, 'current', 'current read from disk')
      assert.equals((store.range(c)), 3, 'line 3')
    end)
    os.remove(path)
    vim.api.nvim_set_current_buf(file_buf)
    qf.clear_review()
    if not ok then error(err, 0) end
  end)
end

check_eol_write('a saved CRLF file is re-anchored once', 'a\r\nb\r\nc\r\n', 'edit')
check_eol_write('a saved CRLF file read as unix is re-anchored once', 'a\r\nb\r\nc\r\n', 'edit ++ff=unix')
check_eol_write('a saved file without a final newline is re-anchored once', 'a\nb\nc', 'edit')

local function outdated_hl(line)
  local s = signs_on(file_buf, line)
  return s[1] and s[1].sign_hl_group == utils.OUTDATED_HL
end

assert.run_test(':ReviewReanchor accepts an outdated comment changed on disk', function()
  fresh()
  vim.fn.cursor(5, 1)
  qf.add_comment('ISSUE')
  local lines = vim.deepcopy(TEN)
  lines[5] = 'line 5 rewritten'
  rewrite(lines)
  assert.equals(store.pos(qf.comments()[1]).state, 'outdated', 'outdated first')
  assert.truthy(outdated_hl(5), 'outdated sign')

  local logged = log_size()
  vim.fn.cursor(5, 1)
  vim.cmd('ReviewReanchor')
  assert.equals(log_size(), logged + 1, 'one update')
  local c = qf.comments()[1]
  assert.equals(store.pos(c).state, 'current', 'current')
  assert.equals(table.concat(c.anchor.lines, '|'), 'line 5 rewritten', 'anchor lines')
  assert.equals(c.anchor.sha, sha_on_disk(), 'anchor sha')
  assert.falsy(outdated_hl(5), 'sign no longer outdated')

  restart()
  c = qf.comments()[1]
  assert.equals(store.pos(c).state, 'current', 'current after a restart')
  assert.equals((store.range(c)), 5, 'line 5')
  rewrite(TEN)
end)

assert.run_test(':ReviewReanchor accepts a comment whose whole range was deleted', function()
  fresh()
  vim.fn.cursor(5, 1)
  qf.add_comment('ISSUE')
  vim.api.nvim_buf_set_lines(file_buf, 4, 5, false, {})
  local c = qf.comments()[1]
  assert.equals(store.pos(c).state, 'outdated', 'outdated first')
  local line = store.range(c)
  local logged = log_size()
  vim.fn.cursor(line, 1)
  qf.reanchor()
  assert.equals(log_size(), logged + 1, 'one update')
  c = qf.comments()[1]
  assert.equals(store.pos(c).state, 'current', 'current')
  assert.equals((store.range(c)), line, 'at the line before the gap')
  -- Saving the same content logs nothing more
  save()
  assert.equals(log_size(), logged + 1, 'no update on save')
  restart()
  c = qf.comments()[1]
  assert.equals(store.pos(c).state, 'current', 'current after a restart')
  rewrite(TEN)
end)

assert.run_test(':ReviewReanchor with nothing outdated logs nothing', function()
  fresh()
  vim.fn.cursor(5, 1)
  qf.add_comment('ISSUE')
  local logged = log_size()
  local msgs = {}
  local original = vim.notify
  vim.notify = function(msg) table.insert(msgs, msg) end
  local ok, err = pcall(function()
    vim.fn.cursor(5, 1)
    vim.cmd('ReviewReanchor')
    vim.fn.cursor(8, 1)
    vim.cmd('ReviewReanchor')
  end)
  vim.notify = original
  if not ok then error(err, 0) end
  assert.equals(log_size(), logged, 'nothing logged')
  assert.truthy(msgs[1] and msgs[1]:find('no outdated comment', 1, true), 'says the comment is not outdated')
  assert.truthy(msgs[2] and msgs[2]:find('no comment', 1, true), 'says there is no comment')
end)

rewrite(TEN)
test_helper.cleanup_test_environment()

return assert
