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

qf.clear_review()
test_helper.cleanup_test_environment()

return assert
