-- Tests for sign placement
local test_helper = dofile((vim.env.QFR_TEST_ROOT or '.') .. '/test/init.lua')
local assert = dofile(test_helper.root .. '/test/assertions.lua')
local utils = require('quickfix-review.utils')

print('\nRunning sign tests...')

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
line 11
line 12
]])

-- Get extmarks on a specific line (0-indexed internally, 1-indexed for callers)
local function get_extmarks_on_line(bufnr, lnum)
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, utils.get_ns_id(), { lnum - 1, 0 }, { lnum - 1, -1 }, { details = true })
  return marks
end

local function has_sign_on_line(bufnr, lnum)
  return #get_extmarks_on_line(bufnr, lnum) > 0
end

-- Get the raw sign text from extmarks on a line (trimmed)
local function get_sign_text_on_line(bufnr, lnum)
  local marks = get_extmarks_on_line(bufnr, lnum)
  if #marks > 0 then
    local details = marks[1][4]
    local sign_text = details and details.sign_text
    if not sign_text then return nil end
    -- Trim whitespace from sign_text (Neovim pads to 2 cells)
    return sign_text:gsub('%s+$', ''):gsub('^%s+', '')
  end
  return nil
end

-- Get the sign text from extmarks on a line (maps back to sign name for compatibility)
local function get_sign_name_on_line(bufnr, lnum)
  local sign_text = get_sign_text_on_line(bufnr, lnum)
  if not sign_text then return nil end

  -- Map sign text back to sign name (test config uses ASCII: !, S, N, +, Q, I, |)
  local sign_mapping = {
    ['!'] = 'review_issue',
    ['S'] = 'review_suggestion',
    ['N'] = 'review_note',
    ['+'] = 'review_praise',
    ['Q'] = 'review_question',
    ['I'] = 'review_insight',
  }
  if sign_text == '│' then
    -- Check highlight to determine continuation type
    local marks = get_extmarks_on_line(bufnr, lnum)
    local details = marks[1][4]
    local hl = details.sign_hl_group
    if hl == 'DiagnosticError' then return 'review_issue_continuation'
    elseif hl == 'DiagnosticWarn' then return 'review_suggestion_continuation'
    elseif hl == 'DiagnosticInfo' then return 'review_note_continuation'
    elseif hl == 'DiagnosticHint' then return 'review_praise_continuation'
    end
  end
  return sign_mapping[sign_text]
end

-- Helper to clear extmarks (replaces sign_unplace)
local function clear_extmarks(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, utils.get_ns_id(), 0, -1)
end

assert.run_test('sign config is recorded for extmarks, no legacy signs defined', function()
  for _, name in ipairs({ 'issue', 'suggestion', 'note', 'praise', 'question', 'insight' }) do
    assert.truthy(utils.sign_config[name], name .. ' sign configured')
    assert.truthy(utils.sign_config[name .. '_continuation'], name .. '_continuation configured')
  end
  assert.equals(utils.sign_config.issue.text, '!', 'issue sign text from comment_types')
  assert.equals(utils.sign_config.issue.texthl, 'DiagnosticError', 'issue sign highlight')
  assert.length(vim.fn.sign_getdefined('review_issue'), 0, 'no :sign definition')
  assert.equals(utils.place_comment_signs, nil, 'dead place_comment_signs removed')
end)

assert.run_test('single line comment places one sign', function()
  qf.clear_review()
  clear_extmarks(vim.fn.bufnr())
  local bufnr = vim.fn.bufnr()

  vim.fn.cursor(5, 1)
  qf.add_comment('ISSUE')

  assert.truthy(has_sign_on_line(bufnr, 5), 'sign on line 5')
  assert.falsy(has_sign_on_line(bufnr, 4), 'no sign on line 4')
  assert.falsy(has_sign_on_line(bufnr, 6), 'no sign on line 6')
end)

assert.run_test('multiline comment places signs on all lines', function()
  qf.clear_review()
  clear_extmarks(vim.fn.bufnr())
  local bufnr = vim.fn.bufnr()

  qf.add_comment('ISSUE', { 3, 7 })

  -- Start and end lines should have main sign
  assert.truthy(has_sign_on_line(bufnr, 3), 'sign on start line 3')
  assert.truthy(has_sign_on_line(bufnr, 7), 'sign on end line 7')

  -- Middle lines should have continuation signs
  assert.truthy(has_sign_on_line(bufnr, 4), 'sign on line 4')
  assert.truthy(has_sign_on_line(bufnr, 5), 'sign on line 5')
  assert.truthy(has_sign_on_line(bufnr, 6), 'sign on line 6')

  -- Lines outside range should have no signs
  assert.falsy(has_sign_on_line(bufnr, 2), 'no sign on line 2')
  assert.falsy(has_sign_on_line(bufnr, 8), 'no sign on line 8')
end)

