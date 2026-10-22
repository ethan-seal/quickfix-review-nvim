-- Tests for the quickfix window hook: delete keys only act on the review list
local test_helper = dofile((vim.env.QFR_TEST_ROOT or '.') .. '/test/init.lua')
local assert = dofile(test_helper.root .. '/test/assertions.lua')

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

-- Fire the CursorMoved the main loop dispatches after a relocated jump's
-- finish (see jump.lua) moved the cursor (navigate fired the jump's own one
-- before the finish ran), then let scheduled callbacks run
local function settle_jump()
  vim.wait(50, function() return false end)
  vim.api.nvim_exec_autocmds('CursorMoved', {})
  vim.wait(50, function() return false end)
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

assert.run_test('the qf delete key follows keymaps.delete_comment', function()
  local ok, err = pcall(function()
    qf.setup({ storage_file = test_helper.storage_file, keymaps = { delete_comment = '<leader>cx' } })
    add_two_comments()
    qf.open_list()
    local buf = vim.api.nvim_get_current_buf()
    assert.truthy(has_buf_map(buf, 'dd'), 'dd mapped')
    assert.truthy(has_buf_map(buf, '<leader>cx'), 'configured key mapped')
    assert.falsy(has_buf_map(buf, '<leader>cd'), 'no hardcoded <leader>cd')

    vim.fn.cursor(2, 1)
    vim.fn.maparg('<leader>cx', 'n', false, true).callback()
    assert.length(qf.comments(), 1, 'one comment left')
    close_lists()

    qf.setup({ storage_file = test_helper.storage_file, keymaps = { delete_comment = false } })
    add_two_comments()
    qf.open_list()
    buf = vim.api.nvim_get_current_buf()
    assert.truthy(has_buf_map(buf, 'dd'), 'dd mapped with delete_comment = false')
    assert.falsy(has_buf_map(buf, '<leader>cx'), 'old configured key gone')
    assert.falsy(has_buf_map(buf, '<leader>cd'), 'no <leader>cd')
  end)
  close_lists()
  test_helper.setup_test_environment()
  if not ok then error(err, 0) end
end)

assert.run_test("edit from the review list edits the row's comment", function()
  add_two_comments()
  qf.open_list()
  assert.equals(vim.fn.win_gettype(), 'quickfix', 'cursor in the quickfix window')
  vim.fn.cursor(2, 1)
  local id = vim.fn.getqflist()[2].user_data.id

  local default
  local ok, err = pcall(function()
    qf.edit_comment()
    local buf = vim.api.nvim_get_current_buf()
    assert.equals(vim.api.nvim_buf_get_name(buf), 'quickfix-review://edit/' .. id, 'editor float for the row')
    default = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'Edited from list' })
    vim.api.nvim_feedkeys(vim.keycode('<CR>'), 'x', false)
  end)
  -- A float a failure left open would take over every later test
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
    if name:match('^quickfix%-review://edit/') then pcall(vim.api.nvim_win_close, win, true) end
  end
  if not ok then error(err, 0) end

  assert.equals(default, 'Test comment', 'editor holds the row body')
  local by_line = {}
  for _, c in ipairs(qf.comments()) do by_line[c.lnum] = c end
  assert.equals(by_line[3].body, 'Edited from list', 'the line 3 comment was edited')
  assert.equals(by_line[3].id, id, 'same id')
  assert.equals(by_line[1].body, 'Test comment', 'the line 1 comment is unchanged')
  local row = vim.fn.getqflist()[2]
  assert.equals(row.user_data.id, id, 'row keeps its comment')
  assert.truthy(row.text:find('Edited from list', 1, true), 'row text updated')
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
  local log_path = test_helper.segment_path(1)
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
  local log_path = test_helper.segment_path(1)
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

