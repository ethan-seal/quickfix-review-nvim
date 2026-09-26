-- Tests for configuration: comment_types validation, the export legend and
-- the order comment types are listed in
local test_helper = dofile('test/init.lua')
local assert = dofile('test/assertions.lua')
local config = require('quickfix-review.config')
local utils = require('quickfix-review.utils')

print('\nRunning config tests...')

test_helper.setup_test_environment()

-- Run fn with vim.notify replaced by a recorder; returns the recorded calls
local function capture_notify(fn)
  local calls = {}
  local original = vim.notify
  vim.notify = function(msg, level) table.insert(calls, { msg = msg, level = level }) end
  local ok, err = pcall(fn)
  vim.notify = original
  if not ok then error(err, 0) end
  return calls
end

local function warnings(calls)
  local found = {}
  for _, c in ipairs(calls) do
    if c.level == vim.log.levels.WARN then table.insert(found, c) end
  end
  return found
end

for _, case in ipairs({ { 'an empty table', {} }, { 'a string', 'x' } }) do
  assert.run_test('comment_types as ' .. case[1] .. ' falls back to the defaults with a warning', function()
    local calls = capture_notify(function()
      config.setup({ storage_file = test_helper.storage_file, comment_types = case[2] })
    end)
    assert.length(warnings(calls), 1, 'one warning')
    assert.matches(warnings(calls)[1].msg, 'comment_types', 'warning names the option')
    assert.truthy(utils.get_comment_type_config('issue'), 'issue type available')
    assert.equals(vim.tbl_count(config.options.comment_types), 6, 'all default types')
  end)
end

assert.run_test('a valid comment_types gives no warning', function()
  local calls = capture_notify(function()
    config.setup({ storage_file = test_helper.storage_file, comment_types = { bug = { sign = 'B', description = 'Bugs' } } })
  end)
  assert.length(warnings(calls), 0, 'no warning')
  assert.equals(vim.tbl_count(config.options.comment_types), 1, 'user types replace the defaults')
end)

assert.run_test('type_legend is generated when not set, in type order', function()
  config.setup({ storage_file = test_helper.storage_file })
  assert.equals(config.options.export.type_legend,
    'Comment types: ISSUE (Problems to fix), SUGGESTION (Improvements), NOTE (Observations), '
      .. 'PRAISE (Positive feedback), QUESTION (Clarification needed), INSIGHT (Useful observations)\n',
    'generated legend')
end)

assert.run_test('a user type_legend is kept, even an empty one', function()
  config.setup({ storage_file = test_helper.storage_file, export = { type_legend = 'X\n' } })
  assert.equals(config.options.export.type_legend, 'X\n', 'custom legend kept')
  config.setup({ storage_file = test_helper.storage_file, export = { type_legend = '' } })
  assert.equals(config.options.export.type_legend, '', 'empty legend kept')
  assert.equals(config.options.export.header, config.defaults.export.header, 'other export options default')
end)

assert.run_test('get_comment_types lists defaults in order, then extra types sorted', function()
  config.setup({
    storage_file = test_helper.storage_file,
    additional_comment_types = {
      zeta = { sign = 'Z', description = 'z' },
      alpha = { sign = 'A', description = 'a' },
    },
  })
  local expected = { 'issue', 'suggestion', 'note', 'praise', 'question', 'insight', 'alpha', 'zeta' }
  for _ = 1, 3 do
    assert.equals(table.concat(utils.get_comment_types(), ','), table.concat(expected, ','), 'order')
  end
end)

assert.run_test('options hold the defaults before setup()', function()
  package.loaded['quickfix-review.config'] = nil
  local fresh = require('quickfix-review.config')
  package.loaded['quickfix-review.config'] = config
  assert.equals(vim.tbl_count(fresh.options.comment_types), 6, 'default comment types')
  assert.truthy(fresh.options.signs.issue, 'signs derived')
  assert.matches(fresh.options.export.type_legend, '^Comment types: ISSUE', 'legend derived')
  assert.equals(fresh.options.keymaps.add_issue, '<leader>ci', 'type keymaps derived')
  assert.equals(fresh.options.keymaps.edit, '<leader>cm', 'edit keymap')
  local lhs_of = {}
  for name, lhs in pairs(fresh.options.keymaps) do
    if lhs then
      assert.equals(lhs_of[lhs], nil, 'default keymaps ' .. tostring(lhs_of[lhs]) .. ' and ' .. name .. ' share ' .. lhs)
      lhs_of[lhs] = name
    end
  end
  assert.equals(fresh.options.storage_file, nil, 'no storage_file by default')
  assert.equals(fresh.options.storage_dir, nil, 'default storage_dir')
  assert.equals(fresh.options.auto_show, true, 'auto_show on by default')
end)