assert.run_test('continuation signs on middle lines', function()
  qf.clear_review()
  clear_extmarks(vim.fn.bufnr())
  local bufnr = vim.fn.bufnr()

  qf.add_comment('ISSUE', { 2, 6 })

  -- Start line has main sign
  local start_sign = get_sign_name_on_line(bufnr, 2)
  assert.equals(start_sign, 'review_issue', 'start line has main sign')

  -- Middle lines have continuation signs
  local middle_sign = get_sign_name_on_line(bufnr, 4)
  assert.equals(middle_sign, 'review_issue_continuation', 'middle line has continuation sign')

  -- End line has main sign
  local end_sign = get_sign_name_on_line(bufnr, 6)
  assert.equals(end_sign, 'review_issue', 'end line has main sign')
end)

assert.run_test('deleting comment removes signs', function()
  qf.clear_review()
  clear_extmarks(vim.fn.bufnr())
  local bufnr = vim.fn.bufnr()

  vim.fn.cursor(5, 1)
  qf.add_comment('ISSUE')
  assert.truthy(has_sign_on_line(bufnr, 5), 'sign placed')

  qf.delete_comment({ 5, 5 })
  assert.falsy(has_sign_on_line(bufnr, 5), 'sign removed after delete')
end)

assert.run_test('restoring a deleted comment shows its sign again', function()
  qf.clear_review()
  clear_extmarks(vim.fn.bufnr())
  local bufnr = vim.fn.bufnr()

  vim.fn.cursor(5, 1)
  qf.add_comment('ISSUE')
  qf.delete_comment({ 5, 5 })
  assert.falsy(has_sign_on_line(bufnr, 5), 'sign removed after delete')
  qf.restore_comment()
  assert.truthy(has_sign_on_line(bufnr, 5), 'sign back after restore')
  qf.clear_review()
end)

assert.run_test('deleting multiline comment removes all signs', function()
  qf.clear_review()
  clear_extmarks(vim.fn.bufnr())
  local bufnr = vim.fn.bufnr()

  qf.add_comment('ISSUE', { 3, 6 })
  assert.truthy(has_sign_on_line(bufnr, 3), 'sign on line 3')
  assert.truthy(has_sign_on_line(bufnr, 5), 'sign on line 5')
  assert.truthy(has_sign_on_line(bufnr, 6), 'sign on line 6')

  qf.delete_comment({ 3, 6 })
  assert.falsy(has_sign_on_line(bufnr, 3), 'sign removed from line 3')
  assert.falsy(has_sign_on_line(bufnr, 5), 'sign removed from line 5')
  assert.falsy(has_sign_on_line(bufnr, 6), 'sign removed from line 6')
end)

assert.run_test('clear_review removes all signs', function()
  qf.clear_review()
  clear_extmarks(vim.fn.bufnr())
  local bufnr = vim.fn.bufnr()

  vim.fn.cursor(2, 1)
  qf.add_comment('ISSUE')
  qf.add_comment('NOTE', { 5, 8 })

  assert.truthy(has_sign_on_line(bufnr, 2), 'sign on line 2')
  assert.truthy(has_sign_on_line(bufnr, 5), 'sign on line 5')

  qf.clear_review()

  assert.falsy(has_sign_on_line(bufnr, 2), 'sign removed from line 2')
  assert.falsy(has_sign_on_line(bufnr, 5), 'sign removed from line 5')
end)