assert.run_test(':ReviewTrash shows ? for a removal whose ts is not a number', function()
  add_two_comments()
  local id = qf.comments()[1].id
  local fh = io.open(test_helper.segment_path(1), 'ab')
  fh:write(vim.json.encode({ op = 'delete', id = id, eid = 'foreign-1', ts = 'x' }) .. '\n')
  fh:close()
  local ok, err = pcall(qf.show_trash)
  assert.truthy(ok, 'no error: ' .. tostring(err))
  local list = vim.fn.getqflist({ title = 0, items = 0 })
  assert.equals(list.title, 'Review trash', 'trash listed')
  assert.equals(list.items[1].user_data.id, id, 'the deleted comment')
  assert.truthy(list.items[1].text:find('^%? delete'), 'time shown as ?: ' .. list.items[1].text)
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
    -- The CursorMoved caused by the finish's own cursor move
    settle_jump()
    local idx = selected()
    assert.equals(idx, 2, 'on the second entry')
    assert.equals(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ':p'),
      vim.fn.fnamemodify(path, ':p'), 'in the moved file')
    assert.equals(vim.fn.line('.'), 6, 'on the relocated line')
    local open = floats()
    assert.length(open, 1, 'exactly one float open')
    local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(open[1]), 0, -1, false)
    assert.equals(lines[1], '[ISSUE] Test comment', 'float shows the moved comment')
    -- A real cursor move still closes it
    vim.fn.cursor(1, 1)
    vim.api.nvim_exec_autocmds('CursorMoved', {})
    assert.length(floats(), 0, 'float closed by a real move')
  end)
  pcall(reset_nav)
  pcall(vim.cmd, 'bwipeout! ' .. vim.fn.fnameescape(path))
  os.remove(path)
  qf.clear_review()
  if not ok then error(err, 0) end
end)

-- Another Neovim adds a comment on line 5 of `path` (listed after the rest)
local function append_external(path)
  local log_path = test_helper.segment_path(1)
  local c = vim.deepcopy(test_helper.saved(log_path)[2])
  c.id = c.id .. '-external'
  c.text = 'External comment'
  c.lnum, c.end_lnum = 5, 5
  if c.anchor then c.anchor.lnum, c.anchor.end_lnum = 5, 5 end
  local log = require('quickfix-review.log')
  assert.truthy(log.append(log_path, { log.event('add', { comment = c }) }), 'appended')
  return c.id
end

local function listed(id)
  for _, item in ipairs(vim.fn.getqflist()) do
    if type(item.user_data) == 'table' and item.user_data.id == id then return true end
  end
  return false
end

-- :cnext into `path` (wiped and shifted on disk when `wipe`, else loaded
-- and hidden) after another Neovim appended to the log: the sync the read or
-- enter runs picks the append up, and refills the list after the jump
local function cnext_after_external_append(wipe)
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
    if wipe then
      vim.cmd('bwipeout! ' .. buf)
      -- Two lines inserted above the comment while the file is not loaded
      vim.fn.writefile({ 'x', 'y', 'a', 'b', 'c', 'd', 'e' }, path)
    else
      assert.truthy(vim.api.nvim_buf_is_loaded(buf), 'target still loaded')
    end
    qf.show_list()
    navigate('cc 1')
    local id = append_external(path)
    local jumped, jump_err = pcall(navigate, 'cnext')
    assert.truthy(jumped, 'cnext succeeded: ' .. tostring(jump_err))
    vim.wait(100, function() return listed(id) end)
    assert.equals(selected(), 2, 'on the second entry')
    assert.equals(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ':p'),
      vim.fn.fnamemodify(path, ':p'), 'in the target file')
    assert.equals(vim.fn.line('.'), wipe and 6 or 4, 'on the entry')
    local found = false
    for _, c in ipairs(qf.comments()) do
      if c.id == id then found = true end
    end
    assert.truthy(found, 'external comment read')
    assert.truthy(listed(id), 'external comment listed')
  end)
  pcall(reset_nav)
  pcall(vim.cmd, 'bwipeout! ' .. vim.fn.fnameescape(path))
  os.remove(path)
  qf.clear_review()
  if not ok then error(err, 0) end
end

assert.run_test('cnext into a file read after another Neovim logged: no E925', function()
  cnext_after_external_append(true)
end)

assert.run_test('cnext into a hidden file after another Neovim logged: no E925', function()
  cnext_after_external_append(false)
end)

