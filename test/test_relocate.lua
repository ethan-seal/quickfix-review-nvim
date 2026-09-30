-- Tests for relocating comments when their file changes: tracking extmarks,
-- relocation on reload and from disk, and the outdated state
local test_helper = dofile((vim.env.QFR_TEST_ROOT or '.') .. '/test/init.lua')
local assert = dofile(test_helper.root .. '/test/assertions.lua')

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
  -- Start a new undo block, as typing after a reload does: otherwise the
  -- next edit joins the reload's block and an undo reverts both
  vim.cmd('let &undolevels = &undolevels')
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
  assert.equals(store.pos(c).state, 'shifted', 'state')
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

assert.run_test('replacing every line with the same content keeps the comment current', function()
  fresh()
  vim.fn.cursor(5, 1)
  qf.add_comment('ISSUE')
  local logged = log_size()

  -- As :%!cat or a formatter would: every line replaced, the content as it was
  vim.cmd('silent %!cat')
  local c = qf.comments()[1]
  assert.equals(store.pos(c).state, 'current', 'still current')
  assert.equals((store.range(c)), 5, 'still on line 5')
  -- No store.refresh(): the filter itself redraws the signs
  local signs = signs_on(file_buf, 5)
  assert.length(signs, 1, 'sign on line 5')
  assert.truthy(signs[1] and signs[1].sign_hl_group ~= utils.OUTDATED_HL, 'not the outdated highlight')
  assert.equals(log_size(), logged, 'nothing logged')

  -- Replaced with other content: diffed against the snapshot
  local shifted = { 'a', 'b' }
  vim.list_extend(shifted, TEN)
  vim.api.nvim_buf_set_lines(file_buf, 0, -1, false, shifted)
  c = qf.comments()[1]
  assert.equals(store.pos(c).state, 'shifted', 'shifted after a replace that inserts lines')
  assert.equals((store.range(c)), 7, 'on line 7')
  vim.cmd('silent edit!')
end)

assert.run_test('deleting a commented line then undoing makes it current again', function()
  fresh()
  vim.fn.cursor(5, 1)
  qf.add_comment('ISSUE')

  vim.cmd('normal! 5Gdd')
  local c = qf.comments()[1]
  assert.equals(store.pos(c).state, 'outdated', 'outdated after dd')

  vim.cmd('silent undo')
  c = qf.comments()[1]
  local pos = store.pos(c)
  local lnum, end_lnum = store.range(c)
  vim.cmd('silent edit!')
  assert.equals(pos.state, 'current', 'current after undo')
  assert.equals(lnum, 5, 'on line 5 after undo')
  assert.equals(end_lnum, 5, 'ends on line 5 after undo')
end)

-- After a reload from a shorter file (as after an external change); the
-- undo break in rewrite() stands in for the user typing after the reload
assert.run_test('deleting a range that ends at EOF then undoing restores it', function()
  qf.clear_review()
  rewrite({ 'line 1', 'line 2' })
  rewrite(TEN)
  qf.add_comment('ISSUE', { 9, 10 })
  local c = qf.comments()[1]

  vim.cmd('normal! 9G2dd')
  local deleted = store.pos(c).state

  vim.cmd('silent undo')
  local pos = store.pos(c)
  local lnum, end_lnum = store.range(c)
  local p = track.positions(file_buf)[c.id]
  vim.cmd('silent edit!')

  assert.equals(deleted, 'outdated', 'outdated after deleting lines 9-10')
  assert.equals(lnum, 9, 'on line 9 after undo')
  assert.equals(end_lnum, 10, 'ends on line 10 after undo')
  assert.equals(pos.state, 'current', 'current after undo')
  assert.truthy(p and p.lnum == 9 and p.end_lnum == 10 and p.state == 'current',
    'positions() agrees after undo')
end)

local FOUR = { 'line 1', 'line 2', 'line 3', 'line 4' }

-- A fresh review with the test file as FOUR and a comment on 3-4
local function four_with_eof_range()
  qf.clear_review()
  rewrite(FOUR)
  qf.add_comment('ISSUE', { 3, 4 })
  return qf.comments()[1]
end

assert.run_test('deleting a whole range at EOF then undoing makes it current again', function()
  local c = four_with_eof_range()

  vim.cmd('normal! 3G2dd')
  local deleted = store.pos(c).state

  vim.cmd('silent undo')
  local pos = store.pos(c)
  local lnum, end_lnum = store.range(c)
  local p = track.positions(file_buf)[c.id]
  vim.cmd('silent edit!')

  assert.equals(deleted, 'outdated', 'outdated after deleting lines 3-4')
  assert.equals(lnum, 3, 'on line 3 after undo')
  assert.equals(end_lnum, 4, 'ends on line 4 after undo')
  assert.equals(pos.state, 'current', 'current after undo')
  assert.truthy(p and p.lnum == 3 and p.end_lnum == 4 and p.state == 'current',
    'positions() agrees after undo')
end)