assert.run_test('different comment types use correct signs', function()
  qf.clear_review()
  clear_extmarks(vim.fn.bufnr())
  local bufnr = vim.fn.bufnr()

  vim.fn.cursor(2, 1)
  qf.add_comment('ISSUE')
  vim.fn.cursor(4, 1)
  qf.add_comment('SUGGESTION')
  vim.fn.cursor(6, 1)
  qf.add_comment('NOTE')
  vim.fn.cursor(8, 1)
  qf.add_comment('PRAISE')
  vim.fn.cursor(10, 1)
  qf.add_comment('QUESTION')
  vim.fn.cursor(12, 1)
  qf.add_comment('INSIGHT')

  assert.equals(get_sign_name_on_line(bufnr, 2), 'review_issue', 'issue sign')
  assert.equals(get_sign_name_on_line(bufnr, 4), 'review_suggestion', 'suggestion sign')
  assert.equals(get_sign_name_on_line(bufnr, 6), 'review_note', 'note sign')
  assert.equals(get_sign_name_on_line(bufnr, 8), 'review_praise', 'praise sign')
  assert.equals(get_sign_name_on_line(bufnr, 10), 'review_question', 'question sign')
  assert.equals(get_sign_name_on_line(bufnr, 12), 'review_insight', 'insight sign')
end)

assert.run_test('multiple comments on same line shows count', function()
  qf.clear_review()
  clear_extmarks(vim.fn.bufnr())
  local bufnr = vim.fn.bufnr()

  -- Add two comments on line 5
  vim.fn.cursor(5, 1)
  qf.add_comment('ISSUE')
  vim.fn.cursor(5, 1)
  qf.add_comment('NOTE')

  -- Should show "2" instead of a symbol
  local sign_text = get_sign_text_on_line(bufnr, 5)
  assert.equals(sign_text, '2', 'two comments shows count 2')

  -- Add a third comment
  vim.fn.cursor(5, 1)
  qf.add_comment('SUGGESTION')

  sign_text = get_sign_text_on_line(bufnr, 5)
  assert.equals(sign_text, '3', 'three comments shows count 3')
end)

assert.run_test('ten or more comments on a line show 9+', function()
  qf.clear_review()
  clear_extmarks(vim.fn.bufnr())
  local bufnr = vim.fn.bufnr()
  local ok, err = pcall(function()
    for _ = 1, 12 do
      vim.fn.cursor(5, 1)
      qf.add_comment('NOTE')
    end
  end)
  assert.truthy(ok, 'adding 12 comments does not error: ' .. tostring(err))
  assert.equals(get_sign_text_on_line(bufnr, 5), '9+', 'count clamped to 9+')
  qf.clear_review()
end)

assert.run_test('a comment type with a 3-letter sign adds and redraws without error', function()
  local ok, err = pcall(function()
    local original = vim.notify
    vim.notify = function() end
    local set_ok, set_err = pcall(qf.setup, { storage_file = test_helper.storage_file,
      additional_comment_types = { nit = { sign = 'NIT', highlight = 'DiagnosticHint', description = 'Nits' } } })
    vim.notify = original
    if not set_ok then error(set_err, 0) end
    vim.cmd('edit ' .. vim.fn.fnameescape(test_file))
    qf.clear_review()
    clear_extmarks(vim.fn.bufnr())
    local bufnr = vim.fn.bufnr()
    vim.fn.cursor(4, 1)
    local added, add_err = pcall(qf.add_comment, 'NIT')
    assert.truthy(added, 'add does not error: ' .. tostring(add_err))
    local refreshed, refresh_err = pcall(require('quickfix-review.store').refresh)
    assert.truthy(refreshed, 'redraw does not error: ' .. tostring(refresh_err))
    local text = get_sign_text_on_line(bufnr, 4)
    assert.truthy(text and vim.fn.strdisplaywidth(text) <= 2, 'sign fits 2 cells: ' .. tostring(text))
  end)
  qf.clear_review()
  test_helper.setup_test_environment()
  vim.cmd('edit ' .. vim.fn.fnameescape(test_file))
  if not ok then error(err, 0) end
end)

assert.run_test('single comment shows symbol not count', function()
  qf.clear_review()
  clear_extmarks(vim.fn.bufnr())
  local bufnr = vim.fn.bufnr()

  vim.fn.cursor(5, 1)
  qf.add_comment('ISSUE')

  -- Should show symbol, not "1"
  local sign_text = get_sign_text_on_line(bufnr, 5)
  assert.equals(sign_text, '!', 'single comment shows symbol not count')
end)