-- 'autochdir' changes the directory during a quickfix jump into a file in
-- another directory (headless Neovim can't turn it on: simulated by firing
-- DirChanged 'auto' mid-jump). The sync it runs picks up another Neovim's
-- append; refilling the list then would abort the jump with E925.
assert.run_test('cnext with autochdir after another Neovim logged: no E925', function()
  local path = vim.fn.tempname() .. '-other-dir.txt'
  vim.fn.writefile({ 'a', 'b', 'c', 'd', 'e' }, path)
  local group = vim.api.nvim_create_augroup('QuickfixReviewTestAutochdir', { clear = true })
  local ok, err = pcall(function()
    qf.clear_review()
    vim.cmd('only')
    vim.fn.cursor(1, 1)
    qf.add_comment('NOTE')
    local home = vim.api.nvim_get_current_buf()
    vim.cmd('edit ' .. vim.fn.fnameescape(path))
    vim.fn.cursor(4, 1)
    qf.add_comment('ISSUE')
    vim.api.nvim_set_current_buf(home)
    qf.show_list()
    navigate('cc 1')
    local id = append_external(path)
    vim.api.nvim_create_autocmd('BufLeave', {
      group = group,
      once = true,
      callback = function() vim.api.nvim_exec_autocmds('DirChanged', { pattern = 'auto' }) end,
    })
    local jumped, jump_err = pcall(navigate, 'cnext')
    assert.truthy(jumped, 'cnext succeeded: ' .. tostring(jump_err))
    assert.equals(selected(), 2, 'on the second entry')
    assert.equals(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ':p'),
      vim.fn.fnamemodify(path, ':p'), 'in the other file')
    vim.wait(100, function() return listed(id) end)
    assert.truthy(listed(id), 'external comment listed after the jump')
  end)
  pcall(vim.api.nvim_del_augroup_by_id, group)
  pcall(reset_nav)
  pcall(vim.cmd, 'bwipeout! ' .. vim.fn.fnameescape(path))
  os.remove(path)
  qf.clear_review()
  if not ok then error(err, 0) end
end)

-- A plugin running :cd from the jump's BufEnter (vim-rooter and the like)
-- fires DirChanged 'global' mid-jump. Simulated: another Neovim logs a
-- comment, then DirChanged 'global' fires, from BufEnter of the jump's
-- target; refilling the list then would abort the jump with E925.
assert.run_test('cnext with a :cd from BufEnter after another Neovim logged: no E925', function()
  local path = vim.fn.tempname() .. '-rooter.txt'
  vim.fn.writefile({ 'a', 'b', 'c', 'd', 'e' }, path)
  local group = vim.api.nvim_create_augroup('QuickfixReviewTestRooter', { clear = true })
  local ok, err = pcall(function()
    qf.clear_review()
    vim.cmd('only')
    vim.fn.cursor(1, 1)
    qf.add_comment('NOTE')
    local home = vim.api.nvim_get_current_buf()
    vim.cmd('edit ' .. vim.fn.fnameescape(path))
    local target = vim.api.nvim_get_current_buf()
    vim.fn.cursor(4, 1)
    qf.add_comment('ISSUE')
    vim.api.nvim_set_current_buf(home)
    qf.show_list()
    navigate('cc 1')
    local id
    vim.api.nvim_create_autocmd('BufEnter', {
      group = group,
      buffer = target,
      once = true,
      callback = function()
        id = append_external(path)
        vim.api.nvim_exec_autocmds('DirChanged', { pattern = 'global' })
      end,
    })
    local jumped, jump_err = pcall(navigate, 'cnext')
    assert.truthy(jumped, 'cnext succeeded: ' .. tostring(jump_err))
    assert.equals(selected(), 2, 'on the second entry')
    assert.equals(vim.api.nvim_get_current_buf(), target, 'in the other file')
    assert.truthy(id, 'the BufEnter hook ran')
    vim.wait(100, function() return listed(id) end)
    assert.truthy(listed(id), 'external comment listed after the jump')
  end)
  pcall(vim.api.nvim_del_augroup_by_id, group)
  pcall(reset_nav)
  pcall(vim.cmd, 'bwipeout! ' .. vim.fn.fnameescape(path))
  os.remove(path)
  qf.clear_review()
  if not ok then error(err, 0) end
end)

