-- Tests for comment add/delete operations
local test_helper = dofile('test/init.lua')
local assert = dofile('test/assertions.lua')

print('\nRunning comment tests...')

local qf = test_helper.setup_test_environment()
local test_file = test_helper.create_test_file([[
line 1
line 2
line 3
line 4
line 5
line 6
line 7
line 8
line 9
line 10
]])

assert.run_test('add single line ISSUE comment', function()
  qf.clear_review()
  vim.fn.cursor(5, 1)
  qf.add_comment('ISSUE')

  local list = qf.comments()
  assert.length(list, 1, 'quickfix list length')
  assert.equals(list[1].lnum, 5, 'comment line number')
  assert.equals(list[1].end_lnum, 5, 'comment end line')
  assert.equals(list[1].kind, 'issue', 'comment kind')
end)

assert.run_test('add multiline ISSUE comment', function()
  qf.clear_review()
  qf.add_comment('ISSUE', { 3, 7 })

  local list = qf.comments()
  assert.length(list, 1, 'quickfix list length')
  assert.equals(list[1].lnum, 3, 'comment start line')
  assert.equals(list[1].end_lnum, 7, 'comment end line')
  assert.equals(list[1].kind, 'issue', 'comment kind')
  assert.equals(list[1].body, 'Test comment', 'body has no prefix')
  assert.equals(require('quickfix-review.store').headline(list[1]), '[ISSUE:L3-7] Test comment', 'shown with its range')
end)

assert.run_test('add SUGGESTION comment', function()
  qf.clear_review()
  vim.fn.cursor(2, 1)
  qf.add_comment('SUGGESTION')

  local list = qf.comments()
  assert.length(list, 1, 'quickfix list length')
  assert.equals(list[1].kind, 'suggestion', 'comment type')
end)

assert.run_test('add NOTE comment', function()
  qf.clear_review()
  vim.fn.cursor(4, 1)
  qf.add_comment('NOTE')

  local list = qf.comments()
  assert.length(list, 1, 'quickfix list length')
  assert.equals(list[1].kind, 'note', 'comment type')
end)

assert.run_test('add PRAISE comment', function()
  qf.clear_review()
  vim.fn.cursor(6, 1)
  qf.add_comment('PRAISE')

  local list = qf.comments()
  assert.length(list, 1, 'quickfix list length')
  assert.equals(list[1].kind, 'praise', 'comment type')
end)

assert.run_test('add QUESTION comment', function()
  qf.clear_review()
  vim.fn.cursor(7, 1)
  qf.add_comment('QUESTION')

  local list = qf.comments()
  assert.length(list, 1, 'quickfix list length')
  assert.equals(list[1].kind, 'question', 'comment type')
end)

assert.run_test('add INSIGHT comment', function()
  qf.clear_review()
  vim.fn.cursor(8, 1)
  qf.add_comment('INSIGHT')

  local list = qf.comments()
  assert.length(list, 1, 'quickfix list length')
  assert.equals(list[1].kind, 'insight', 'comment type')
end)

assert.run_test('delete single line comment', function()
  qf.clear_review()
  vim.fn.cursor(5, 1)
  qf.add_comment('ISSUE')
  assert.length(qf.comments(), 1, 'comment added')

  qf.delete_comment({ 5, 5 })
  assert.length(qf.comments(), 0, 'comment deleted')
end)

assert.run_test('delete multiline comment', function()
  qf.clear_review()
  qf.add_comment('ISSUE', { 2, 6 })
  assert.length(qf.comments(), 1, 'multiline comment added')

  qf.delete_comment({ 3, 4 }) -- Delete by overlapping range
  assert.length(qf.comments(), 0, 'multiline comment deleted')
end)

assert.run_test('delete does not affect other comments', function()
  qf.clear_review()
  vim.fn.cursor(2, 1)
  qf.add_comment('ISSUE')
  vim.fn.cursor(8, 1)
  qf.add_comment('NOTE')
  assert.length(qf.comments(), 2, 'two comments added')

  qf.delete_comment({ 2, 2 })
  local list = qf.comments()
  assert.length(list, 1, 'one comment remains')
  assert.equals(list[1].kind, 'note', 'correct comment remains')
end)