assert.run_test('overlapping multiline comments show count on shared lines', function()
  qf.clear_review()
  clear_extmarks(vim.fn.bufnr())
  local bufnr = vim.fn.bufnr()

  -- Add two overlapping multiline comments
  -- Comment 1: lines 3-6 (ISSUE) -> start=3, end=6, continuation=4,5
  -- Comment 2: lines 5-8 (NOTE)  -> start=5, end=8, continuation=6,7
  qf.add_comment('ISSUE', { 3, 6 })
  qf.add_comment('NOTE', { 5, 8 })

  -- Line 3: only comment 1 starts here (1 start/end) -> symbol
  assert.equals(get_sign_text_on_line(bufnr, 3), '!', 'line 3 shows issue symbol')

  -- Line 4: only continuation for comment 1 -> continuation symbol
  assert.equals(get_sign_text_on_line(bufnr, 4), '│', 'line 4 shows continuation')

  -- Line 5: comment 2 starts here (1 start/end), comment 1 continues
  -- Shows highest priority type's symbol (ISSUE > NOTE)
  assert.equals(get_sign_text_on_line(bufnr, 5), '!', 'line 5 shows highest priority symbol')

  -- Line 6: comment 1 ends here (1 start/end), comment 2 continues -> symbol
  assert.equals(get_sign_text_on_line(bufnr, 6), '!', 'line 6 shows issue symbol (1 end)')

  -- Line 7: only continuation for comment 2 -> continuation symbol
  assert.equals(get_sign_text_on_line(bufnr, 7), '│', 'line 7 shows continuation')

  -- Line 8: only comment 2 ends here (1 start/end) -> symbol
  assert.equals(get_sign_text_on_line(bufnr, 8), 'N', 'line 8 shows note symbol')
end)

assert.run_test('two comments starting on same line shows count', function()
  qf.clear_review()
  clear_extmarks(vim.fn.bufnr())
  local bufnr = vim.fn.bufnr()

  -- Two multiline comments both starting on line 3
  qf.add_comment('ISSUE', { 3, 5 })
  qf.add_comment('NOTE', { 3, 7 })

  -- Line 3: both comments start here (2 start/end) -> count
  assert.equals(get_sign_text_on_line(bufnr, 3), '2', 'line 3 shows count 2')

  -- Line 5: comment 1 ends here (1 start/end) -> symbol
  assert.equals(get_sign_text_on_line(bufnr, 5), '!', 'line 5 shows issue symbol')

  -- Line 7: comment 2 ends here (1 start/end) -> symbol
  assert.equals(get_sign_text_on_line(bufnr, 7), 'N', 'line 7 shows note symbol')
end)

assert.run_test('deleting one of multiple comments updates count', function()
  qf.clear_review()
  clear_extmarks(vim.fn.bufnr())
  local bufnr = vim.fn.bufnr()

  -- Add three comments on line 5
  vim.fn.cursor(5, 1)
  qf.add_comment('ISSUE')
  vim.fn.cursor(5, 1)
  qf.add_comment('NOTE')
  vim.fn.cursor(5, 1)
  qf.add_comment('SUGGESTION')

  assert.equals(get_sign_text_on_line(bufnr, 5), '3', 'three comments shows 3')

  -- Delete one comment (deletes all on that line in current impl)
  qf.delete_comment({ 5, 5 })

  -- After delete, no signs should remain (delete removes all on line)
  assert.falsy(has_sign_on_line(bufnr, 5), 'no sign after delete')
end)

assert.run_test('review signs coexist with git gutter signs on the same line', function()
  qf.clear_review()
  clear_extmarks(vim.fn.bufnr())
  local bufnr = vim.fn.bufnr()

  -- Simulate a git gutter sign (like gitsigns) with higher priority
  local git_priority = 10  -- gitsigns uses priority 6-10
  local git_ns = vim.api.nvim_create_namespace("test_gitsigns")
  vim.api.nvim_buf_set_extmark(bufnr, git_ns, 4, 0, {  -- line 5 (0-indexed: 4)
    sign_text = "+",
    sign_hl_group = "DiffAdd",
    priority = git_priority,
  })

  -- Add a review comment on the same line (lower priority)
  vim.fn.cursor(5, 1)
  qf.add_comment('ISSUE')

  -- Collect every sign extmark on line 5 across all namespaces. With
  -- signcolumn=yes:2 Neovim shows up to two signs per line, so both are
  -- visible as long as no more than two sign extmarks share the line.
  local sign_marks = vim.api.nvim_buf_get_extmarks(bufnr, -1, { 4, 0 }, { 4, -1 },
    { details = true, type = 'sign' })

  local git_mark, review_mark
  for _, mark in ipairs(sign_marks) do
    local details = mark[4]
    if details.ns_id == git_ns then
      git_mark = details
    elseif details.ns_id == utils.get_ns_id() then
      review_mark = details
    end
  end

  -- Cleanup
  vim.api.nvim_buf_clear_namespace(bufnr, git_ns, 0, -1)

  assert.length(sign_marks, 2, 'exactly two signs on line 5')
  assert.truthy(git_mark, 'git sign extmark placed on line 5')
  assert.truthy(review_mark, 'review sign extmark placed on line 5')
  if review_mark then
    assert.equals(vim.trim(review_mark.sign_text), '!', 'review sign shows issue symbol')
    assert.truthy(review_mark.priority < git_priority, 'review sign priority is below git sign priority')
  end
end)