-- With 'autowrite' and 'nohidden', :cnext out of a modified buffer writes it
-- mid-jump: the anchors are written back, and the list refilled after
assert.run_test('cnext with autowrite out of a modified buffer: no E925, anchors written', function()
  local path = vim.fn.tempname() .. '-other.txt'
  vim.fn.writefile({ 'a', 'b', 'c', 'd', 'e' }, path)
  local home_path = vim.fn.tempname() .. '-home.txt'
  vim.fn.writefile({ 'one', 'two', 'three' }, home_path)
  local autowrite, hidden = vim.o.autowrite, vim.o.hidden
  local home
  local ok, err = pcall(function()
    qf.clear_review()
    vim.cmd('only')
    vim.cmd('edit ' .. vim.fn.fnameescape(home_path))
    home = vim.api.nvim_get_current_buf()
    vim.fn.cursor(2, 1)
    qf.add_comment('NOTE')
    vim.cmd('edit ' .. vim.fn.fnameescape(path))
    vim.fn.cursor(4, 1)
    qf.add_comment('ISSUE')
    vim.api.nvim_set_current_buf(home)
    qf.show_list()
    navigate('cc 1')
    assert.equals(vim.api.nvim_get_current_buf(), home, 'in the home file')
    local before = #test_helper.log_ops(test_helper.events_path(), 'update')
    vim.api.nvim_buf_set_lines(home, 0, 0, false, { 'zero' })
    vim.o.autowrite, vim.o.hidden = true, false
    local jumped, jump_err = pcall(navigate, 'cnext')
    assert.truthy(jumped, 'cnext succeeded: ' .. tostring(jump_err))
    assert.equals(selected(), 2, 'on the second entry')
    assert.equals(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ':p'),
      vim.fn.fnamemodify(path, ':p'), 'in the other file')
    assert.falsy(vim.api.nvim_buf_is_loaded(home) and vim.bo[home].modified, 'home file written')
    local updates = test_helper.log_ops(test_helper.events_path(), 'update')
    assert.equals(#updates, before + 1, 'one anchor update logged')
    assert.equals(updates[#updates].set.anchor.lnum, 3, 'anchor shifted by the inserted line')
    vim.wait(100, function() return vim.fn.getqflist()[1].lnum == 3 end)
    assert.equals(vim.fn.getqflist()[1].lnum, 3, 'entry 1 refilled at its new line')
  end)
  vim.o.autowrite, vim.o.hidden = autowrite, hidden
  pcall(reset_nav)
  pcall(vim.cmd, 'bwipeout! ' .. vim.fn.fnameescape(path))
  pcall(vim.cmd, 'bwipeout! ' .. vim.fn.fnameescape(home_path))
  os.remove(path)
  os.remove(home_path)
  qf.clear_review()
  if not ok then error(err, 0) end
end)

-- Another Neovim appends after the jump's source was selected, and the
-- target file shifted on disk: the read's sync redraws the signs (placing
-- the marks) before relocation, which then finds nothing to move. The jump
-- still lands on the relocated line, and shows its float.
assert.run_test('cnext into a shifted file after another Neovim logged: relocated line', function()
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
    navigate('cc 1')
    -- Two lines inserted above the comment while the file is not loaded
    vim.fn.writefile({ 'x', 'y', 'a', 'b', 'c', 'd', 'e' }, path)
    local id = append_external(path)
    local jumped, jump_err = pcall(navigate, 'cnext')
    assert.truthy(jumped, 'cnext succeeded: ' .. tostring(jump_err))
    -- The CursorMoved caused by the finish's own cursor move
    settle_jump()
    assert.equals(selected(), 2, 'on the second entry')
    assert.equals(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ':p'),
      vim.fn.fnamemodify(path, ':p'), 'in the moved file')
    assert.equals(vim.fn.line('.'), 6, 'on the relocated line')
    local open = floats()
    assert.length(open, 1, 'exactly one float open')
    local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(open[1]), 0, -1, false)
    assert.equals(lines[1], '[ISSUE] Test comment', 'float shows the moved comment')
    vim.wait(100, function() return listed(id) end)
    assert.truthy(listed(id), 'external comment listed')
    local entry = vim.fn.getqflist()[2]
    assert.equals(entry.lnum, 6, 'entry refilled at the relocated line')
    vim.fn.cursor(1, 1)
    vim.api.nvim_exec_autocmds('CursorMoved', {})
    assert.length(floats(), 0, 'float closed by a real move')
  end)
  pcall(reset_nav)
  pcall(vim.cmd, 'bwipeout! ' .. vim.fn.fnameescape(path))
  os.remove(path)
  qf.clear_review()
  if not ok then error(err, 0) end