assert.run_test('auto_show = false: navigating the review list opens no float', function()
  local qf = require('quickfix-review')
  local ok, err = pcall(function()
    qf.setup({ storage_file = test_helper.storage_file, auto_show = false })
    test_helper.create_test_file('line 1\nline 2\nline 3\n')
    vim.cmd('only')
    qf.clear_review()
    vim.fn.cursor(1, 1)
    qf.add_comment('NOTE')
    vim.fn.cursor(3, 1)
    qf.add_comment('NOTE')
    qf.show_list()
    for _, cmd in ipairs({ 'cc 1', 'cnext' }) do
      vim.cmd(cmd)
      vim.api.nvim_exec_autocmds('CursorMoved', {})
      vim.wait(50, function() return false end)
    end
    assert.equals(vim.fn.line('.'), 3, 'cnext moved')
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      assert.equals(vim.api.nvim_win_get_config(win).relative, '', 'no float open')
    end
  end)
  vim.api.nvim_exec_autocmds('CursorMoved', {})
  vim.fn.setqflist({})
  qf.clear_review()
  test_helper.setup_test_environment()
  if not ok then error(err, 0) end
end)

assert.run_test('auto_show = false: reloading the selected file does not move the cursor', function()
  local qf = require('quickfix-review')
  local ok, err = pcall(function()
    qf.setup({ storage_file = test_helper.storage_file, auto_show = false })
    local file = test_helper.create_test_file('line 1\nline 2\nline 3\nline 4\nline 5\n')
    vim.cmd('only')
    qf.clear_review()
    vim.fn.cursor(1, 1)
    qf.add_comment('NOTE')
    vim.fn.cursor(3, 1)
    qf.add_comment('NOTE')
    qf.show_list()
    for _, cmd in ipairs({ 'cc 1', 'cnext' }) do
      vim.cmd(cmd)
      vim.api.nvim_exec_autocmds('CursorMoved', {})
      vim.wait(50, function() return false end)
    end
    assert.equals(vim.fn.line('.'), 3, 'cnext moved')
    -- Two lines inserted above both comments on disk, then reloaded
    vim.fn.writefile({ 'x', 'y', 'line 1', 'line 2', 'line 3', 'line 4', 'line 5' }, file)
    vim.cmd('silent edit!')
    vim.wait(50, function() return false end)
    assert.equals(vim.fn.line('.'), 3, 'cursor not moved by the plugin')
  end)
  vim.api.nvim_exec_autocmds('CursorMoved', {})
  vim.fn.setqflist({})
  qf.clear_review()
  test_helper.setup_test_environment()
  if not ok then error(err, 0) end
end)

assert.run_test('reloading a file loaded before setup does not move the cursor', function()
  local qf = require('quickfix-review')
  local moved = vim.fn.tempname() .. '.txt'
  local ok, err = pcall(function()
    test_helper.create_test_file('home 1\nhome 2\n')
    vim.cmd('only')
    qf.clear_review()
    vim.fn.cursor(1, 1)
    qf.add_comment('NOTE')
    -- Loaded without the plugin seeing its read, as when the plugin is set
    -- up lazily or a session is restored before setup()
    vim.fn.writefile({ 'line 1', 'line 2', 'line 3', 'line 4', 'line 5' }, moved)
    vim.cmd('noautocmd edit ' .. vim.fn.fnameescape(moved))
    qf.setup({ storage_file = test_helper.storage_file })
    vim.fn.cursor(3, 1)
    qf.add_comment('ISSUE')
    qf.show_list()
    local idx
    for i, item in ipairs(vim.fn.getqflist()) do
      if item.bufnr == vim.fn.bufnr(moved) then idx = i end
    end
    assert.truthy(idx, 'entry for the file')
    vim.cmd('cc ' .. idx)
    vim.api.nvim_exec_autocmds('CursorMoved', {})
    vim.wait(50, function() return false end)
    assert.equals(vim.fn.line('.'), 3, 'on the entry')
    -- Two lines inserted above the comment on disk, then reloaded
    vim.fn.writefile({ 'x', 'y', 'line 1', 'line 2', 'line 3', 'line 4', 'line 5' }, moved)
    vim.cmd('silent edit!')
    vim.wait(50, function() return false end)
    assert.equals(vim.fn.line('.'), 3, 'cursor not moved by the plugin')
  end)
  vim.api.nvim_exec_autocmds('CursorMoved', {})
  vim.fn.setqflist({})
  qf.clear_review()
  test_helper.setup_test_environment()
  pcall(vim.cmd, 'bwipeout! ' .. vim.fn.fnameescape(moved))
  vim.fn.delete(moved)
  if not ok then error(err, 0) end
end)

-- Put the test configuration back for the files that run after this one
test_helper.setup_test_environment()
test_helper.cleanup_test_environment()

return assert
