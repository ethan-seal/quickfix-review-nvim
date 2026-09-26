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

assert.run_test('dd deletes by id after the file is reordered on disk', function()
  add_two_comments()
  qf.open_list()
  -- Row 1 (not 2): re-rendering the view moves the cursor back to row 1,
  -- so only row 1 exposes a positional lookup
  vim.fn.cursor(1, 1) -- the line 1 comment

  local storage_file = test_helper.storage_file
  local doc = vim.json.decode(table.concat(vim.fn.readfile(storage_file), '\n'),
    { luanil = { object = true, array = true } })
  local list = doc.comments
  vim.uv.sleep(10) -- so the rewrite gets a new mtime
  vim.fn.writefile({ vim.json.encode({ version = 2, comments = { list[2], list[1] } }) }, storage_file)

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
  assert.truthy(md and md:find('```diff', 1, true), 'export still emits the snippet')
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
  local storage_file = test_helper.storage_file
  vim.uv.sleep(10) -- so the rewrite gets a new mtime
  vim.fn.writefile({ 'not json' }, storage_file)

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
    if c.level == vim.log.levels.WARN and c.msg:find('unreadable', 1, true) then warned = true end
  end
  assert.truthy(warned, 'warns that the storage file is unreadable')
  for _, line in ipairs(printed) do
    assert.falsy(line:find('no longer exists', 1, true), 'does not claim the comment is gone')
  end
  assert.equals(vim.fn.readfile(storage_file)[1], 'not json', 'file untouched')

  os.remove(storage_file)
  close_lists()
end)

qf.clear_review()
test_helper.cleanup_test_environment()

return assert
