-- Tests for the quickfix window hook: delete keys only act on the review list
local test_helper = dofile('test/init.lua')
local assert = dofile('test/assertions.lua')

print('\nRunning quickfix window tests...')

local qf = test_helper.setup_test_environment()
local test_file = test_helper.create_test_file('line 1\nline 2\nline 3\nline 4\n')

-- Whether lhs has a buffer-local normal-mode map in buf
local function has_buf_map(buf, lhs)
  local want = vim.api.nvim_replace_termcodes(lhs, true, true, true)
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
    if vim.api.nvim_replace_termcodes(map.lhs, true, true, true) == want then return true end
  end
  return false
end

-- Two comments, on lines 1 and 3, with the file window current
local function add_two_comments()
  qf.clear_review()
  vim.cmd('only')
  vim.fn.cursor(1, 1)
  qf.add_comment('NOTE')
  vim.fn.cursor(3, 1)
  qf.add_comment('ISSUE')
end

local function close_lists()
  pcall(vim.cmd, 'lclose')
  pcall(vim.cmd, 'cclose')
  vim.cmd('only')
end

-- The floating windows open now
local function floats()
  local found = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(win).relative ~= '' then table.insert(found, win) end
  end
  return found
end

-- Run a quickfix navigation command the way the main loop would: the
-- command, then its CursorMoved (headless Neovim never fires it), then let
-- scheduled callbacks run
local function navigate(cmd)
  vim.cmd(cmd)
  vim.api.nvim_exec_autocmds('CursorMoved', {})
  vim.wait(100, function() return #floats() > 0 end)
end

-- Close any float and leave no list behind for later tests
local function reset_nav()
  vim.api.nvim_exec_autocmds('CursorMoved', {})
  close_lists()
  vim.fn.setqflist({})
end

assert.run_test('cc 1 then cnext shows exactly one float with comment 2', function()
  add_two_comments()
  qf.show_list()
  assert.equals(vim.fn.win_gettype(), '', 'a normal window is current')
  navigate('cc 1')
  assert.equals(vim.fn.line('.'), 1, 'on the first comment')
  navigate('cnext')
  assert.equals(vim.fn.line('.'), 3, 'cnext moved to the second comment')
  local open = floats()
  assert.length(open, 1, 'exactly one float open')
  local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(open[1]), 0, -1, false)
  assert.equals(lines[1], '[ISSUE] Test comment', 'float shows comment 2')
  reset_nav()
  qf.clear_review()
end)

