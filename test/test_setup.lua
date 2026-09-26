-- Tests that setup() can be called more than once without duplicating autocmds
local test_helper = dofile('test/init.lua')
local assert = dofile('test/assertions.lua')

print('\nRunning setup tests...')

-- Plugin autocmds that are not in any group
local function ungrouped(event)
  local found = {}
  for _, au in ipairs(vim.api.nvim_get_autocmds({ event = event })) do
    if au.group == nil then table.insert(found, au) end
  end
  return found
end

local qf = test_helper.setup_test_environment()
test_helper.create_test_file('line 1\nline 2\nline 3\n')

assert.run_test('setup() twice keeps the same QuickfixReview autocmds', function()
  local once = #vim.api.nvim_get_autocmds({ group = 'QuickfixReview' })
  assert.truthy(once > 0, 'setup registers autocmds in QuickfixReview')

  test_helper.setup_test_environment()
  local twice = #vim.api.nvim_get_autocmds({ group = 'QuickfixReview' })
  assert.equals(twice, once, 'autocmd count after second setup')
end)

assert.run_test('setup() leaves no ungrouped plugin autocmds', function()
  for _, event in ipairs({ 'BufEnter', 'QuickFixCmdPost', 'FileChangedShellPost', 'FileType' }) do
    assert.length(ungrouped(event), 0, 'ungrouped ' .. event .. ' handlers')
  end
end)

assert.run_test('view_comment float close autocmd is grouped and removed on close', function()
  qf.clear_review()
  vim.fn.cursor(2, 1)
  qf.add_comment('NOTE')
  qf.view_comment()

  local float = #vim.api.nvim_get_autocmds({ group = 'QuickfixReviewFloat' })
  assert.equals(float, 2, 'CursorMoved and BufLeave close handlers')
  assert.length(ungrouped('CursorMoved'), 0, 'ungrouped CursorMoved handlers')

  vim.api.nvim_exec_autocmds('CursorMoved', {})
  assert.equals(#vim.api.nvim_get_autocmds({ group = 'QuickfixReviewFloat' }), 0,
    'float handlers removed after close')
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    assert.equals(vim.api.nvim_win_get_config(win).relative, '', 'no floating window left open')
  end
  qf.clear_review()
end)

test_helper.cleanup_test_environment()

return assert
