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
  for _, event in ipairs({ 'BufEnter', 'CursorMoved', 'FileChangedShellPost', 'FileType', 'DirChanged', 'BufWritePost' }) do
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

-- The floating windows currently open
local function floats()
  local found = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(win).relative ~= '' then table.insert(found, win) end
  end
  return found
end

-- The lines of the one float open now (fails if there is not exactly one)
local function only_float_lines()
  local open = floats()
  assert.length(open, 1, 'floating windows open')
  return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(open[1]), 0, -1, false)
end

assert.run_test('jump_comment leaves the float open', function()
  qf.clear_review()
  vim.fn.cursor(2, 1)
  qf.add_comment('NOTE')
  vim.fn.cursor(1, 1)
  qf.jump_comment(1)
  -- Stands in for the CursorMoved the main loop dispatches after the jump
  vim.api.nvim_exec_autocmds('CursorMoved', {})
  vim.wait(100, function() return #floats() > 0 end)
  assert.equals(vim.fn.line('.'), 2, 'jumped to the comment')
  local lines = only_float_lines()
  assert.equals(lines[1], '[NOTE] Test comment', 'float shows the comment')
  vim.api.nvim_exec_autocmds('CursorMoved', {})
  assert.length(floats(), 0, 'float closed by the next move')
  qf.clear_review()
end)

assert.run_test('three consecutive views leave no buffers, floats or handlers behind', function()
  qf.clear_review()
  vim.fn.cursor(2, 1)
  qf.add_comment('NOTE')
  local bufs = #vim.api.nvim_list_bufs()

  for _ = 1, 3 do qf.view_comment() end
  assert.length(floats(), 1, 'one float open after three views')
  assert.equals(#vim.api.nvim_get_autocmds({ group = 'QuickfixReviewFloat' }), 2,
    'one float close handler (two events)')

  vim.api.nvim_exec_autocmds('CursorMoved', {})
  assert.length(floats(), 0, 'no float left after closing')
  assert.equals(#vim.api.nvim_list_bufs(), bufs, 'buffer count back to baseline')
  assert.equals(#vim.api.nvim_get_autocmds({ group = 'QuickfixReviewFloat' }), 0,
    'float handlers removed after close')
  qf.clear_review()
end)

assert.run_test('view_comment on the middle line of a range comment opens its float', function()
  qf.clear_review()
  qf.add_comment('ISSUE', { 1, 3 })
  vim.fn.cursor(2, 1)
  qf.view_comment()
  local lines = only_float_lines()
  assert.equals(lines[1], '[ISSUE:L1-3] Test comment', 'float shows the range comment')
  vim.api.nvim_exec_autocmds('CursorMoved', {})
  qf.clear_review()
end)

assert.run_test('overlapping comments are shown together in one float, in line order', function()
  qf.clear_review()
  qf.add_comment('NOTE', { 2, 3 })
  qf.add_comment('ISSUE', { 1, 2 })
  vim.fn.cursor(2, 1)
  qf.view_comment()
  local lines = only_float_lines()
  assert.equals(table.concat(lines, '\n'),
    '[ISSUE:L1-2] Test comment\n\n[NOTE:L2-3] Test comment', 'both comments, lnum order')
  vim.api.nvim_exec_autocmds('CursorMoved', {})
  qf.clear_review()
end)

assert.run_test('FileChangedShellPost relocates the changed buffer and never offers to clear', function()
  local changed_buf = vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(changed_buf)
  local other = vim.fn.tempname() .. '-other.txt'
  vim.fn.writefile({ 'other' }, other)
  local original_confirm = vim.fn.confirm
  local original_notify = vim.notify
  local ok, err = pcall(function()
    local notes = {}
    vim.notify = function(msg, level) table.insert(notes, { msg = msg, level = level }) end
    qf.setup({ storage_file = test_helper.storage_file, prompt_on_file_change = true })
    qf.setup({ storage_file = test_helper.storage_file, prompt_on_file_change = true })
    vim.notify = original_notify
    local deprecations = 0
    for _, n in ipairs(notes) do
      if n.msg:find('prompt_on_file_change is deprecated', 1, true) then deprecations = deprecations + 1 end
    end
    assert.equals(deprecations, 1, 'deprecation notice shown once across two setup() calls')

    qf.clear_review()
    vim.fn.cursor(2, 1)
    qf.add_comment('NOTE')
    assert.length(qf.comments(), 1, 'comment in the changed file')

    -- Two lines added above it on disk, reloaded
    vim.fn.writefile({ 'new a', 'new b', 'line 1', 'line 2', 'line 3' }, path)
    vim.api.nvim_buf_call(changed_buf, function() vim.cmd('silent edit!') end)

    vim.cmd('edit ' .. vim.fn.fnameescape(other))
    local asked = 0
    vim.fn.confirm = function() asked = asked + 1 return 1 end
    vim.api.nvim_exec_autocmds('FileChangedShellPost', { buffer = changed_buf })
    assert.equals(asked, 0, 'never asked to clear comments')
    local list = qf.comments()
    assert.length(list, 1, 'the comment is kept')
    local lnum = require('quickfix-review.store').range(list[1])
    assert.equals(lnum, 4, 'the comment followed its line')
  end)
  vim.notify = original_notify
  vim.fn.confirm = original_confirm
  vim.api.nvim_set_current_buf(changed_buf)
  pcall(vim.cmd, 'bwipeout! ' .. vim.fn.fnameescape(other))
  os.remove(other)
  vim.fn.writefile({ 'line 1', 'line 2', 'line 3' }, path)
  vim.cmd('silent edit!')
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
    for _, cmd in ipairs({ 'ReviewTrash', 'ReviewHistory', 'ReviewReanchor' }) do
      local cok, cerr = pcall(vim.cmd, cmd)
      assert.truthy(cok, ':' .. cmd .. ' does not error: ' .. tostring(cerr))
    end
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