assert.run_test("deleting only a range's last line at EOF makes it outdated", function()
  local c = four_with_eof_range()
  vim.cmd('normal! 4Gdd')
  local state = store.pos(c).state
  vim.cmd('silent edit!')
  assert.equals(state, 'outdated', 'outdated after 4Gdd')
end)

assert.run_test('changing both lines of a range at EOF into one makes it outdated', function()
  local c = four_with_eof_range()
  vim.cmd('normal! 3Gcjxx')
  local state = store.pos(c).state
  vim.cmd('silent edit!')
  assert.equals(state, 'outdated', 'outdated after 3Gcjxx')
end)

assert.run_test("deleting a mid-file range's last line makes it outdated", function()
  fresh()
  qf.add_comment('ISSUE', { 4, 5 })
  local c = qf.comments()[1]
  vim.cmd('normal! 5Gdd')
  local state = store.pos(c).state
  vim.cmd('silent edit!')
  assert.equals(state, 'outdated', 'outdated after 5Gdd')
end)

assert.run_test('deleting a 2-3 range at EOF of a 3-line file then undoing restores it', function()
  qf.clear_review()
  rewrite({ 'line 1', 'line 2', 'line 3' })
  qf.add_comment('ISSUE', { 2, 3 })
  local c = qf.comments()[1]

  vim.cmd('2,3d')
  vim.cmd('silent undo')
  local pos = store.pos(c)
  local lnum, end_lnum = store.range(c)
  local p = track.positions(file_buf)[c.id]
  vim.cmd('silent edit!')

  assert.equals(lnum, 2, 'on line 2 after undo')
  assert.equals(end_lnum, 3, 'ends on line 3 after undo')
  assert.equals(pos.state, 'current', 'current after undo')
  assert.truthy(p and p.lnum == 2 and p.end_lnum == 3 and p.state == 'current',
    'positions() agrees after undo')
end)

assert.run_test("deleting only a range's last line at EOF then undoing makes it current", function()
  local c = four_with_eof_range()
  vim.cmd('normal! 4Gdd')
  vim.cmd('silent undo')
  local pos = store.pos(c)
  local lnum, end_lnum = store.range(c)
  vim.cmd('silent edit!')
  assert.equals(lnum, 3, 'on line 3 after undo')
  assert.equals(end_lnum, 4, 'ends on line 4 after undo')
  assert.equals(pos.state, 'current', 'current after undo')
end)

