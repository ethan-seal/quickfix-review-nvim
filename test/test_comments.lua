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
local snapshots = require('quickfix-review.snapshots')
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
  -- Anchored to what the reviewer saw: the diff buffer's revision
  local anchor = list[1].anchor
  assert.truthy(type(anchor.sha) == 'string', 'snapshot taken')
  assert.truthy(vim.deep_equal(snapshots.get(anchor.sha), { 'a', 'b', 'c' }), 'snapshot is the diff buffer')
  assert.truthy(vim.deep_equal(anchor.lines, { 'b' }), 'anchor lines from the diff buffer')
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
  vim.wait(50, function() return false end)
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
      vim.wait(50, function() return false end)
      vim.api.nvim_exec_autocmds('CursorMoved', {})
      assert.equals(vim.api.nvim_get_current_buf(), file_buf, 'stays in the file buffer')
      table.insert(lines, vim.fn.line('.'))
    end
    assert.equals(table.concat(lines, ','), '3,8,3', 'next visits L3, L8, then wraps to L3')
    qf.jump_comment(-1)
    vim.wait(50, function() return false end)
    vim.api.nvim_exec_autocmds('CursorMoved', {})
    assert.equals(vim.fn.line('.'), 8, 'previous from L3 wraps to L8')
  end)
  os.remove(link)
  qf.clear_review()
  if not ok then error(err, 0) end
end)

assert.run_test('jump crosses files in filename order and wraps across files', function()
  qf.clear_review()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  local body = {}
  for i = 1, 10 do body[i] = 'line ' .. i end
  local a, b = dir .. '/a.txt', dir .. '/b.txt'
  vim.fn.writefile(body, a)
  vim.fn.writefile(body, b)
  local ok, err = pcall(function()
    store.add({ filename = a, lnum = 2, text = '[NOTE] a2' })
    store.add({ filename = a, lnum = 5, text = '[NOTE] a5' })
    store.add({ filename = b, lnum = 4, text = '[NOTE] b4' })
    vim.cmd('edit ' .. vim.fn.fnameescape(a))
    vim.fn.cursor(1, 1)

    local function step(direction)
      qf.jump_comment(direction)
      vim.wait(50, function() return false end)
      vim.api.nvim_exec_autocmds('CursorMoved', {})
      return vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ':t'):sub(1, 1) .. ':' .. vim.fn.line('.')
    end
    local visited = {}
    for _ = 1, 4 do table.insert(visited, step(1)) end
    assert.equals(table.concat(visited, ','), 'a:2,a:5,b:4,a:2', 'next visits a, then b, then wraps to a')
    assert.equals(step(-1), 'b:4', 'previous from the first comment wraps back to b')
    assert.equals(step(-1), 'a:5', 'previous from b goes back to a')
  end)
  vim.api.nvim_set_current_buf(file_buf)
  for _, path in ipairs({ a, b }) do
    local buf = vim.fn.bufnr(path)
    if buf > 0 then vim.cmd('bwipeout! ' .. buf) end
  end
  vim.fn.delete(dir, 'rf')
  qf.clear_review()
  if not ok then error(err, 0) end
end)

