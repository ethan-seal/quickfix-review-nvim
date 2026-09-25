-- Tests for persistence: the review lives in the plugin, is written through to
-- disk on every change, and the quickfix list is only a view of it
local test_helper = dofile('test/init.lua')
local assert = dofile('test/assertions.lua')

print('\nRunning persistence tests...')

local qf = test_helper.setup_test_environment()
local test_file = test_helper.create_test_file([[
line 1
line 2
line 3
line 4
line 5
]])

local storage_file = test_helper.storage_file

local function reset()
  vim.fn.setqflist({}, 'f')
  os.remove(storage_file)
  qf.clear_review()
end

local function saved()
  return vim.fn.json_decode(table.concat(vim.fn.readfile(storage_file), '\n'))
end

-- Simulate quitting and reopening Neovim: drop every module and set up again
local function restart()
  for name, _ in pairs(package.loaded) do
    if name:match('^quickfix%-review') then package.loaded[name] = nil end
  end
  local fresh = require('quickfix-review')
  fresh.setup({ storage_file = storage_file })
  return fresh
end

assert.run_test('every change is written through to disk', function()
  reset()
  vim.fn.cursor(3, 1)
  qf.add_comment('ISSUE')

  local list = saved()
  assert.length(list, 1, 'comment saved without calling save_review')
  assert.equals(list[1].lnum, 3, 'correct line number')
  assert.matches(list[1].text, '%[ISSUE%]', 'correct comment type')

  qf.delete_comment({ 3, 3 })
  assert.length(saved(), 0, 'deletion saved')
end)

assert.run_test('comments survive a restart', function()
  reset()
  vim.fn.cursor(1, 1)
  qf.add_comment('ISSUE')
  qf.add_comment('NOTE', { 2, 4 })

  qf = restart()

  local list = qf.comments()
  assert.length(list, 2, 'comments loaded at setup')
  assert.equals(list[2].lnum, 2, 'start line preserved')
  assert.equals(list[2].end_lnum, 4, 'end line preserved')
end)

assert.run_test('adding after a restart keeps earlier comments', function()
  reset()
  vim.fn.cursor(1, 1)
  qf.add_comment('ISSUE')

  qf = restart()
  vim.fn.cursor(5, 1)
  qf.add_comment('NOTE')

  assert.length(saved(), 2, 'earlier comment not overwritten')
end)

assert.run_test('replacing the quickfix list does not touch the review', function()
  reset()
  vim.fn.cursor(1, 1)
  qf.add_comment('ISSUE')
  qf.load_review()

  -- What LSP references or :grep would do
  vim.fn.setqflist({ { filename = test_file, lnum = 2, text = 'lsp reference' } }, 'r')
  vim.fn.setqflist({ { filename = test_file, lnum = 4, text = 'grep hit' } }, ' ')

  vim.fn.cursor(5, 1)
  qf.add_comment('NOTE')
  qf.save_review()

  local list = saved()
  assert.length(list, 2, 'only review comments saved')
  assert.matches(list[1].text, '%[ISSUE%]', 'first comment intact')
  assert.matches(list[2].text, '%[NOTE%]', 'second comment intact')
  assert.equals(vim.fn.getqflist()[1].text, 'grep hit', 'other quickfix list left alone')
end)

assert.run_test('load_review shows the review in a new quickfix list', function()
  reset()
  vim.fn.setqflist({ { filename = test_file, lnum = 1, text = 'other list' } }, ' ')
  vim.fn.cursor(2, 1)
  qf.add_comment('SUGGESTION')

  qf.load_review()
  assert.equals(vim.fn.getqflist({ title = 0 }).title, 'Code Review Comments', 'review is current list')
  assert.length(vim.fn.getqflist(), 1, 'review shown')

  vim.fn.cursor(3, 1)
  qf.add_comment('NOTE')
  assert.length(vim.fn.getqflist(), 2, 'view follows changes')

  vim.cmd('silent colder')
  assert.equals(vim.fn.getqflist()[1].text, 'other list', 'previous list kept')
end)

assert.run_test('changes made on disk are picked up', function()
  reset()
  vim.fn.cursor(1, 1)
  qf.add_comment('ISSUE')

  local list = saved()
  table.insert(list, { filename = vim.fn.fnamemodify(test_file, ':p'), lnum = 4, text = '[NOTE] from elsewhere' })
  vim.uv.sleep(10)
  vim.fn.writefile({ vim.fn.json_encode(list) }, storage_file)

  assert.length(qf.comments(), 2, 'external comment visible')
  vim.fn.cursor(5, 1)
  qf.add_comment('PRAISE')
  assert.length(saved(), 3, 'external comment kept when adding')
end)

assert.run_test('clearing persists', function()
  reset()
  vim.fn.cursor(1, 1)
  qf.add_comment('ISSUE')
  qf.clear_review()

  assert.length(saved(), 0, 'cleared on disk')
  qf = restart()
  assert.length(qf.comments(), 0, 'still cleared after restart')
end)

assert.run_test('an unreadable file is not overwritten', function()
  reset()
  vim.fn.writefile({ 'not json' }, storage_file)

  vim.fn.cursor(1, 1)
  qf.add_comment('ISSUE')

  assert.equals(vim.fn.readfile(storage_file)[1], 'not json', 'file untouched')
end)

assert.run_test('dd in the quickfix view deletes that comment', function()
  reset()
  vim.fn.cursor(1, 1)
  qf.add_comment('ISSUE')
  vim.fn.cursor(3, 1)
  qf.add_comment('NOTE')
  qf.open_list()

  vim.fn.cursor(2, 1)
  qf.delete_comment_from_qf()
  vim.cmd('cclose')

  local list = qf.comments()
  assert.length(list, 1, 'one comment deleted')
  assert.matches(list[1].text, '%[ISSUE%]', 'the selected comment was deleted')
  assert.length(saved(), 1, 'deletion saved')
end)

-- Final cleanup
test_helper.cleanup_test_environment()

return assert