assert.run_test('dd on a commented line: sign and view agree without a save', function()
  fresh()
  vim.fn.cursor(5, 1)
  qf.add_comment('ISSUE')
  -- Run what the reload in fresh() scheduled (a refresh, which redraws every
  -- buffer's signs), so only the TextChanged redraw can fix the sign
  local drained = false
  vim.schedule(function() drained = true end)
  vim.wait(1000, function() return drained end)

  vim.cmd('normal! 5Gdd')
  assert.length(signs_on(file_buf, 5), 1, 'the sign slid onto line 5 (precondition)')
  -- Headless 'normal!' may not fire TextChanged: fire it, then wait out the
  -- debounced redraw
  local tick = vim.api.nvim_buf_get_changedtick(file_buf)
  vim.api.nvim_exec_autocmds('TextChanged', { buffer = file_buf })
  local c = qf.comments()[1]
  local l = store.range(c)
  local ok_wait = vim.wait(2000, function() return #signs_on(file_buf, l) > 0 end, 20)
  local marks = vim.api.nvim_buf_get_extmarks(file_buf, utils.get_ns_id(), 0, -1, {})
  local lines = float_lines(l)
  local after_tick = vim.api.nvim_buf_get_changedtick(file_buf)
  local state = store.pos(c).state
  vim.cmd('silent edit!')

  assert.equals(state, 'outdated', 'outdated after dd')
  assert.truthy(ok_wait, 'sign redrawn on the line store.range reports')
  assert.equals(after_tick, tick, 'no further change made')
  for _, m in ipairs(marks) do
    assert.equals(m[2] + 1, l, 'every sign on the line store.range reports')
  end
  assert.truthy(#lines > 0, 'the float shows the comment on its line')
end)

assert.run_test('an in-session edit: sign, quickfix row and float all equal track.positions()', function()
  fresh()
  vim.fn.cursor(5, 1)
  qf.add_comment('ISSUE')
  qf.add_comment('NOTE', { 7, 8 })
  local drained = false
  vim.schedule(function() drained = true end)
  vim.wait(1000, function() return drained end)
  local ids = {}
  for i, c in ipairs(qf.comments()) do ids[i] = c.id end

  vim.api.nvim_buf_set_lines(file_buf, 0, 0, false, { 'new 1', 'new 2' })
  vim.api.nvim_exec_autocmds('TextChanged', { buffer = file_buf })
  local redrawn = vim.wait(2000, function() return #signs_on(file_buf, 7) > 0 end, 20)
  local tick = vim.api.nvim_buf_get_changedtick(file_buf)
  local p = track.positions(file_buf)

  -- Signs: on every line of each comment's range, and nowhere else
  local sign_lines = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(file_buf, utils.get_ns_id(), 0, -1, {})) do
    sign_lines[m[2] + 1] = true
  end
  local want_lines = {}
  for _, id in ipairs(ids) do
    for l = p[id].lnum, p[id].end_lnum do want_lines[l] = true end
  end

  -- The float opens on each comment's line, and not on its old line
  local float_first = float_lines(p[ids[1]].lnum)
  local float_range = float_lines(p[ids[2]].end_lnum)
  local float_old = float_lines(5)

  -- The quickfix rows
  qf.show_list()
  local rows = {}
  for _, row in ipairs(vim.fn.getqflist()) do
    if type(row.user_data) == 'table' then rows[row.user_data.id] = row end
  end

  -- Fresh tables: mutating one changes nothing shared
  local mine = store.pos(qf.comments()[1])
  mine.lnum = 999
  p[ids[1]].lnum = 999
  local copy = qf.comments()[1]
  copy.anchor.lnum = 1
  copy.anchor.end_lnum = 1
  local live_anchor = store.get(ids[1]).anchor.lnum
  local again = track.positions(file_buf)
  local reread = store.pos(qf.comments()[1]).lnum
  local after_tick = vim.api.nvim_buf_get_changedtick(file_buf)
  vim.cmd('silent edit!')

  assert.truthy(redrawn, 'signs redrawn after the edit')
  assert.equals(after_tick, tick, 'everything read in one tick')
  assert.equals(again[ids[1]].lnum, 7, 'first comment shifted to line 7')
  assert.equals(again[ids[1]].state, 'shifted', 'first comment shifted')
  assert.equals(again[ids[2]].lnum, 9, 'range comment starts on line 9')
  assert.equals(again[ids[2]].end_lnum, 10, 'range comment ends on line 10')
  assert.equals(reread, 7, 'store.pos is a fresh table')
  assert.equals(live_anchor, 5, "a copy's anchor is not the live anchor")
  for l in pairs(want_lines) do
    assert.truthy(sign_lines[l], 'a sign on line ' .. l)
  end
  for l in pairs(sign_lines) do
    assert.truthy(want_lines[l], 'no sign off a comment, on line ' .. l)
  end
  for _, id in ipairs(ids) do
    assert.truthy(rows[id], 'a quickfix row for ' .. id)
    assert.equals(rows[id].lnum, again[id].lnum, 'qf row lnum is positions() lnum')
    assert.equals(rows[id].end_lnum, again[id].end_lnum, 'qf row end_lnum is positions() end_lnum')
  end
  assert.truthy(#float_first > 0, 'float on the first comment at its position')
  assert.truthy(#float_range > 0, 'float on the range comment at its end line')
  assert.length(float_old, 0, 'no float on the old line')
end)

assert.run_test(':colorscheme keeps QuickfixReviewOutdated linked', function()
  vim.cmd('colorscheme default')
  local hl = vim.api.nvim_get_hl(0, { name = 'QuickfixReviewOutdated' })
  assert.equals(hl.link, 'DiagnosticWarn', 'linked after :colorscheme')
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

assert.run_test('a diff buffer holding the snapshot shows the comment as current in the float', function()
  fresh()
  vim.fn.cursor(5, 1)
  qf.add_comment('ISSUE')
  local lines = vim.deepcopy(TEN)
  lines[5] = 'line 5 rewritten'
  rewrite(lines)
  local c = qf.comments()[1]
  assert.equals(store.pos(c).state, 'outdated', 'outdated in the working file')

  local fugbuf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(fugbuf, 0, -1, false, TEN)
  vim.api.nvim_buf_set_name(fugbuf, 'fugitive://' .. vim.fn.getcwd() .. '/.git//0/' .. test_file)
  local ok, err = pcall(function()
    vim.cmd('buffer ' .. fugbuf)
    local float = float_lines(5)
    assert.truthy(float[1] ~= 'outdated — code changed since comment', 'no outdated header')
    assert.equals(float[1], store.headline(c), 'headline first')
    local signs = signs_on(fugbuf, 5)
    assert.length(signs, 1, 'sign on line 5 of the diff buffer')
    assert.truthy(signs[1] and signs[1].sign_hl_group ~= utils.OUTDATED_HL, 'not the outdated highlight')
  end)
  vim.cmd('buffer ' .. file_buf)
  vim.cmd('bwipeout! ' .. fugbuf)
  if not ok then error(err, 0) end
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
    assert.equals(store.pos(c).state, 'shifted', 'state')

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
      local snapshots = require('quickfix-review.snapshots')
      assert.equals(snapshots.hash(vim.api.nvim_buf_get_lines(buf, 0, -1, false)),
        snapshots.hash(vim.fn.readfile(path)), 'buffer sha == disk sha')
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
check_eol('a file with a NUL on the commented line is current loaded and from disk', 'a\nb\0x\nc\n', 'edit')
check_eol('a CRLF file with a CR CR LF line is not outdated', 'a\r\nb\r\r\nc\r\n', 'edit')
check_eol('a CRLF file with a CR CR LF line read as unix is not outdated', 'a\r\nb\r\r\nc\r\n', 'edit ++ff=unix')

-- A latin1 file (not valid UTF-8), opened with `edit_cmd`: the buffer holds
-- it converted to UTF-8, and so does the content read from disk once the
-- buffer is wiped. `content` defaults to 'a\ncaf\xe9\nc\n'
local function check_latin1(name, edit_cmd, content)
  assert.run_test(name, function()
    local path = vim.fn.tempname() .. '-latin1.txt'
    local fh = io.open(path, 'wb')
    fh:write(content or 'a\ncaf\xe9\nc\n')
    fh:close()
    local ok, err = pcall(function()
      qf.clear_review()
      vim.cmd(edit_cmd .. ' ' .. vim.fn.fnameescape(path))
      local buf = vim.api.nvim_get_current_buf()
      assert.equals(vim.bo[buf].fileencoding, 'latin1', 'read as latin1')
      vim.fn.cursor(2, 1)
      qf.add_comment('NOTE')
      local c = qf.comments()[1]
      local snapshots = require('quickfix-review.snapshots')
      local snap = snapshots.get(c.anchor.sha)
      assert.equals(snap and snap[2], 'café', 'snapshot holds UTF-8 lines')
      assert.equals(store.pos(c).state, 'current', 'current while loaded')
      vim.api.nvim_set_current_buf(file_buf)
      vim.cmd('bwipeout! ' .. buf)
      assert.equals(store.pos(c).state, 'current', 'current read from disk')
      assert.equals((store.range(c)), 2, 'line 2')
      assert.equals(track.positions(path)[c.id].state, 'current', 'positions from disk')
    end)
    os.remove(path)
    vim.api.nvim_set_current_buf(file_buf)
    qf.clear_review()
    if not ok then error(err, 0) end
  end)
end

check_latin1('a latin1 file opened with ++enc=latin1 is current loaded and from disk', 'edit ++enc=latin1')
check_latin1('a latin1 file detected through fileencodings is current loaded and from disk', 'edit')
-- A cut-off sequence followed by the final newline is not UTF-8 either
check_latin1('a latin1 file ending in a lead byte and a newline is current loaded and from disk',
  'edit', 'a\ncaf\xe9\n')

-- A file (`content`, commented on line 2) that is not strict UTF-8 but
-- that Neovim reads as UTF-8, keeping the bytes as they are; so must the
-- content read from disk
local function check_utf8(name, content)
  assert.run_test(name, function()
    local path = vim.fn.tempname() .. '-utf8.txt'
    local fh = io.open(path, 'wb')
    fh:write(content)
    fh:close()
    local ok, err = pcall(function()
      qf.clear_review()
      vim.cmd('edit ' .. vim.fn.fnameescape(path))
      local buf = vim.api.nvim_get_current_buf()
      assert.equals(vim.bo[buf].fileencoding, 'utf-8', 'read as utf-8')
      vim.fn.cursor(2, 1)
      qf.add_comment('NOTE')
      local c = qf.comments()[1]
      assert.equals(store.pos(c).state, 'current', 'current while loaded')
      vim.api.nvim_set_current_buf(file_buf)
      vim.cmd('bwipeout! ' .. buf)
      assert.equals(store.pos(c).state, 'current', 'current read from disk')
      assert.equals(track.positions(path)[c.id].state, 'current', 'positions from disk')
    end)
    os.remove(path)
    vim.api.nvim_set_current_buf(file_buf)
    qf.clear_review()
    if not ok then error(err, 0) end
  end)
end

-- A surrogate (ED A0 80)
check_utf8('a file with a UTF-8 surrogate is current loaded and from disk', 'a\nx\xed\xa0\x80\nc\n')
-- A lead byte cut off by the end of the file, with no final newline
check_utf8('a file ending in a cut-off UTF-8 sequence is current loaded and from disk', 'a\ncaf\xe9')

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
  local fug_signs = #vim.api.nvim_buf_get_extmarks(fugbuf, utils.get_ns_id(), 0, -1, {})
  vim.cmd('buffer ' .. file_buf)
  vim.cmd('bwipeout! ' .. fugbuf)

  local after = store.pos(qf.comments()[1])
  assert.equals(after.lnum, before.lnum, 'lnum unchanged')
  assert.equals(after.end_lnum, before.end_lnum, 'end_lnum unchanged')
  assert.equals(after.state, 'current', 'still current')
  assert.equals(log_size(), logged, 'nothing logged')
  assert.equals(fug_signs, 0, 'no sign in a diff buffer that differs from the snapshot')
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

-- Before 7dv8 a sha-less comment whose span changed read shifted and was
-- re-anchored on save; the span check must not make it outdated
assert.run_test('a sha-less comment follows its mark when its span changes, saved', function()
  fresh()
  store.add({ filename = abs, lnum = 4, end_lnum = 5, kind = 'note', body = 'legacy' })
  vim.cmd('silent edit!')
  local c = qf.comments()[1]
  assert.equals(c.anchor.sha, nil, 'no sha')

  vim.cmd('normal! 5GOX')
  local pos = store.pos(c)
  assert.truthy(pos.state ~= 'outdated', 'not outdated after 5GOX: ' .. tostring(pos.state))
  assert.equals(pos.lnum, 4, 'mark starts on line 4')
  assert.equals(pos.end_lnum, 6, 'mark ends on line 6')
  save()

  local a = qf.comments()[1].anchor
  assert.equals(a.lnum, 4, 'stored start follows the mark')
  assert.equals(a.end_lnum, 6, 'stored end follows the mark')

  restart()
  local lnum, end_lnum = store.range(qf.comments()[1])
  assert.equals(lnum, 4, 'on line 4 after reload')
  assert.equals(end_lnum, 6, 'ends on line 6 after reload')
end)

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

assert.run_test('an unsaved edit inside a range: outdated, and current again after undo', function()
  fresh()
  vim.fn.cursor(2, 1)
  qf.add_comment('ISSUE')
  local c = qf.comments()[1]
  assert.truthy(c.anchor.sha, 'has a sha')

  vim.cmd('normal! 2Gciwfoo')
  local edited = store.pos(c).state
  local p = track.positions(file_buf)[c.id]

  vim.cmd('silent undo')
  local pos = store.pos(c)
  local lnum, end_lnum = store.range(c)
  local q = track.positions(file_buf)[c.id]

  vim.cmd('normal! 2Gciwline')
  local retyped = store.pos(c).state
  vim.cmd('silent edit!')

  assert.equals(edited, 'outdated', 'outdated after ciw')
  assert.truthy(p and p.state == 'outdated', 'positions() agrees after ciw')
  assert.equals(pos.state, 'current', 'current after undo')
  assert.equals(lnum, 2, 'on line 2 after undo')
  assert.equals(end_lnum, 2, 'ends on line 2 after undo')
  assert.truthy(q and q.state == 'current', 'positions() agrees after undo')
  assert.equals(retyped, 'current', 'current after retyping the same text')
end)

-- Run the callbacks scheduled so far (e.g. deferred list refills)
local function drain()
  local drained = false
  vim.schedule(function() drained = true end)
  vim.wait(1000, function() return drained end)
end

assert.run_test('an edit inside a range, redrawn then saved: the list shows it outdated', function()
  fresh()
  vim.fn.cursor(2, 1)
  qf.add_comment('ISSUE')
  local c = qf.comments()[1]
  assert.truthy(c.anchor.sha, 'has a sha')
  -- No refill left pending from the setup, so only the save's can tag it
  drain()
  qf.show_list()
  assert.truthy(not vim.startswith(vim.fn.getqflist()[1].text, '[outdated]'), 'not outdated before the edit')

  vim.cmd('normal! 2Gciwfoo')
  -- Cache the position as the TextChanged sign redraw does, before the save
  assert.equals(track.positions(file_buf)[c.id].state, 'outdated', 'outdated before the save')
  save()
  -- Run the refill the save deferred until after the write
  drain()

  local text
  for _, item in ipairs(vim.fn.getqflist()) do
    if item.user_data and item.user_data.id == c.id then text = item.text end
  end
  rewrite(TEN)
  assert.truthy(text, 'the comment is in the list')
  assert.truthy(vim.startswith(text, '[outdated] '), 'list row tagged outdated, got ' .. tostring(text))
end)

assert.run_test('an unsaved edit inside a legacy range with no sha is not outdated', function()
  fresh()
  store.add({ filename = abs, lnum = 4, end_lnum = 5, kind = 'note', body = 'legacy' })
  vim.cmd('silent edit!')
  vim.cmd('let &undolevels = &undolevels')
  local c = qf.comments()[1]
  assert.equals(c.anchor.sha, nil, 'no sha')
  vim.cmd('normal! 4Gciwfoo')
  local state = store.pos(c).state
  vim.cmd('silent edit!')
  assert.truthy(state ~= 'outdated', 'not outdated, got ' .. tostring(state))
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
check_eol_write('a saved CRLF file with a CR CR LF line is re-anchored once', 'a\r\nb\r\r\nc\r\n', 'edit')
check_eol_write('a saved CRLF file with a CR CR LF line read as unix is re-anchored once',
  'a\r\nb\r\r\nc\r\n', 'edit ++ff=unix')

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

-- Run `fn(path, buf)` on a temp file holding TEN, loaded as the current
-- buffer in a fresh review; the file and its buffer are removed after
local function with_temp_file(fn)
  local path = vim.fn.fnamemodify(vim.fn.tempname() .. '-tmp.txt', ':p')
  vim.fn.writefile(TEN, path)
  local extra = {}
  local ok, err = pcall(function()
    qf.clear_review()
    vim.cmd('edit ' .. vim.fn.fnameescape(path))
    fn(path, vim.api.nvim_get_current_buf(), extra)
  end)
  vim.api.nvim_set_current_buf(file_buf)
  for _, p in ipairs({ path, unpack(extra) }) do
    local b = vim.fn.bufnr(p)
    if b > 0 then vim.cmd('bwipeout! ' .. b) end
    os.remove(p)
  end
  qf.clear_review()
  if not ok then error(err, 0) end
end

assert.run_test(':ReviewReanchor, then :bd with no save: current at the new line from disk', function()
  with_temp_file(function(path, buf)
    vim.fn.cursor(5, 1)
    qf.add_comment('ISSUE')
    vim.api.nvim_set_current_buf(file_buf)
    vim.cmd('bwipeout ' .. buf)
    local lines = vim.deepcopy(TEN)
    lines[5] = 'line 5 rewritten'
    vim.fn.writefile(lines, path)
    -- Relocated from disk: caches the outdated pos for this file's content
    assert.equals(store.pos(qf.comments()[1]).state, 'outdated', 'outdated from disk')

    vim.cmd('edit ' .. vim.fn.fnameescape(path))
    buf = vim.api.nvim_get_current_buf()
    vim.fn.cursor(5, 1)
    vim.cmd('ReviewReanchor')
    assert.equals(store.pos(qf.comments()[1]).state, 'current', 'current once re-anchored')
    vim.api.nvim_set_current_buf(file_buf)
    vim.cmd('bdelete ' .. buf) -- unloaded, not saved (it had no edits)

    local c = qf.comments()[1]
    assert.equals(store.pos(c).state, 'current', 'current from disk after :bd')
    assert.equals((store.range(c)), 5, 'line 5 from disk after :bd')

    vim.cmd('edit ' .. vim.fn.fnameescape(path))
    c = qf.comments()[1]
    assert.equals(store.pos(c).state, 'current', 'current after reopening')
    assert.equals((store.range(c)), 5, 'line 5 after reopening')
  end)
end)

assert.run_test(':saveas does not write anchors for the new file', function()
  with_temp_file(function(_, buf, extra)
    vim.fn.cursor(5, 1)
    qf.add_comment('ISSUE')
    local anchor = vim.deepcopy(qf.comments()[1].anchor)
    local logged = log_size()
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { 'top' })
    local other = vim.fn.fnamemodify(vim.fn.tempname() .. '-saveas.txt', ':p')
    table.insert(extra, other)
    vim.cmd('silent saveas ' .. vim.fn.fnameescape(other))
    assert.equals(vim.api.nvim_buf_get_name(buf), other, 'buffer renamed')
    assert.equals(log_size(), logged, 'nothing logged')
    assert.truthy(vim.deep_equal(qf.comments()[1].anchor, anchor), 'anchor unchanged')
  end)
end)

assert.run_test(':w !cmd does not write anchors', function()
  with_temp_file(function(path, buf)
    vim.fn.cursor(5, 1)
    qf.add_comment('ISSUE')
    local anchor = vim.deepcopy(qf.comments()[1].anchor)
    local logged = log_size()
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { 'top' })
    vim.cmd('silent w !cat >/dev/null')
    assert.equals(log_size(), logged, 'nothing logged')
    assert.truthy(vim.deep_equal(qf.comments()[1].anchor, anchor), 'anchor unchanged')
    assert.equals(#vim.fn.readfile(path), 10, 'file untouched')
  end)
end)

assert.run_test('a range write to the own file does not write anchors', function()
  with_temp_file(function(path, buf)
    vim.fn.cursor(5, 1)
    qf.add_comment('ISSUE')
    local anchor = vim.deepcopy(qf.comments()[1].anchor)
    local logged = log_size()
    -- Shift the comment, then mark the buffer unmodified, so only the range
    -- keeps the write from anchoring to lines the file won't have (a range
    -- write fires FileWritePost, not BufWritePost; this pins that)
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { 'top' })
    vim.bo[buf].modified = false
    vim.cmd('silent 1,5w!')
    assert.equals(#vim.fn.readfile(path), 5, 'five lines written')
    assert.equals(log_size(), logged, 'nothing logged')
    assert.truthy(vim.deep_equal(qf.comments()[1].anchor, anchor), 'anchor unchanged')
  end)
end)

assert.run_test('a BufWritePre that adds a line: :w still re-anchors to the saved content', function()
  with_temp_file(function(path, buf)
    vim.fn.cursor(5, 1)
    qf.add_comment('ISSUE')
    local old_sha = qf.comments()[1].anchor.sha
    local logged = log_size()
    -- A formatter-like hook: the line count changes during the write itself
    local group = vim.api.nvim_create_augroup('QfrTestBufWritePre', { clear = true })
    vim.api.nvim_create_autocmd('BufWritePre', {
      group = group,
      buffer = buf,
      callback = function() vim.api.nvim_buf_set_lines(buf, 0, 0, false, { 'top' }) end,
    })
    local ok, err = pcall(vim.cmd, 'silent write')
    vim.api.nvim_del_augroup_by_id(group)
    if not ok then error(err, 0) end
    local saved = vim.fn.readfile(path)
    assert.equals(#saved, 11, 'eleven lines written')
    assert.equals(log_size(), logged + 1, 'one update')
    local c = qf.comments()[1]
    assert.equals(c.anchor.sha, require('quickfix-review.snapshots').hash(saved), 'anchored to the saved content')
    assert.truthy(c.anchor.sha ~= old_sha, 'new sha')
    assert.equals(c.anchor.lnum, 6, 'shifted by one line')
    assert.equals((store.range(c)), 6, 'range on line 6')
  end)
end)

assert.run_test('the unloaded-file cache keeps at most 32 files', function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  for i = 1, 40 do
    local path = dir .. '/f' .. i .. '.txt'
    vim.fn.writefile({ 'x' .. i }, path)
    track.pos({ id = 'lru' .. i, filename = path, anchor = { lnum = 1, end_lnum = 1 } })
  end
  local count = track._files_count()
  vim.fn.delete(dir, 'rf')
  assert.equals(count, 32, 'capped at 32')
end)

-- Replace the live diff (vim.text.diff on 0.11+, vim.diff on 0.10: M.diff
-- looks it up per call) with a counting wrapper during fn()
-- Returns: how many diffs fn() ran
local function count_diffs(fn)
  local holder, name = vim, 'diff'
  if vim.text and vim.text.diff then holder, name = vim.text, 'diff' end
  local orig = holder[name]
  local n = 0
  holder[name] = function(...)
    n = n + 1
    return orig(...)
  end
  local ok, err = pcall(fn)
  holder[name] = orig
  if not ok then error(err, 0) end
  return n
end

assert.run_test('a refresh with 500 comments over 100 buffers is not comments x buffers', function()
  qf.clear_review()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  -- 1-3 comments on each loaded buffer (200 in all), so the batched
  -- mark/place/sign path runs at scale too
  local bufs, loaded = {}, 0
  for i = 1, 100 do
    local path = dir .. '/loaded' .. i .. '.txt'
    vim.fn.writefile({ 'a' .. i, 'b' .. i, 'c' .. i }, path)
    local buf = vim.fn.bufadd(path)
    vim.fn.bufload(buf)
    table.insert(bufs, buf)
    for l = 1, (i % 3) + 1 do
      store.add({ filename = path, lnum = l, kind = 'note', body = 'l' .. i .. ':' .. l })
      loaded = loaded + 1
    end
  end
  for i = 1, 100 do
    local path = dir .. '/unloaded' .. i .. '.txt'
    vim.fn.writefile({ 'a' .. i, 'b' .. i, 'c' .. i }, path)
    for l = 1, 3 do
      store.add({ filename = path, lnum = l, kind = 'note', body = 'n' .. i .. ':' .. l })
    end
  end
  qf.show_list()

  local orig_match, orig_list = utils.files_match, vim.api.nvim_list_bufs
  local orig_signs = utils.refresh_buffer_signs
  local orig_set, orig_get = vim.api.nvim_buf_set_extmark, vim.api.nvim_buf_get_extmark_by_id
  local matches, lists, signs, sets, gets = 0, 0, 0, 0, 0
  utils.files_match = function(...)
    matches = matches + 1
    return orig_match(...)
  end
  vim.api.nvim_list_bufs = function()
    lists = lists + 1
    return orig_list()
  end
  utils.refresh_buffer_signs = function(...)
    signs = signs + 1
    return orig_signs(...)
  end
  vim.api.nvim_buf_set_extmark = function(...)
    sets = sets + 1
    return orig_set(...)
  end
  vim.api.nvim_buf_get_extmark_by_id = function(...)
    gets = gets + 1
    return orig_get(...)
  end
  local ok, err = pcall(store.refresh)
  utils.files_match, vim.api.nvim_list_bufs = orig_match, orig_list
  utils.refresh_buffer_signs = orig_signs
  vim.api.nvim_buf_set_extmark, vim.api.nvim_buf_get_extmark_by_id = orig_set, orig_get
  local rows = #vim.fn.getqflist()

  vim.fn.setqflist({}, 'f')
  for _, buf in ipairs(bufs) do vim.cmd('silent! bwipeout! ' .. buf) end
  vim.fn.delete(dir, 'rf')
  qf.clear_review()

  assert.truthy(ok, 'refreshed: ' .. tostring(err))
  assert.equals(loaded, 200, 'comments on loaded buffers')
  assert.equals(rows, 500, 'all 500 comments listed')
  assert.truthy(matches < 400, 'files_match calls: ' .. matches .. ' (over 100000 unbatched)')
  assert.truthy(lists <= 5, 'buffer list scans: ' .. lists)
  -- One sign pass per loaded buffer, and a few extmark calls per comment on one
  assert.truthy(signs <= #bufs + 20, 'sign refreshes: ' .. signs)
  assert.truthy(sets <= loaded * 3, 'extmarks set: ' .. sets)
  assert.truthy(gets <= loaded * 3, 'extmarks read: ' .. gets)
end)

assert.run_test('comments sharing one anchor sha are relocated through one diff', function()
  qf.clear_review()
  local path = vim.fn.fnamemodify(vim.fn.tempname() .. '-shared.txt', ':p')
  vim.fn.writefile(TEN, path)
  vim.cmd('silent edit ' .. vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()
  for l = 1, 10 do
    vim.fn.cursor(l, 1)
    qf.add_comment('NOTE')
  end
  local sha = qf.comments()[1].anchor.sha
  local shared = true
  for _, c in ipairs(qf.comments()) do
    if c.anchor.sha ~= sha then shared = false end
  end

  -- Loaded: the reload relocates every comment (relocate_buffer)
  local lines = { 'sxwk top' }
  vim.list_extend(lines, TEN)
  vim.fn.writefile(lines, path)
  local loaded = count_diffs(function() vim.cmd('silent edit!') end)
  local states = {}
  for _, c in ipairs(qf.comments()) do
    local lnum = store.range(c)
    local state = store.pos(c).state
    if state ~= 'shifted' or lnum ~= c.anchor.lnum + 1 then
      table.insert(states, c.anchor.lnum .. '->' .. lnum .. ' ' .. state)
    end
  end

  -- Unloaded: each comment is relocated from disk
  vim.cmd('silent! bwipeout! ' .. buf)
  lines = { 'sxwk top', 'sxwk second' }
  vim.list_extend(lines, TEN)
  vim.fn.writefile(lines, path)
  local unloaded, ranged = count_diffs(function()
    for _, c in ipairs(qf.comments()) do store.range(c) end
  end), {}
  for _, c in ipairs(qf.comments()) do
    if (store.range(c)) ~= c.anchor.lnum + 2 then table.insert(ranged, c.anchor.lnum) end
  end

  qf.clear_review()
  vim.fn.delete(path)

  assert.truthy(shared, 'the comments share one anchor sha')
  assert.equals(loaded, 1, 'one diff on reload')
  assert.length(states, 0, 'every comment shifted by one: ' .. table.concat(states, ', '))
  assert.equals(unloaded, 1, 'one diff from disk')
  assert.length(ranged, 0, 'every comment shifted by two from disk')
end)

assert.run_test('a deleted commented range is not diffed again on every pos', function()
  fresh()
  vim.fn.cursor(5, 1)
  qf.add_comment('ISSUE')
  vim.cmd('normal! 5Gdd')
  local c = qf.comments()[1]
  local states = {}
  local n = count_diffs(function()
    for i = 1, 3 do states[i] = store.pos(c).state end
  end)
  vim.cmd('silent edit!')
  assert.equals(states[3], 'outdated', 'outdated after dd')
  assert.truthy(n <= 1, 'diffs over 3 pos calls: ' .. n)
end)

assert.run_test('BufWipeout forgets the cached content of the buffer', function()
  qf.clear_review()
  local path = vim.fn.fnamemodify(vim.fn.tempname() .. '-wipe.txt', ':p')
  vim.fn.writefile(TEN, path)
  vim.cmd('silent edit ' .. vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()
  vim.fn.cursor(3, 1)
  qf.add_comment('NOTE')
  store.pos(qf.comments()[1])
  local cached = track._has_contents(buf)
  local memo = track._path_memo_size()
  vim.cmd('silent! bwipeout! ' .. buf)
  local after = track._has_contents(buf)
  local memo_after = track._path_memo_size()
  qf.clear_review()
  vim.fn.delete(path)
  assert.truthy(cached, 'content cached while loaded')
  assert.falsy(after, 'content forgotten after wipeout')
  assert.truthy(memo > 0, 'path keys memoised while loaded')
  assert.equals(memo_after, 0, 'path keys forgotten after wipeout')
end)

rewrite(TEN)
test_helper.cleanup_test_environment()

return assert