assert.run_test('multiple comments on same line', function()
  qf.clear_review()
  vim.fn.cursor(5, 1)
  qf.add_comment('ISSUE')
  vim.fn.cursor(5, 1)
  qf.add_comment('NOTE')

  local list = qf.comments()
  assert.length(list, 2, 'two comments on same line')
end)

assert.run_test('clear_review removes all comments', function()
  qf.clear_review()
  vim.fn.cursor(1, 1)
  qf.add_comment('ISSUE')
  vim.fn.cursor(3, 1)
  qf.add_comment('NOTE')
  vim.fn.cursor(5, 1)
  qf.add_comment('SUGGESTION')
  assert.length(qf.comments(), 3, 'three comments added')

  qf.clear_review()
  assert.length(qf.comments(), 0, 'all comments cleared')
end)

assert.run_test('summary counts comment types', function()
  qf.clear_review()
  vim.fn.cursor(1, 1)
  qf.add_comment('ISSUE')
  vim.fn.cursor(2, 1)
  qf.add_comment('ISSUE')
  vim.fn.cursor(3, 1)
  qf.add_comment('SUGGESTION')
  vim.fn.cursor(4, 1)
  qf.add_comment('NOTE')

  -- summary() prints to output, we just verify it doesn't error
  qf.summary()
  assert.length(qf.comments(), 4, 'comments still exist after summary')
end)

local store = require('quickfix-review.store')
local utils = require('quickfix-review.utils')
local abs = vim.fn.fnamemodify(test_file, ':p')
local file_buf = vim.api.nvim_get_current_buf()

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

local function count_level(calls, level)
  local n = 0
  for _, c in ipairs(calls) do
    if c.level == level then n = n + 1 end
  end
  return n
end

-- Run fn in a fresh scratch buffer with this name and buftype, then go back
local function in_scratch(name, buftype, fn)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buf)
  vim.bo[buf].buftype = buftype
  if name then vim.api.nvim_buf_set_name(buf, name) end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'a', 'b', 'c' })
  local ok, err = pcall(fn)
  vim.api.nvim_set_current_buf(file_buf)
  vim.api.nvim_buf_delete(buf, { force = true })
  if not ok then error(err, 0) end
end

assert.run_test('a nofile scratch buffer is refused with a warning', function()
  qf.clear_review()
  in_scratch('scratch-notes', 'nofile', function()
    vim.fn.cursor(1, 1)
    local calls = capture_notify(function() qf.add_comment('ISSUE') end)
    assert.equals(count_level(calls, vim.log.levels.WARN), 1, 'one warning')
  end)
  assert.length(qf.comments(), 0, 'no comment added')
end)

assert.run_test('an unnamed buffer is refused with a warning', function()
  qf.clear_review()
  in_scratch(nil, '', function()
    local calls = capture_notify(function() qf.add_comment('NOTE') end)
    assert.equals(count_level(calls, vim.log.levels.WARN), 1, 'one warning')
  end)
  assert.length(qf.comments(), 0, 'no comment added')
end)

assert.run_test('a diffview buffer (buftype nofile) is still accepted', function()
  qf.clear_review()
  in_scratch('diffview:///no-such-repo/.git/abc123/test_file.txt', 'nofile', function()
    vim.fn.cursor(2, 1)
    local calls = capture_notify(function() qf.add_comment('NOTE') end)
    assert.equals(count_level(calls, vim.log.levels.WARN), 0, 'no warning')
  end)
  local list = qf.comments()
  assert.length(list, 1, 'comment added')
  assert.equals(list[1].filename, '/no-such-repo/test_file.txt', 'real file path recorded')
  qf.clear_review()
end)

assert.run_test('store.add reports whether the comment was added', function()
  qf.clear_review()
  assert.equals(store.add({ filename = '', lnum = 1, text = '[NOTE] x' }), false, 'no file: refused')
  assert.length(qf.comments(), 0, 'nothing stored')
  assert.equals(store.add({ filename = abs, lnum = 1, text = '[NOTE] x' }), true, 'added')
  assert.length(qf.comments(), 1, 'stored')
  qf.clear_review()
end)