end)

-- Jump to the entry already selected (entry 2, in a file wiped and then
-- shifted on disk) with `jump`: no E925, and the cursor on the relocated line
local function jump_to_current_into_moved_file(jump)
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
    qf.show_list()
    navigate('cc 2')
    assert.equals(selected(), 2, 'entry 2 selected')
    vim.api.nvim_set_current_buf(home)
    vim.api.nvim_exec_autocmds('CursorMoved', {})
    vim.wait(50, function() return false end)
    assert.length(floats(), 0, 'float closed')
    vim.cmd('bwipeout! ' .. buf)
    -- Refill, so the entry names the file again rather than the wiped buffer
    qf.show_list()
    assert.equals(selected(), 2, 'entry 2 still selected')
    -- Two lines inserted above the comment while the file is not loaded
    vim.fn.writefile({ 'x', 'y', 'a', 'b', 'c', 'd', 'e' }, path)
    local jumped, jump_err = pcall(jump)
    assert.truthy(jumped, 'jump succeeded: ' .. tostring(jump_err))
    vim.wait(100, function() return false end)
    assert.equals(selected(), 2, 'still on entry 2')
    assert.equals(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ':p'),
      vim.fn.fnamemodify(path, ':p'), 'in the moved file')
    assert.equals(vim.fn.line('.'), 6, 'on the relocated line')
  end)
  pcall(reset_nav)
  pcall(vim.cmd, 'bwipeout! ' .. vim.fn.fnameescape(path))
  os.remove(path)
  qf.clear_review()
  if not ok then error(err, 0) end
end

assert.run_test('<CR> on the current entry into a file whose comment relocates on read', function()
  jump_to_current_into_moved_file(function()
    qf.open_list()
    assert.equals(vim.bo.buftype, 'quickfix', 'in the list window')
    assert.equals(vim.fn.line('.'), 2, 'on the current row')
    navigate('execute "normal \\<CR>"')
  end)
end)

assert.run_test(':cc N to the current N into a file whose comment relocates on read', function()
  jump_to_current_into_moved_file(function() navigate('cc 2') end)
end)

