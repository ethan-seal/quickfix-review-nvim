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

assert.run_test('FileChangedShellPost checks the changed buffer, not the current one', function()
  local changed_buf = vim.api.nvim_get_current_buf()
  local other = vim.fn.tempname() .. '-other.txt'
  vim.fn.writefile({ 'other' }, other)
  local original_confirm = vim.fn.confirm
  local ok, err = pcall(function()
    qf.setup({ storage_file = test_helper.storage_file, prompt_on_file_change = true })
    qf.clear_review()
    vim.fn.cursor(2, 1)
    qf.add_comment('NOTE')
    assert.length(qf.comments(), 1, 'comment in the changed file')

    vim.cmd('edit ' .. vim.fn.fnameescape(other))
    local asked = 0
    vim.fn.confirm = function() asked = asked + 1 return 1 end
    vim.api.nvim_exec_autocmds('FileChangedShellPost', { buffer = changed_buf })
    assert.equals(asked, 1, 'asked about the changed file')
    assert.length(qf.comments(), 0, 'its comments cleared')
  end)
  vim.fn.confirm = original_confirm
  vim.api.nvim_set_current_buf(changed_buf)
  pcall(vim.cmd, 'bwipeout! ' .. vim.fn.fnameescape(other))
  os.remove(other)
  test_helper.setup_test_environment()
  if not ok then error(err, 0) end
end)

assert.run_test('commands work before setup()', function()
  local saved_modules = {}
  for name, mod in pairs(package.loaded) do
    if name:match('^quickfix%-review') then
      saved_modules[name] = mod
      package.loaded[name] = nil
    end
  end
  local storage_file = vim.fn.tempname() .. '-before-setup.json'
  local original_setreg = vim.fn.setreg
  local clipboard
  local ok, err = pcall(function()
    -- Never touch the real review in stdpath('data')
    require('quickfix-review.config').options.storage_file = storage_file
    require('quickfix-review.store').add({
      filename = vim.fn.fnamemodify('test_file.txt', ':p'), lnum = 1, kind = 'question', body = 'before setup',
    })
    vim.fn.setreg = function(_, value) clipboard = value end
    vim.g.loaded_quickfix_review = nil
    vim.cmd('runtime plugin/quickfix-review.lua')

    local sok, serr = pcall(vim.cmd, 'ReviewSummary')
    assert.truthy(sok, ':ReviewSummary does not error: ' .. tostring(serr))
    local eok, eerr = pcall(vim.cmd, 'ReviewExport')
    assert.truthy(eok, ':ReviewExport does not error: ' .. tostring(eerr))
    assert.truthy(clipboard and clipboard:find('Comment types: ISSUE', 1, true), 'export has the default legend')
    assert.truthy(clipboard:find('**[QUESTION]**', 1, true), 'export has the comment')
  end)
  vim.fn.setreg = original_setreg
  os.remove(storage_file)
  for name, _ in pairs(package.loaded) do
    if name:match('^quickfix%-review') then package.loaded[name] = nil end
  end
  for name, mod in pairs(saved_modules) do package.loaded[name] = mod end
  if not ok then error(err, 0) end
end)

test_helper.cleanup_test_environment()

return assert