assert.run_test('signs appear in a fugitive buffer for the real file', function()
  qf.clear_review()
  local bufnr = vim.fn.bufnr()
  clear_extmarks(bufnr)

  vim.fn.cursor(5, 1)
  qf.add_comment('ISSUE')

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local fugbuf = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_buf_set_lines(fugbuf, 0, -1, false, lines)
  vim.api.nvim_buf_set_name(fugbuf, 'fugitive://' .. vim.fn.getcwd() .. '/.git//0/' .. test_file)

  -- Entering the buffer fires BufEnter, which refreshes its signs
  vim.cmd('buffer ' .. fugbuf)
  local has_sign = has_sign_on_line(fugbuf, 5)
  vim.cmd('buffer ' .. bufnr)
  vim.cmd('bwipeout! ' .. fugbuf)

  assert.truthy(has_sign, 'sign on line 5 of the fugitive buffer')
end)

assert.run_test('a fugitive buffer holding the snapshot shows the sign at the anchor line', function()
  qf.clear_review()
  local bufnr = vim.fn.bufnr()
  clear_extmarks(bufnr)

  vim.fn.cursor(5, 1)
  qf.add_comment('ISSUE')
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  -- The working buffer moves on: the tracked position becomes line 7
  vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { 'new a', 'new b' })
  local store = require('quickfix-review.store')
  assert.equals((store.range(qf.comments()[1])), 7, 'tracked at line 7 in the working buffer')

  local fugbuf = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_buf_set_lines(fugbuf, 0, -1, false, lines)
  vim.api.nvim_buf_set_name(fugbuf, 'fugitive://' .. vim.fn.getcwd() .. '/.git//0/' .. test_file)
  vim.cmd('buffer ' .. fugbuf)
  local on5, on7 = has_sign_on_line(fugbuf, 5), has_sign_on_line(fugbuf, 7)
  -- view_comment in the diff buffer finds it at its anchor line too
  vim.fn.cursor(5, 1)
  local before = {}
  for _, w in ipairs(vim.api.nvim_list_wins()) do before[w] = true end
  qf.view_comment()
  local float
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if not before[w] and vim.api.nvim_win_get_config(w).relative ~= '' then float = w end
  end
  if float then vim.api.nvim_win_close(float, true) end
  vim.cmd('buffer ' .. bufnr)
  vim.cmd('bwipeout! ' .. fugbuf)
  vim.api.nvim_buf_set_lines(bufnr, 0, 2, false, {})
  vim.bo[bufnr].modified = false

  assert.truthy(on5, 'sign on line 5 of the fugitive buffer')
  assert.falsy(on7, 'no sign on line 7 of the fugitive buffer')
  assert.truthy(float, 'view_comment opens a float at line 5 of the fugitive buffer')
end)