-- ]r into a file (wiped, then shifted on disk) holding the selected review
-- list entry is the plugin's own navigation, not a quickfix jump to that
-- entry: it lands on the comment it was heading for, with its float
assert.run_test('jump_comment into a shifted file holding the selected entry', function()
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
    vim.fn.cursor(1, 1)
    qf.add_comment('ISSUE')
    vim.fn.cursor(3, 1)
    qf.add_comment('SUGGESTION')
    vim.api.nvim_set_current_buf(home)
    qf.show_list()
    navigate('cc 3')
    local idx, item = selected()
    assert.equals(idx, 3, 'entry 3 selected')
    assert.equals(item.bufnr, buf, 'entry 3 is in the other file')
    vim.api.nvim_set_current_buf(home)
    vim.api.nvim_exec_autocmds('CursorMoved', {})
    vim.wait(50, function() return false end)
    assert.length(floats(), 0, 'float closed')
    vim.cmd('bwipeout! ' .. buf)
    -- Refill, so the entries name the file again rather than the wiped buffer
    qf.show_list()
    assert.equals(selected(), 3, 'entry 3 still selected')
    -- Two lines inserted at the top while the file is not loaded: the next
    -- comment is now on line 3, the selected entry's (stale) line
    vim.fn.writefile({ 'x', 'y', 'a', 'b', 'c', 'd', 'e' }, path)
    vim.fn.cursor(1, 1)
    qf.jump_comment(1)
    vim.api.nvim_exec_autocmds('CursorMoved', {})
    vim.wait(100, function() return #floats() > 0 end)
    vim.wait(50, function() return false end)
    assert.equals(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ':p'),
      vim.fn.fnamemodify(path, ':p'), 'in the moved file')
    assert.equals(vim.fn.line('.'), 3, 'on the next comment, relocated')
    local open = floats()
    assert.length(open, 1, 'exactly one float open')
    local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(open[1]), 0, -1, false)
    assert.equals(lines[1], '[ISSUE] Test comment', 'float shows the next comment')
    assert.equals(selected(), 3, 'selection unchanged')
  end)
  pcall(reset_nav)
  pcall(vim.cmd, 'bwipeout! ' .. vim.fn.fnameescape(path))
  os.remove(path)
  qf.clear_review()
  if not ok then error(err, 0) end
end)

-- Transitions of the jump state machine (see the table in jump.lua)
local jump = require('quickfix-review.jump')

-- Run `body(path)` with a review of two comments: line 1 of the test
-- file, and line 4 of another file (wiped, then shifted two lines down on
-- disk), entry 1 selected and seen. A cnext then relocates on read.
local function with_relocating_jump(body)
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
    vim.fn.writefile({ 'x', 'y', 'a', 'b', 'c', 'd', 'e' }, path)
    navigate('cc 1')
    assert.equals(jump.state(), 'idle', 'idle before the jump')
    body(path)
  end)
  pcall(reset_nav)
  pcall(vim.cmd, 'bwipeout! ' .. vim.fn.fnameescape(path))
  os.remove(path)
  qf.clear_review()
  if not ok then error(err, 0) end
end

assert.run_test('jump: held float closes on a CursorMoved elsewhere', function()
  with_relocating_jump(function()
    navigate('cnext')
    vim.wait(50, function() return false end)
    assert.equals(jump.state(), 'idle', 'idle after finish')
    assert.equals(vim.fn.line('.'), 6, 'on the relocated line')
    assert.length(floats(), 1, 'float open, held')
    -- The first CursorMoved lands somewhere other than the hold
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.api.nvim_exec_autocmds('CursorMoved', {})
    assert.length(floats(), 0, 'float closed')
  end)
end)

assert.run_test('jump: held float closes on BufLeave', function()
  with_relocating_jump(function()
    navigate('cnext')
    vim.wait(50, function() return false end)
    assert.length(floats(), 1, 'float open, held')
    vim.api.nvim_exec_autocmds('BufLeave', {})
    assert.length(floats(), 0, 'float closed')
  end)
end)

assert.run_test('jump: cursor check while finishing is ignored', function()
  with_relocating_jump(function()
    vim.cmd('cnext')
    assert.equals(jump.state(), 'finishing', 'finish scheduled by the relocated read')
    assert.equals(vim.fn.line('.'), 4, 'still on the old line')
    -- A check now would take the old line for the entry and show a float
    jump.on_event('cursor')
    assert.length(floats(), 0, 'no float while finishing')
    assert.equals(jump.state(), 'finishing', 'still finishing')
    vim.api.nvim_exec_autocmds('CursorMoved', {})
    vim.wait(100, function() return #floats() > 0 end)
    settle_jump()
    assert.equals(jump.state(), 'idle', 'idle after finish')
    assert.equals(vim.fn.line('.'), 6, 'on the relocated line')
    local open = floats()
    assert.length(open, 1, 'exactly one float after finish')
    local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(open[1]), 0, -1, false)
    assert.equals(lines[1], '[ISSUE] Test comment', 'float shows the moved comment')
  end)
end)