assert.run_test('jump to a comment past the end of the file lands on the last line', function()
  qf.clear_review()
  store.add({ filename = abs, lnum = 50, end_lnum = 50, text = '[NOTE] beyond the end' })
  vim.fn.cursor(1, 1)
  local ok, err = pcall(qf.jump_comment, 1)
  assert.truthy(ok, 'jump does not error: ' .. tostring(err))
  assert.equals(vim.api.nvim_get_current_buf(), file_buf, 'same buffer')
  assert.equals(vim.fn.line('.'), 10, 'clamped to line 10')
  vim.api.nvim_exec_autocmds('CursorMoved', {})
  qf.clear_review()
end)

assert.run_test('jump treats a comment made through a symlink as this file', function()
  qf.clear_review()
  local link = vim.fn.tempname() .. '-link.txt'
  assert.truthy(vim.uv.fs_symlink(abs, link), 'symlink created')
  local ok, err = pcall(function()
    store.add({ filename = link, lnum = 3, text = '[NOTE] via link' })
    store.add({ filename = abs, lnum = 8, text = '[NOTE] direct' })
    vim.fn.cursor(1, 1)

    local lines = {}
    for _ = 1, 3 do
      qf.jump_comment(1)
      vim.api.nvim_exec_autocmds('CursorMoved', {})
      assert.equals(vim.api.nvim_get_current_buf(), file_buf, 'stays in the file buffer')
      table.insert(lines, vim.fn.line('.'))
    end
    assert.equals(table.concat(lines, ','), '3,8,3', 'next visits L3, L8, then wraps to L3')
    qf.jump_comment(-1)
    vim.api.nvim_exec_autocmds('CursorMoved', {})
    assert.equals(vim.fn.line('.'), 8, 'previous from L3 wraps to L8')
  end)
  os.remove(link)
  qf.clear_review()
  if not ok then error(err, 0) end
end)

assert.run_test('summary_data counts every configured type in a fixed order', function()
  qf.clear_review()
  vim.fn.cursor(1, 1)
  qf.add_comment('ISSUE')
  vim.fn.cursor(2, 1)
  qf.add_comment('ISSUE')
  vim.fn.cursor(3, 1)
  qf.add_comment('QUESTION')

  local data = qf.summary_data()
  assert.equals(data.total, 3, 'total')
  local names, counts = {}, {}
  for _, entry in ipairs(data.by_type) do
    table.insert(names, entry[1])
    counts[entry[1]] = entry[2]
  end
  assert.equals(table.concat(names, ','), table.concat(utils.get_comment_types(), ','), 'all types, in order')
  assert.equals(names[1], 'issue', 'issue first')
  assert.equals(counts.issue, 2, 'two issues')
  assert.equals(counts.question, 1, 'one question')
  assert.equals(counts.note, 0, 'no notes')
  assert.equals(vim.inspect(qf.summary_data()), vim.inspect(data), 'same result on repeat')
  qf.summary()
  qf.clear_review()
end)

-- :ReviewClear with vim.fn.confirm stubbed to return `answer`; returns how
-- many times confirm was asked
local function review_clear(cmd, answer)
  local asked = 0
  local original = vim.fn.confirm
  vim.fn.confirm = function() asked = asked + 1 return answer end
  local ok, err = pcall(vim.cmd, cmd)
  vim.fn.confirm = original
  if not ok then error(err, 0) end
  return asked
end

vim.g.loaded_quickfix_review = nil
vim.cmd('runtime plugin/quickfix-review.lua')

assert.run_test(':ReviewClear asks first and keeps comments on No', function()
  qf.clear_review()
  qf.add_comment('ISSUE', { 1, 1 })
  assert.equals(review_clear('ReviewClear', 2), 1, 'asked once')
  assert.length(qf.comments(), 1, 'nothing cleared')
end)

assert.run_test(':ReviewClear clears on Yes', function()
  qf.clear_review()
  qf.add_comment('ISSUE', { 1, 1 })
  assert.equals(review_clear('ReviewClear', 1), 1, 'asked once')
  assert.length(qf.comments(), 0, 'cleared')
end)

assert.run_test(':ReviewClear! clears without asking', function()
  qf.clear_review()
  qf.add_comment('ISSUE', { 1, 1 })
  assert.equals(review_clear('ReviewClear!', 2), 0, 'not asked')
  assert.length(qf.comments(), 0, 'cleared')
end)

test_helper.cleanup_test_environment()

return assert