assert.run_test(']r/[r in a fugitive buffer land on the signed anchor line', function()
  -- Let callbacks earlier tests scheduled run now, not mid-test (one would
  -- redraw this test's buffers from another module instance's comments)
  vim.wait(50)
  qf.clear_review()
  local bufnr = vim.fn.bufnr()
  clear_extmarks(bufnr)

  vim.fn.cursor(5, 1)
  qf.add_comment('ISSUE')
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  -- The working buffer moves on: the comment is tracked at line 7, and a
  -- second comment made now is not shown in the older revision
  vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { 'new a', 'new b' })
  vim.fn.cursor(11, 1)
  qf.add_comment('NOTE')

  local fugbuf = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_buf_set_lines(fugbuf, 0, -1, false, lines)
  vim.api.nvim_buf_set_name(fugbuf, 'fugitive://' .. vim.fn.getcwd() .. '/.git//0/' .. test_file)
  vim.cmd('buffer ' .. fugbuf)

  local function close_floats()
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(w).relative ~= '' then vim.api.nvim_win_close(w, true) end
    end
  end
  -- Jump from `from` in `direction`; returns ok, buffer, line
  local function jump_from(from, direction)
    vim.api.nvim_set_current_buf(fugbuf)
    vim.fn.cursor(from, 1)
    local ok, err = pcall(qf.jump_comment, direction)
    vim.wait(50)
    close_floats()
    return ok and true or err, vim.api.nvim_get_current_buf(), vim.fn.line('.')
  end

  local fwd_ok, fwd_buf, fwd_line = jump_from(1, 1)
  local signed = has_sign_on_line(fugbuf, 5)
  local back_ok, back_buf, back_line = jump_from(#lines, -1)
  local wrap_ok, wrap_buf, wrap_line = jump_from(6, 1)

  vim.cmd('buffer ' .. bufnr)
  vim.cmd('bwipeout! ' .. fugbuf)
  vim.api.nvim_buf_set_lines(bufnr, 0, 2, false, {})
  vim.bo[bufnr].modified = false
  qf.clear_review()

  assert.equals(fwd_ok, true, ']r did not error')
  assert.equals(fwd_buf, fugbuf, ']r stays in the fugitive buffer')
  assert.equals(fwd_line, 5, ']r lands on the anchor line, not the tracked line 7')
  assert.truthy(signed, 'the sign is on line 5')
  assert.equals(back_ok, true, '[r did not error')
  assert.equals(back_buf, fugbuf, '[r stays in the fugitive buffer')
  assert.equals(back_line, 5, '[r skips the comment this revision does not show')
  assert.equals(wrap_ok, true, ']r past the last shown comment did not error')
  assert.equals(wrap_buf, fugbuf, ']r wraps within the fugitive buffer')
  assert.equals(wrap_line, 5, ']r wraps to the shown comment')
end)

assert.run_test('a comment added in a fugitive buffer holding the snapshot keeps its sign at the anchor line there', function()
  qf.clear_review()
  local bufnr = vim.fn.bufnr()
  clear_extmarks(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  local fugbuf = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_buf_set_lines(fugbuf, 0, -1, false, lines)
  vim.api.nvim_buf_set_name(fugbuf, 'fugitive://' .. vim.fn.getcwd() .. '/.git//0/' .. test_file)
  vim.cmd('buffer ' .. fugbuf)
  vim.fn.cursor(5, 1)
  qf.add_comment('ISSUE')
  local added = #qf.comments()

  -- The working buffer moves on: the tracked position becomes line 7
  vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { 'new a', 'new b' })
  local store = require('quickfix-review.store')
  local working = added == 1 and (store.range(qf.comments()[1])) or nil
  vim.api.nvim_exec_autocmds('BufEnter', { buffer = fugbuf })
  local on5, on7 = has_sign_on_line(fugbuf, 5), has_sign_on_line(fugbuf, 7)

  vim.cmd('buffer ' .. bufnr)
  vim.cmd('bwipeout! ' .. fugbuf)
  vim.api.nvim_buf_set_lines(bufnr, 0, 2, false, {})
  vim.bo[bufnr].modified = false

  assert.equals(added, 1, 'comment added from the fugitive buffer')
  assert.equals(working, 7, 'tracked at line 7 in the working buffer')
  assert.truthy(on5, 'sign on line 5 of the fugitive buffer')
  assert.falsy(on7, 'no sign on line 7 of the fugitive buffer')
end)

assert.run_test('comment added through a symlink shows on the real path', function()
  qf.clear_review()
  local orig_buf = vim.fn.bufnr()

  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  local real = dir .. '/real.txt'
  local link = dir .. '/link.txt'
  vim.fn.writefile({ 'a', 'b', 'c', 'd' }, real)
  assert.truthy(vim.uv.fs_symlink(real, link), 'symlink created')

  vim.cmd('edit ' .. vim.fn.fnameescape(link))
  local link_buf = vim.fn.bufnr()
  vim.fn.cursor(3, 1)
  qf.add_comment('ISSUE')
  vim.cmd('buffer ' .. orig_buf)
  vim.cmd('bwipeout! ' .. link_buf)

  vim.cmd('edit ' .. vim.fn.fnameescape(real))
  local real_buf = vim.fn.bufnr()
  local has_sign = has_sign_on_line(real_buf, 3)
  vim.cmd('buffer ' .. orig_buf)
  vim.cmd('bwipeout! ' .. real_buf)
  qf.clear_review()
  vim.fn.delete(dir, 'rf')

  assert.truthy(has_sign, 'sign on line 3 of the real-path buffer')
end)