assert.run_test('moving the cursor onto the current entry opens no float', function()
  add_two_comments()
  qf.show_list()
  assert.equals(vim.fn.win_gettype(), '', 'a normal window is current')
  local idx = vim.fn.getqflist({ id = 0, idx = 0 }).idx
  local entry = vim.fn.getqflist({ id = 0, items = 0 }).items[idx]
  assert.equals(entry.lnum, 1, 'current entry is on line 1')
  -- Off the entry: the check records the current idx as seen
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  vim.api.nvim_exec_autocmds('CursorMoved', {})
  vim.wait(100, function() return #floats() > 0 end)
  -- Plain cursor motion onto the entry is not quickfix navigation
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.api.nvim_exec_autocmds('CursorMoved', {})
  vim.wait(100, function() return #floats() > 0 end)
  assert.length(floats(), 0, 'no float open')
  reset_nav()
  qf.clear_review()
end)

assert.run_test('navigating a non-review quickfix list opens no float', function()
  add_two_comments()
  vim.fn.setqflist({}, ' ', { title = 'grep', items = {
    { filename = test_file, lnum = 1, text = 'hit 1' },
    { filename = test_file, lnum = 3, text = 'hit 3' },
  } })
  navigate('cc 1')
  navigate('cnext')
  assert.equals(vim.fn.line('.'), 3, 'cnext moved')
  assert.length(floats(), 0, 'no float open')
  reset_nav()
  qf.clear_review()
end)

assert.run_test('dd in a location list window does not delete a comment', function()
  add_two_comments()
  qf.show_list()
  vim.fn.setloclist(0, {
    { filename = test_file, lnum = 1, text = 'loc 1' },
    { filename = test_file, lnum = 2, text = 'loc 2' },
  })
  vim.cmd('lopen')
  assert.equals(vim.fn.win_gettype(), 'loclist', 'cursor in the location list')
  vim.fn.cursor(1, 1)

  pcall(vim.cmd, 'normal dd')
  qf.delete_comment_from_qf()
  assert.length(qf.comments(), 2, 'comment count unchanged')
  close_lists()
end)

assert.run_test('delete keys are removed when another list replaces the review', function()
  add_two_comments()
  qf.open_list()
  local buf = vim.api.nvim_get_current_buf()
  assert.truthy(has_buf_map(buf, 'dd'), 'dd mapped while the review shows')

  vim.fn.setqflist({ { filename = test_file, lnum = 2, text = 'grep hit' } }, ' ')
  assert.equals(vim.fn.getqflist({ qfbufnr = 0 }).qfbufnr, buf, 'same quickfix buffer')
  assert.falsy(has_buf_map(buf, 'dd'), 'dd unmapped after the refill')
  assert.falsy(has_buf_map(buf, '<leader>cd'), '<leader>cd unmapped after the refill')
  assert.falsy(has_buf_map(buf, '<leader>cr'), 'no hardcoded <leader>cr map')

  pcall(vim.cmd, 'normal dd')
  assert.length(qf.comments(), 2, 'comment count unchanged')
  close_lists()
end)

assert.run_test('dd in the review list deletes the comment on that row', function()
  add_two_comments()
  qf.open_list()
  assert.equals(vim.fn.win_gettype(), 'quickfix', 'cursor in the quickfix window')
  assert.truthy(has_buf_map(vim.api.nvim_get_current_buf(), 'dd'), 'dd mapped')
  vim.fn.cursor(2, 1)

  pcall(vim.cmd, 'normal dd')
  local list = qf.comments()
  assert.length(list, 1, 'one comment left')
  assert.equals(list[1].lnum, 1, 'the line 3 comment was deleted')
  close_lists()
end)

assert.run_test('dd deletes by id after another Neovim reorders the review', function()
  add_two_comments()
  qf.open_list()
  -- Row 1 (not 2): re-rendering the view moves the cursor back to row 1,
  -- so only row 1 exposes a positional lookup
  vim.fn.cursor(1, 1) -- the line 1 comment

  -- Another Neovim deletes the line 1 comment and restores it, which moves
  -- it to the end of the review
  local log_path = test_helper.log_path()
  local first = test_helper.saved(log_path)[1]
  local log = require('quickfix-review.log')
  assert.truthy(log.append(log_path, {
    log.event('delete', { id = first.id, comment = first }),
    log.event('restore', { id = first.id, comment = first }),
  }), 'appended')

  pcall(vim.cmd, 'normal dd')
  local left = qf.comments()
  assert.length(left, 1, 'one comment left')
  assert.equals(left[1].lnum, 3, 'the line 1 comment the cursor was on was deleted')
  close_lists()
end)

assert.run_test('review rows carry the comment id; export keeps the context', function()
  add_two_comments()
  qf.show_list()
  local rows, comments = vim.fn.getqflist(), qf.comments()
  assert.length(rows, 2, 'two rows')
  for i = 1, 2 do
    assert.truthy(comments[i].id, 'comment has an id')
    assert.equals(rows[i].user_data.id, comments[i].id, 'row ' .. i .. ' carries the id')
    assert.equals(type(comments[i].context), 'table', 'stored context kept')
    assert.equals(comments[i].context.id, nil, 'id not written into the stored context')
  end
  local config = require('quickfix-review.config')
  local md = require('quickfix-review.export').to_markdown(comments, config.options)
  assert.truthy(md and md:find('   ```', 1, true), 'export still emits the snippet')
  close_lists()
end)

assert.run_test('show_list maps dd when the quickfix window already shows another list', function()
  add_two_comments()
  -- Push enough lists that the review view falls off the quickfix stack
  for i = 1, 11 do
    vim.fn.setqflist({ { filename = test_file, lnum = 2, text = 'grep hit ' .. i } }, ' ')
  end
  vim.cmd('copen')
  vim.cmd('wincmd p')

  qf.show_list()
  local buf = vim.fn.getqflist({ qfbufnr = 0 }).qfbufnr
  assert.truthy(has_buf_map(buf, 'dd'), 'dd mapped on the fresh review list')

  -- Focus the window directly: :copen would refill it and fire FileType again
  vim.fn.win_gotoid(vim.fn.win_findbuf(buf)[1])
  assert.equals(vim.fn.win_gettype(), 'quickfix', 'in the quickfix window')
  vim.fn.cursor(1, 1)
  pcall(vim.cmd, 'normal dd')
  local list = qf.comments()
  assert.length(list, 1, 'one comment left')
  assert.equals(list[1].lnum, 3, 'the line 1 comment was deleted')
  close_lists()
end)

assert.run_test("another plugin's dd in the quickfix window survives a refill", function()
  add_two_comments()
  qf.open_list()
  local buf = vim.api.nvim_get_current_buf()
  vim.fn.setqflist({ { filename = test_file, lnum = 2, text = 'grep hit' } }, ' ')
  assert.falsy(has_buf_map(buf, 'dd'), 'review dd removed')

  vim.keymap.set('n', 'dd', '<Nop>', { buffer = buf, desc = 'other plugin' })
  vim.keymap.set('n', '<leader>cd', '<Nop>', { buffer = buf, desc = 'other plugin' })
  vim.fn.setqflist({ { filename = test_file, lnum = 3, text = 'grep hit 2' } }, ' ')
  assert.truthy(has_buf_map(buf, 'dd'), 'other dd kept')
  assert.truthy(has_buf_map(buf, '<leader>cd'), 'other <leader>cd kept')
  assert.equals(vim.fn.maparg('dd', 'n', false, true).desc, 'other plugin', 'dd is the other plugin map')
  pcall(vim.keymap.del, 'n', 'dd', { buffer = buf })
  pcall(vim.keymap.del, 'n', '<leader>cd', { buffer = buf })
  close_lists()
end)

assert.run_test('dd with an unreadable storage file says so and deletes nothing', function()
  add_two_comments()
  qf.open_list()
  vim.fn.cursor(1, 1)
  local log_path = test_helper.log_path()
  vim.fn.writefile({ 'not json' }, log_path)

  local calls = {}
  local original_notify, original_print = vim.notify, print
  vim.notify = function(msg, level) table.insert(calls, { msg = msg, level = level }) end
  local printed = {}
  print = function(...) table.insert(printed, table.concat({ ... }, ' ')) end
  local ok, err = pcall(qf.delete_comment_from_qf)
  vim.notify, print = original_notify, original_print
  assert.truthy(ok, 'no error: ' .. tostring(err))

  local warned = false
  for _, c in ipairs(calls) do
    if c.level == vim.log.levels.WARN and c.msg:find('the comment was not deleted', 1, true) then warned = true end
  end
  assert.truthy(warned, 'warns that the comment was not deleted')
  for _, line in ipairs(printed) do
    assert.falsy(line:find('no longer exists', 1, true), 'does not claim the comment is gone')
  end
  assert.equals(vim.fn.readfile(log_path)[1], 'not json', 'log untouched')
  assert.length(vim.fn.readfile(log_path), 1, 'nothing appended')

  test_helper.remove_storage()
  close_lists()
end)

assert.run_test(':ReviewTrash lists deleted comments, newest first, in a list of its own', function()
  add_two_comments()
  qf.show_list()
  local review_title = vim.fn.getqflist({ title = 0 }).title
  local ids = {}
  for i, c in ipairs(qf.comments()) do ids[i] = c.id end
  qf.delete_comment({ 1, 1 })
  qf.delete_comment({ 3, 3 })
  local live = vim.deepcopy(qf.comments())

  qf.show_trash()
  local list = vim.fn.getqflist({ title = 0, items = 0 })
  assert.equals(list.title, 'Review trash', 'titled')
  assert.truthy(list.title ~= review_title, 'not the review title')
  assert.equals(list.items[1].user_data.id, ids[2], 'newest deletion first')
  assert.equals(list.items[2].user_data.id, ids[1], 'then the older one')
  assert.equals(list.items[1].lnum, 3, 'at its line')
  assert.truthy(list.items[1].text:find('ISSUE', 1, true) and list.items[1].text:find(ids[2], 1, true),
    'kind and id shown: ' .. list.items[1].text)
  assert.truthy(vim.deep_equal(qf.comments(), live), 'the review is unchanged')

  -- A change to the review refreshes its own list, not the trash list
  vim.fn.cursor(2, 1)
  qf.add_comment('NOTE')
  local after = vim.fn.getqflist({ title = 0, items = 0 })
  assert.equals(after.title, 'Review trash', 'trash list still current')
  assert.length(after.items, #list.items, 'trash list not overwritten')
  close_lists()
  qf.clear_review()
end)

assert.run_test('navigating Review trash opens no float', function()
  add_two_comments()
  qf.delete_comment({ 1, 1 })
  qf.delete_comment({ 3, 3 })
  -- Live comments on the trash rows' lines, so only the list decides
  vim.fn.cursor(1, 1)
  qf.add_comment('NOTE')
  vim.fn.cursor(3, 1)
  qf.add_comment('NOTE')
  qf.show_trash()
  assert.equals(vim.fn.getqflist({ title = 0 }).title, 'Review trash', 'trash list current')
  navigate('cc 1')
  navigate('cnext')
  assert.length(floats(), 0, 'no float open')
  reset_nav()
  qf.clear_review()
end)

-- The review list's selected entry: its idx and item
local function selected()
  local info = vim.fn.getqflist({ id = 0, idx = 0, items = 0 })
  return info.idx, info.items[info.idx]
end

-- Plain cursor motion onto `lnum`, then let the scheduled check run
local function move_to(lnum)
  vim.api.nvim_win_set_cursor(0, { lnum, 0 })
  vim.api.nvim_exec_autocmds('CursorMoved', {})
  vim.wait(100, function() return #floats() > 0 end)
end

assert.run_test('adding or deleting another comment keeps the same comment selected', function()
  qf.clear_review()
  vim.cmd('only')
  for _, lnum in ipairs({ 1, 3, 4 }) do
    vim.fn.cursor(lnum, 1)
    qf.add_comment('NOTE')
  end
  qf.show_list()
  vim.fn.setqflist({}, 'a', { idx = 3 })
  local _, item = selected()
  local id = item.user_data.id
  vim.fn.cursor(2, 1)
  qf.add_comment('ISSUE')
  local idx, now = selected()
  assert.equals(idx, 3, 'selection kept (the list is in creation order)')
  assert.equals(now.user_data.id, id, 'same comment selected after an add')
  qf.delete_comment({ 1, 1 })
  idx, now = selected()
  assert.equals(idx, 2, 'selection shifted with its comment')
  assert.equals(now.user_data.id, id, 'same comment selected after a delete')
  reset_nav()
  qf.clear_review()
end)

assert.run_test('a refill that shifts the selection is not navigation', function()
  add_two_comments()
  qf.show_list()
  navigate('cc 2')
  move_to(2)
  assert.length(floats(), 0, 'float closed off the entry')
  -- Delete the comment before the selection: the selected one is now entry 1
  qf.delete_comment({ 1, 1 })
  local idx, item = selected()
  assert.equals(idx, 1, 'selection shifted')
  move_to(item.lnum)
  assert.length(floats(), 0, 'no float open')
  reset_nav()
  qf.clear_review()
end)

assert.run_test('a refill that clamps the selection is not navigation', function()
  add_two_comments()
  qf.show_list()
  navigate('cc 2')
  move_to(2)
  -- Delete the selected (last) comment: the selection clamps to entry 1
  qf.delete_comment({ 3, 3 })
  local idx, item = selected()
  assert.equals(idx, 1, 'selection clamped')
  move_to(item.lnum)
  assert.length(floats(), 0, 'no float open')
  reset_nav()
  qf.clear_review()
end)

assert.run_test('moving onto the current entry right after showing the list opens no float', function()
  add_two_comments()
  -- Free every list, so showing creates a new review list (a new id)
  close_lists()
  vim.fn.setqflist({}, 'f')
  vim.fn.cursor(2, 1)
  qf.show_list()
  move_to(1)
  assert.length(floats(), 0, 'no float open')
  reset_nav()
  qf.clear_review()
end)

assert.run_test('cnext into a file whose comment relocates on read shows it', function()
  local path = vim.fn.tempname() .. '-moved.txt'
  vim.fn.writefile({ 'a', 'b', 'c', 'd', 'e' }, path)
  local ok, err = pcall(function()
    qf.clear_review()
    vim.cmd('only')
    vim.fn.cursor(1, 1)
    qf.add_comment('NOTE')
    local home = vim.api.nvim_get_current_buf()
    vim.cmd('edit ' .. vim.fn.fnameescape(path))
    local buf = vim.api.nvim_get_current_buf()
    vim.fn.cursor(4, 1)
    qf.add_comment('ISSUE')
    vim.api.nvim_set_current_buf(home)
    vim.cmd('bwipeout! ' .. buf)
    qf.show_list()
    -- Two lines inserted above the comment while the file is not loaded
    vim.fn.writefile({ 'x', 'y', 'a', 'b', 'c', 'd', 'e' }, path)
    navigate('cc 1')
    navigate('cnext')
    local idx = selected()
    assert.equals(idx, 2, 'on the second entry')
    assert.equals(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ':p'),
      vim.fn.fnamemodify(path, ':p'), 'in the moved file')
    assert.equals(vim.fn.line('.'), 6, 'on the relocated line')
    local open = floats()
    assert.length(open, 1, 'exactly one float open')
    local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(open[1]), 0, -1, false)
    assert.equals(lines[1], '[ISSUE] Test comment', 'float shows the moved comment')
  end)
  pcall(reset_nav)
  pcall(vim.cmd, 'bwipeout! ' .. vim.fn.fnameescape(path))
  os.remove(path)
  qf.clear_review()
  if not ok then error(err, 0) end
end)

qf.clear_review()
test_helper.cleanup_test_environment()

return assert