-- A second relocated read while finishing supersedes the first finish: the
-- state stays finishing until the latest finish runs
assert.run_test('jump: second relocation while finishing stays finishing', function()
  with_relocating_jump(function(path)
    local relocations = 0
    local on_event = jump.on_event
    jump.on_event = function(name, args)
      if name == 'relocated' then relocations = relocations + 1 end
      return on_event(name, args)
    end
    local ok, err = pcall(function()
      vim.cmd('cnext')
      assert.equals(jump.state(), 'finishing', 'finish scheduled by the first read')
      assert.equals(relocations, 1, 'first read relocated')
      -- Runs after the first finish, before the second
      local probe
      vim.schedule(function() probe = jump.state() end)
      -- One more line inserted at the top: the comment moves again
      vim.fn.writefile({ 'z', 'x', 'y', 'a', 'b', 'c', 'd', 'e' }, path)
      vim.cmd('edit!')
      assert.equals(relocations, 2, 'second read relocated')
      assert.equals(jump.state(), 'finishing', 'still finishing after the second read')
      settle_jump()
      assert.equals(probe, 'finishing', 'still finishing between the two finishes')
      assert.equals(jump.state(), 'idle', 'idle after the last finish')
      assert.equals(vim.fn.line('.'), 7, 'on the relocated line')
      assert.length(floats(), 1, 'exactly one float')
    end)
    jump.on_event = on_event
    if not ok then error(err, 0) end
  end)
end)