assert.run_test('comment-type cycling walks the configured order and wraps both ways', function()
  local types = utils.get_comment_types()
  local n = #types
  assert.truthy(n > 1, 'several comment types configured')
  local index_of = {}
  for i, t in ipairs(types) do index_of[t] = i end

  local seen = {}
  for i = 1, n do seen[i] = qf.cycle_next_comment_type() end
  local k = index_of[seen[1]]
  assert.truthy(k, 'cycled to a configured type: ' .. tostring(seen[1]))
  for i = 1, n do
    assert.equals(seen[i], types[((k + i - 2) % n) + 1], 'next #' .. i .. ' follows the configured order')
  end
  -- n steps land one before the first: the walk wrapped round once
  assert.equals(seen[n], types[((k - 2) % n) + 1], 'next wraps past the last type')

  assert.equals(qf.cycle_previous_comment_type(), types[((k - 3) % n) + 1], 'previous steps back one')
  local back = {}
  for i = 1, n do back[i] = qf.cycle_previous_comment_type() end
  assert.equals(back[n], types[((k - 3) % n) + 1], 'previous wraps round to the same type')

  qf.clear_review()
  vim.fn.cursor(4, 1)
  qf.add_comment_cycle()
  local list = qf.comments()
  assert.length(list, 1, 'cycle comment added')
  assert.equals(list[1].kind, back[n], 'comment uses the current cycle type')
  qf.clear_review()
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

-- Run fn with print replaced by a recorder; returns the printed lines
local function capture_print(fn)
  local lines = {}
  local original = print
  _G.print = function(...) table.insert(lines, table.concat(vim.tbl_map(tostring, { ... }), ' ')) end
  local ok, err = pcall(fn)
  _G.print = original
  if not ok then error(err, 0) end
  return lines
end

local function restores()
  return #test_helper.log_ops(test_helper.log_path(), 'restore')
end

assert.run_test(':ReviewRestore brings back the last deleted comment', function()
  qf.clear_review()
  qf.add_comment('ISSUE', { 2, 2 })
  qf.add_comment('NOTE', { 5, 5 })
  local before = vim.deepcopy(qf.comments()[2])
  qf.delete_comment({ 5, 5 })
  assert.length(qf.comments(), 1, 'deleted')
  local n = restores()
  local out = capture_print(function() vim.cmd('ReviewRestore') end)
  assert.equals(restores(), n + 1, 'one restore event')
  local list = qf.comments()
  assert.length(list, 2, 'back')
  assert.equals(list[2].id, before.id, 'same id')
  assert.equals(list[2].body, before.body, 'same body')
  assert.equals(list[2].kind, before.kind, 'same kind')
  assert.equals(list[2].lnum, 5, 'same line')
  assert.truthy(out[1] and out[1]:find('Restored 1', 1, true), 'reported: ' .. tostring(out[1]))
  qf.clear_review()
end)

assert.run_test(':ReviewRestore after :ReviewClear asks and restores all of it', function()
  qf.clear_review()
  qf.add_comment('ISSUE', { 1, 1 })
  qf.add_comment('NOTE', { 3, 3 })
  qf.add_comment('PRAISE', { 5, 5 })
  local ids = {}
  for i, c in ipairs(qf.comments()) do ids[i] = c.id end
  review_clear('ReviewClear', 1)
  assert.length(qf.comments(), 0, 'cleared')

  local n = restores()
  local prompt
  local original = vim.fn.confirm
  vim.fn.confirm = function(msg) prompt = msg return 2 end
  local ok, err = pcall(vim.cmd, 'ReviewRestore')
  vim.fn.confirm = original
  if not ok then error(err, 0) end
  assert.truthy(prompt and prompt:find('3', 1, true), 'asked with the count: ' .. tostring(prompt))
  assert.equals(restores(), n, 'No: nothing logged')
  assert.length(qf.comments(), 0, 'No: nothing restored')

  assert.equals(review_clear('ReviewRestore', 1), 1, 'asked once')
  assert.equals(restores(), n + 3, 'three restore events')
  local back = {}
  for i, c in ipairs(qf.comments()) do back[i] = c.id end
  table.sort(ids)
  table.sort(back)
  assert.equals(table.concat(back, ','), table.concat(ids, ','), 'the same ids are back')
  qf.clear_review()
end)

assert.run_test('restoring a clear is one append under one lock', function()
  qf.clear_review()
  qf.add_comment('ISSUE', { 1, 1 })
  qf.add_comment('NOTE', { 3, 3 })
  qf.add_comment('PRAISE', { 5, 5 })
  qf.clear_review()
  local log = require('quickfix-review.log')
  local append, with_lock = log.append, log.with_lock
  local appends, locks, sizes = 0, 0, {}
  log.append = function(path, events, mode)
    appends = appends + 1
    table.insert(sizes, #events)
    return append(path, events, mode)
  end
  log.with_lock = function(...)
    locks = locks + 1
    return with_lock(...)
  end
  local ok, err = pcall(review_clear, 'ReviewRestore', 1)
  log.append, log.with_lock = append, with_lock
  if not ok then error(err, 0) end
  assert.equals(appends, 1, 'one append')
  assert.equals(sizes[1], 3, 'holding three events')
  assert.equals(locks, 1, 'one lock')
  assert.length(qf.comments(), 3, 'all back')
  qf.clear_review()
end)

assert.run_test(':ReviewRestore of a live id says so and logs nothing', function()
  qf.clear_review()
  qf.add_comment('ISSUE', { 2, 2 })
  local id = qf.comments()[1].id
  local n = restores()
  local out = capture_print(function() vim.cmd('ReviewRestore ' .. id) end)
  assert.equals(restores(), n, 'no restore event')
  assert.length(qf.comments(), 1, 'unchanged')
  assert.truthy(out[1] and out[1]:find(id, 1, true) and out[1]:find('live', 1, true),
    'message names the id: ' .. tostring(out[1]))
  out = capture_print(function() vim.cmd('ReviewRestore 0000nosuchid0000') end)
  assert.equals(restores(), n, 'unknown id: no restore event')
  assert.truthy(out[1] and out[1]:find('0000nosuchid0000', 1, true), 'unknown id named: ' .. tostring(out[1]))
  qf.clear_review()
end)

assert.run_test(':ReviewRestore <id> restores that comment; completion lists the trash', function()
  qf.clear_review()
  qf.add_comment('ISSUE', { 2, 2 })
  qf.add_comment('NOTE', { 4, 4 })
  local first = qf.comments()[1].id
  local second = qf.comments()[2].id
  qf.delete_comment({ 2, 2 })
  qf.delete_comment({ 4, 4 })
  local completions = vim.fn.getcompletion('ReviewRestore ', 'cmdline')
  assert.truthy(vim.tbl_contains(completions, first) and vim.tbl_contains(completions, second),
    'trash ids completed')
  local narrowed = vim.fn.getcompletion('ReviewRestore ' .. first:sub(1, 6), 'cmdline')
  assert.truthy(vim.tbl_contains(narrowed, first), 'prefix keeps the match')
  vim.cmd('ReviewRestore ' .. first)
  local list = qf.comments()
  assert.length(list, 1, 'one back')
  assert.equals(list[1].id, first, 'the named one')
  assert.falsy(vim.tbl_contains(vim.fn.getcompletion('ReviewRestore ', 'cmdline'), first),
    'restored id no longer completed')
  assert.truthy(vim.tbl_contains(vim.fn.getcompletion('ReviewHistory ', 'cmdline'), first),
    'history completes live ids')
  qf.clear_review()
end)

local function same(actual, expected, msg)
  assert.truthy(vim.deep_equal(actual, expected),
    string.format('%s: expected %s, got %s', msg, vim.inspect(expected), vim.inspect(actual)))
end

assert.run_test('a new comment is anchored to a snapshot of its buffer', function()
  qf.clear_review()
  qf.add_comment('ISSUE', { 3, 4 })
  local c = qf.comments()[1]
  local a = c.anchor
  assert.truthy(type(a.sha) == 'string', 'anchor has a sha')
  assert.equals(vim.fn.filereadable(store.snapshots_dir() .. '/' .. a.sha), 1, 'snapshot file exists')
  same(snapshots.get(a.sha), vim.api.nvim_buf_get_lines(file_buf, 0, -1, false), 'snapshot is the buffer')
  assert.equals(a.lnum, 3, 'anchor lnum')
  assert.equals(a.end_lnum, 4, 'anchor end_lnum')
  same(a.lines, { 'line 3', 'line 4' }, 'lines')
  same(a.before, { 'line 1', 'line 2' }, 'before')
  same(a.after, { 'line 5', 'line 6' }, 'after')
  assert.equals(c.lnum, a.lnum, 'top-level lnum equals the anchor')
  assert.equals(c.end_lnum, a.end_lnum, 'top-level end_lnum equals the anchor')
  same(c.pos, { sha = a.sha, lnum = 3, end_lnum = 4, state = 'current' }, 'pos starts at the anchor')
  local saved = test_helper.saved()[1]
  assert.equals(saved.anchor.sha, a.sha, 'anchor is logged')
  assert.equals(saved.pos, nil, 'pos is not logged')
  qf.clear_review()
end)

assert.run_test('anchor context is cut at the start and end of the file', function()
  qf.clear_review()
  qf.add_comment('NOTE', { 1, 1 })
  qf.add_comment('NOTE', { 9, 10 })
  local first, last = qf.comments()[1].anchor, qf.comments()[2].anchor
  same(first.before, {}, 'nothing before line 1')
  same(first.after, { 'line 2', 'line 3' }, 'after line 1')
  same(last.before, { 'line 7', 'line 8' }, 'before line 9')
  same(last.after, {}, 'nothing after line 10')
  qf.clear_review()
end)

assert.run_test('anchor lines are capped at 50', function()
  qf.clear_review()
  local long = {}
  for i = 1, 60 do long[i] = 'l' .. i end
  in_scratch('diffview:///no-such-repo/.git/abc123/long.txt', 'nofile', function()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, long)
    qf.add_comment('NOTE', { 2, 60 })
  end)
  local a = qf.comments()[1].anchor
  assert.length(a.lines, 50, '50 lines kept')
  assert.equals(a.lines[50], 'l51', 'the first 50 commented lines')
  assert.equals(a.end_lnum, 60, 'the range is not cut')
  qf.clear_review()
end)

assert.run_test('a buffer with unsaved edits is anchored to the buffer, not disk', function()
  qf.clear_review()
  vim.api.nvim_buf_set_lines(file_buf, 2, 3, false, { 'edited line 3' })
  local ok, err = pcall(function()
    qf.add_comment('ISSUE', { 3, 3 })
    local a = qf.comments()[1].anchor
    local buffer = vim.api.nvim_buf_get_lines(file_buf, 0, -1, false)
    same(snapshots.get(a.sha), buffer, 'snapshot is the buffer')
    assert.falsy(vim.deep_equal(snapshots.get(a.sha), vim.fn.readfile(abs)), 'snapshot is not the file on disk')
    same(a.lines, { 'edited line 3' }, 'anchor lines are the edited line')
  end)
  vim.cmd('edit!')
  qf.clear_review()
  if not ok then error(err, 0) end
end)

assert.run_test('a snapshot that cannot be saved warns and still adds the comment', function()
  qf.clear_review()
  local put = snapshots.put
  snapshots.put = function() return nil, 'Could not write snapshot' end
  local ok, calls = pcall(capture_notify, function() qf.add_comment('NOTE', { 2, 2 }) end)
  snapshots.put = put
  if not ok then error(calls, 0) end
  assert.equals(count_level(calls, vim.log.levels.WARN), 1, 'one warning')
  local list = qf.comments()
  assert.length(list, 1, 'comment added')
  assert.equals(list[1].anchor.sha, nil, 'no sha')
  assert.equals(list[1].anchor.lnum, 2, 'anchored by line')
  same(list[1].anchor.lines, { 'line 2' }, 'anchor lines kept')
  qf.clear_review()
end)

test_helper.cleanup_test_environment()

return assert