assert.run_test('a comment on a file not yet created, through a symlinked dir, shows once it exists', function()
  qf.clear_review()
  local store = require('quickfix-review.store')
  local orig_buf = vim.fn.bufnr()

  local root = vim.fn.tempname()
  local real_dir = root .. '/real'
  local link_dir = root .. '/link'
  vim.fn.mkdir(real_dir, 'p')
  assert.truthy(vim.uv.fs_symlink(real_dir, link_dir), 'symlink created')
  local link_file = link_dir .. '/later.txt'

  -- A comment (as the log could carry one) on the file through the
  -- symlinked dir, before the file exists on disk
  assert.truthy(store.add({ filename = link_file, lnum = 3, kind = 'issue', body = 'x' }), 'added')
  local id = store.all()[1] and store.all()[1].id
  assert.truthy(id, 'comment added')
  assert.falsy(vim.uv.fs_realpath(vim.fn.fnamemodify(store.get(id).filename, ':p')),
    'the comment path does not resolve yet')

  -- Build the index while the path is unresolved
  store.in_file(utils.path_key(link_file))

  -- The file appears; open it by its real path
  vim.fn.writefile({ 'a', 'b', 'c', 'd' }, real_dir .. '/later.txt')
  vim.cmd('edit ' .. vim.fn.fnameescape(real_dir .. '/later.txt'))
  local real_buf = vim.fn.bufnr()
  local listed = store.in_file(utils.path_key(vim.api.nvim_buf_get_name(real_buf)))
  local found = false
  for _, c in ipairs(listed) do
    if c.id == id then found = true end
  end
  local has_sign = has_sign_on_line(real_buf, 3)
  vim.cmd('buffer ' .. orig_buf)
  vim.cmd('bwipeout! ' .. real_buf)
  qf.clear_review()
  vim.fn.delete(root, 'rf')

  assert.truthy(found, 'in_file lists the comment under the resolved path')
  assert.truthy(has_sign, 'sign on line 3 of the now-existing file')
end)

assert.run_test('refresh_buffer_signs skips lines past the end of the buffer', function()
  qf.clear_review()
  local bufnr = vim.fn.bufnr()
  local abs = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ':p')
  local count = vim.api.nvim_buf_line_count(bufnr)
  local function all_marks()
    return vim.api.nvim_buf_get_extmarks(bufnr, utils.get_ns_id(), 0, -1, {})
  end
  local function refresh(records)
    local ok, err = pcall(utils.refresh_buffer_signs, bufnr, abs, records)
    assert.truthy(ok, 'refresh does not error: ' .. tostring(err))
  end

  -- Wholly beyond the end: no sign at all
  refresh({ { filename = abs, lnum = count + 8, end_lnum = count + 8, kind = 'note', text = '[NOTE] x' } })
  assert.length(all_marks(), 0, 'no sign for a comment past the end')

  -- Straddling the end: signs only on the lines that exist
  refresh({ { filename = abs, lnum = count - 1, end_lnum = count + 3, kind = 'note', text = '[NOTE] x' } })
  assert.truthy(has_sign_on_line(bufnr, count - 1), 'sign on the start line')
  assert.truthy(has_sign_on_line(bufnr, count), 'sign on the last line')
  assert.length(all_marks(), 2, 'signs only on existing lines')

  -- A valid comment alongside one past the end still gets its sign
  refresh({
    { filename = abs, lnum = count + 8, end_lnum = count + 8, kind = 'issue', text = '[ISSUE] x' },
    { filename = abs, lnum = 3, end_lnum = 3, kind = 'note', text = '[NOTE] y' },
  })
  assert.length(all_marks(), 1, 'one sign placed')
  assert.equals(get_sign_name_on_line(bufnr, 3), 'review_note', 'valid comment keeps its sign')

  utils.refresh_buffer_signs(bufnr, abs, qf.comments())
  qf.clear_review()
end)

test_helper.cleanup_test_environment()

return assert