assert.run_test('jump: jump_comment float skipped when the cursor moved first', function()
  add_two_comments()
  vim.fn.cursor(1, 1)
  qf.jump_comment(1)
  assert.equals(vim.fn.line('.'), 3, 'on the next comment')
  -- Moved before the scheduled view runs
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  vim.wait(100, function() return #floats() > 0 end)
  assert.length(floats(), 0, 'no float')
  reset_nav()
  qf.clear_review()
end)

assert.run_test('jump: own_jump bracket restores the prior state', function()
  assert.equals(jump.state(), 'idle', 'idle')
  jump.on_event('own_edit_begin')
  assert.equals(jump.state(), 'own_jump', 'own_jump inside the bracket')
  jump.on_event('own_edit_end')
  assert.equals(jump.state(), 'idle', 'back to idle')
end)

assert.run_test('jump: own_jump bracket restores the prior state (finishing)', function()
  with_relocating_jump(function()
    vim.cmd('cnext')
    local buf = vim.api.nvim_get_current_buf()
    assert.equals(jump.state(), 'finishing', 'finishing')
    jump.on_event('own_edit_begin')
    assert.equals(jump.state(), 'own_jump', 'own_jump inside the bracket')
    assert.truthy(jump.in_jump(buf), 'still in a jump: the finish is pending')
    jump.on_event('cursor')
    assert.length(floats(), 0, 'cursor check still ignored')
    jump.on_event('own_edit_end')
    assert.equals(jump.state(), 'finishing', 'finishing restored')
    vim.api.nvim_exec_autocmds('CursorMoved', {})
    vim.wait(100, function() return #floats() > 0 end)
    settle_jump()
    assert.equals(jump.state(), 'idle', 'idle after finish')
    assert.equals(vim.fn.line('.'), 6, 'finish moved to the relocated line')
    assert.length(floats(), 1, 'float after finish')
  end)
end)

assert.run_test('jump: in_jump while finishing', function()
  with_relocating_jump(function()
    vim.cmd('cnext')
    local buf = vim.api.nvim_get_current_buf()
    assert.equals(jump.state(), 'finishing', 'finishing')
    -- The selection seen: only the finishing branch remains
    jump.on_event('seen', vim.fn.getqflist({ id = 0, idx = 0 }))
    assert.equals(jump.pending(buf, false), nil, 'no pending jump')
    assert.truthy(jump.in_jump(buf), 'in a jump while finishing')
    vim.wait(100, function() return jump.state() == 'idle' end)
    assert.equals(jump.state(), 'idle', 'idle after finish')
    assert.falsy(jump.in_jump(buf), 'no longer in a jump')
  end)
end)

assert.run_test('jump: in_jump while pending', function()
  add_two_comments()
  qf.show_list()
  navigate('cc 1')
  -- Selection changed, not yet seen by the cursor check
  vim.cmd('cnext')
  local buf = vim.api.nvim_get_current_buf()
  assert.equals(jump.state(), 'idle', 'not finishing')
  assert.truthy(jump.pending(buf, false), 'pending jump into this buffer')
  assert.truthy(jump.in_jump(buf), 'in a jump while pending')
  jump.on_event('cursor')
  assert.falsy(jump.in_jump(buf), 'no longer in a jump once seen')
  reset_nav()
  qf.clear_review()
end)

-- The own_jump guard sits at relocate_buffer's call only: in_jump still sees
-- a pending entry inside ]r's :edit, so a DirChanged there defers its refill
assert.run_test('jump: in_jump while pending, inside the own_jump bracket', function()
  add_two_comments()
  qf.show_list()
  navigate('cc 1')
  -- Selection changed, not yet seen by the cursor check
  vim.cmd('cnext')
  local buf = vim.api.nvim_get_current_buf()
  local ok, err = pcall(function()
    jump.on_event('own_edit_begin')
    assert.equals(jump.state(), 'own_jump', 'own_jump inside the bracket')
    assert.truthy(jump.pending(buf, false), 'pending entry inside the bracket')
    assert.truthy(jump.in_jump(buf), 'in a jump inside the bracket')
  end)
  jump.on_event('own_edit_end')
  reset_nav()
  qf.clear_review()
  if not ok then error(err, 0) end
end)

-- A :cd from BufEnter (vim-rooter and the like) during ]r's own :edit into
-- the file holding a selected entry the cursor check hasn't seen: the sync
-- DirChanged runs defers its refill, as it would for a quickfix jump
assert.run_test('jump_comment with a :cd from BufEnter and a stale selection defers the refill', function()
  local path = vim.fn.tempname() .. '-rooter.txt'
  vim.fn.writefile({ 'a', 'b', 'c', 'd', 'e' }, path)
  local group = vim.api.nvim_create_augroup('QuickfixReviewTestOwnRooter', { clear = true })
  local ok, err = pcall(function()
    qf.clear_review()
    vim.cmd('only')
    vim.fn.cursor(1, 1)
    qf.add_comment('NOTE')
    local home = vim.api.nvim_get_current_buf()
    vim.cmd('edit ' .. vim.fn.fnameescape(path))
    local target = vim.api.nvim_get_current_buf()
    vim.fn.cursor(4, 1)
    qf.add_comment('ISSUE')
    vim.api.nvim_set_current_buf(home)
    qf.show_list()
    navigate('cc 1')
    -- Entry 2 selected without the cursor check seeing it
    vim.fn.setqflist({}, 'a', { idx = 2 })
    local idx, item = selected()
    assert.equals(idx, 2, 'entry 2 selected')
    assert.equals(item.bufnr, target, 'entry 2 is in the target file')
    local id, listed_during
    vim.api.nvim_create_autocmd('BufEnter', {
      group = group,
      buffer = target,
      once = true,
      callback = function()
        id = append_external(path)
        vim.api.nvim_exec_autocmds('DirChanged', { pattern = 'global' })
        listed_during = listed(id)
      end,
    })
    vim.api.nvim_set_current_buf(home)
    vim.fn.cursor(1, 1)
    qf.jump_comment(1)
    assert.equals(vim.api.nvim_get_current_buf(), target, 'in the target file')
    assert.truthy(id, 'the BufEnter hook ran')
    assert.falsy(listed_during, 'list not refilled during the edit')
    vim.wait(100, function() return listed(id) end)
    assert.truthy(listed(id), 'external comment listed after the edit')
  end)
  pcall(vim.api.nvim_del_augroup_by_id, group)
  pcall(reset_nav)
  pcall(vim.cmd, 'bwipeout! ' .. vim.fn.fnameescape(path))
  os.remove(path)
  qf.clear_review()
  if not ok then error(err, 0) end
end)

qf.clear_review()
test_helper.cleanup_test_environment()

return assert
