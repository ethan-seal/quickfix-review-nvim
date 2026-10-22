-- Tests for comment add/delete operations
local test_helper = dofile((vim.env.QFR_TEST_ROOT or '.') .. '/test/init.lua')
local assert = dofile(test_helper.root .. '/test/assertions.lua')

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

assert.run_test('diff-plugin buffers that show no file are refused', function()
  local names = {
    'diffview://null',
    'diffview:///repo/panels/1/DiffviewFilePanel',
    'fugitive://' .. vim.fn.getcwd() .. '/.git//',
    'fugitive://' .. vim.fn.getcwd() .. '/.git//0123456789abcdef0123456789abcdef01234567',
    -- A dir that merely starts with .git is not a git dir
    'fugitive://' .. vim.fn.getcwd() .. '/.gitrepos/foo//0/file.txt',
  }
  for _, name in ipairs(names) do
    qf.clear_review()
    local adds = #test_helper.log_ops(test_helper.events_path(), 'add')
    in_scratch(name, 'nofile', function()
      vim.fn.cursor(1, 1)
      local calls = capture_notify(function() qf.add_comment('NOTE') end)
      assert.equals(count_level(calls, vim.log.levels.WARN), 1, 'one warning for ' .. name)
    end)
    assert.length(qf.comments(), 0, 'no comment added for ' .. name)
    assert.equals(#test_helper.log_ops(test_helper.events_path(), 'add'), adds, 'nothing logged for ' .. name)
  end
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

assert.run_test('a fugitive buffer with a percent-encoded name stores the decoded path', function()
  qf.clear_review()
  in_scratch('fugitive://' .. vim.fn.getcwd() .. '/.git//0/notes%231.md', 'nofile', function()
    vim.fn.cursor(2, 1)
    local calls = capture_notify(function() qf.add_comment('NOTE') end)
    assert.equals(count_level(calls, vim.log.levels.WARN), 0, 'no warning')
  end)
  local list = qf.comments()
  assert.length(list, 1, 'comment added')
  assert.truthy(list[1].filename:sub(-#'/notes#1.md') == '/notes#1.md',
    'decoded file name recorded: ' .. list[1].filename)
  qf.clear_review()
end)

assert.run_test('a gitsigns index buffer stores the real path, not the gitsigns name', function()
  qf.clear_review()
  in_scratch('gitsigns://' .. vim.fn.getcwd() .. '/.git//:0:test_file.txt', 'acwrite', function()
    vim.fn.cursor(2, 1)
    qf.add_comment('NOTE')
  end)
  local list = qf.comments()
  assert.length(list, 1, 'comment added')
  assert.falsy(list[1].filename:match('^gitsigns://'), 'no gitsigns:// path stored')
  assert.equals(list[1].filename, vim.fn.getcwd() .. '/test_file.txt', 'real file path recorded')
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

assert.run_test('setup() with fewer types resets a cycle past the end', function()
  local base = { sign = 'X', highlight = 'DiagnosticInfo' }
  local function types(names)
    local t = {}
    for _, name in ipairs(names) do t[name] = vim.tbl_extend('force', base, { description = name }) end
    return t
  end
  local ok, err = pcall(function()
    qf.setup({ storage_file = test_helper.storage_file, comment_types = types({ 'aaa', 'bbb', 'ccc' }) })
    -- Walk the cycle round to ccc
    local current
    for _ = 1, 3 do
      current = qf.cycle_next_comment_type()
      if current == 'ccc' then break end
    end
    assert.equals(current, 'ccc', 'cycled to the last type')

    qf.setup({ storage_file = test_helper.storage_file, comment_types = types({ 'aaa', 'bbb' }) })
    assert.equals(qf.cycle_next_comment_type(), 'bbb', 'next from the first type after the reset')
    assert.falsy(vim.api.nvim_get_commands({}).ReviewAddCcc, ':ReviewAddCcc deleted with its type')
    assert.equals(qf.cycle_previous_comment_type(), 'aaa', 'previous works too')
    qf.clear_review()
    vim.fn.cursor(4, 1)
    qf.add_comment_cycle()
    local list = qf.comments()
    assert.length(list, 1, 'cycle comment added')
    assert.equals(list[1].kind, 'aaa', 'comment uses a still-configured type')

    -- A current type that is still configured survives setup()
    qf.cycle_next_comment_type()
    qf.setup({ storage_file = test_helper.storage_file, comment_types = types({ 'aaa', 'bbb', 'ccc' }) })
    assert.equals(qf.cycle_next_comment_type(), 'ccc', 'kept bbb across setup()')
  end)
  qf.clear_review()
  test_helper.setup_test_environment()
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
  return #test_helper.log_ops(test_helper.events_path(), 'restore')
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
  local lock = require('quickfix-review.store.lock')
  local append, with_lock = log.append, lock.with_lock
  local appends, locks, sizes = 0, 0, {}
  log.append = function(path, events, mode)
    appends = appends + 1
    table.insert(sizes, #events)
    return append(path, events, mode)
  end
  lock.with_lock = function(...)
    locks = locks + 1
    return with_lock(...)
  end
  local ok, err = pcall(review_clear, 'ReviewRestore', 1)
  log.append, lock.with_lock = append, with_lock
  if not ok then error(err, 0) end
  assert.equals(appends, 1, 'one append')
  assert.equals(sizes[1], 3, 'holding three events')
  assert.equals(locks, 1, 'one lock')
  assert.length(qf.comments(), 3, 'all back')
  qf.clear_review()
end)

assert.run_test('a change renders after the lock is released', function()
  qf.clear_review()
  local store = require('quickfix-review.store')
  local held = {}
  store.set_on_change(function()
    table.insert(held, require('quickfix-review.store.lock').held(test_helper.flock_path()) and 1 or 0)
  end)
  local ok, err = pcall(qf.add_comment, 'ISSUE', { 2, 2 })
  -- Restores the real on_change handler
  qf = test_helper.setup_test_environment()
  if not ok then error(err, 0) end
  assert.truthy(#held >= 1, 'on_change ran')
  for i, h in ipairs(held) do
    assert.equals(h, 0, 'the lock is not held during on_change #' .. i)
  end
  assert.length(qf.comments(), 1, 'the comment is there')
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

assert.run_test(':3,5ReviewAddNote adds a range comment', function()
  qf.clear_review()
  vim.cmd('3,5ReviewAddNote')
  local list = qf.comments()
  assert.length(list, 1, 'one comment')
  assert.equals(list[1].lnum, 3, 'start line')
  assert.equals(list[1].end_lnum, 5, 'end line')
  assert.equals(list[1].kind, 'note', 'kind')
  qf.clear_review()
end)

assert.run_test(':ReviewAdd {type} adds at the cursor or over a range', function()
  qf.clear_review()
  vim.fn.cursor(2, 1)
  vim.cmd('ReviewAdd question')
  vim.cmd('2,4ReviewAdd issue')
  local list = qf.comments()
  assert.length(list, 2, 'two comments')
  local by_kind = {}
  for _, c in ipairs(list) do by_kind[c.kind] = c end
  assert.equals(by_kind.question.lnum, 2, 'question at the cursor')
  assert.equals(by_kind.question.end_lnum, 2, 'question is one line')
  assert.equals(by_kind.issue.lnum, 2, 'issue start')
  assert.equals(by_kind.issue.end_lnum, 4, 'issue end')
  qf.clear_review()
end)

assert.run_test(':ReviewAdd completes the configured types', function()
  local all = vim.fn.getcompletion('ReviewAdd ', 'cmdline')
  for _, t in ipairs({ 'issue', 'suggestion', 'note', 'praise', 'question', 'insight' }) do
    assert.truthy(vim.tbl_contains(all, t), 'completes ' .. t)
  end
  assert.truthy(vim.deep_equal(vim.fn.getcompletion('ReviewAdd in', 'cmdline'), { 'insight' }), 'prefix narrows')
end)

assert.run_test(':3,4ReviewDelete deletes comments in the range', function()
  qf.clear_review()
  qf.add_comment('ISSUE', { 4, 6 })
  qf.add_comment('NOTE', { 8, 8 })
  vim.cmd('3,4ReviewDelete')
  local list = qf.comments()
  assert.length(list, 1, 'one left')
  assert.equals(list[1].lnum, 8, 'the one outside the range')
  qf.clear_review()
end)

local function deletes()
  return #test_helper.log_ops(test_helper.events_path(), 'delete')
end

-- Run fn with vim.ui.select answering with choose(items) (nil cancels);
-- returns the format_item rows of every picker shown
local function with_select(choose, fn)
  local shown = {}
  local original = vim.ui.select
  vim.ui.select = function(items, opts, on_choice)
    table.insert(shown, vim.tbl_map(opts.format_item, items))
    on_choice(choose(items))
  end
  local ok, err = pcall(fn)
  vim.ui.select = original
  if not ok then error(err, 0) end
  return shown
end

-- Two comments covering line 5: a range one starting earlier, then a
-- single-line one. Returns their ids in that (picker) order.
local function two_on_line_5()
  qf.clear_review()
  qf.add_comment('ISSUE', { 3, 6 })
  vim.fn.cursor(5, 1)
  qf.add_comment('NOTE')
  local ids = {}
  for _, c in ipairs(qf.comments()) do ids[c.kind] = c.id end
  vim.fn.cursor(5, 1)
  return { ids.issue, ids.note }
end

assert.run_test('delete at cursor with two comments deletes only the picked one', function()
  local ids = two_on_line_5()
  local printed
  local shown = with_select(function(items) return items[2] end, function()
    printed = capture_print(function() qf.delete_comment() end)
  end)
  assert.length(shown, 1, 'one picker')
  assert.length(shown[1], 2, 'both comments offered')
  assert.truthy(shown[1][1]:find('ISSUE', 1, true), 'range comment first (starts earlier)')
  local list = qf.comments()
  assert.length(list, 1, 'one comment left')
  assert.equals(list[1].id, ids[1], 'the other comment survives')
  assert.equals(printed[1], string.format('Deleted 1 comment(s) from %s:5',
    vim.fn.fnamemodify(abs, ':.')), 'says so')
  qf.clear_review()
end)

assert.run_test('delete at cursor: a cancelled picker deletes nothing', function()
  two_on_line_5()
  local n = deletes()
  local shown = with_select(function() return nil end, function() qf.delete_comment() end)
  assert.length(shown, 1, 'picker shown')
  assert.length(qf.comments(), 2, 'both comments remain')
  assert.equals(deletes(), n, 'no delete logged')
  qf.clear_review()
end)

assert.run_test('delete at cursor: a picked comment deleted meanwhile is reported gone', function()
  local ids = two_on_line_5()
  local n = deletes()
  local printed
  with_select(function(items)
    -- Another change removes the chosen comment while the picker is open
    assert.equals(store.remove(ids[2]), 1, 'removed elsewhere')
    return items[2]
  end, function()
    printed = capture_print(function() qf.delete_comment() end)
  end)
  assert.equals(printed[1], 'Comment no longer exists', 'says so')
  assert.equals(deletes(), n + 1, 'only the other removal logged')
  assert.length(qf.comments(), 1, 'the unpicked comment remains')
  assert.equals(qf.comments()[1].id, ids[1], 'it is the range comment')
  qf.clear_review()
end)

assert.run_test('delete at cursor with one comment deletes it without a picker', function()
  qf.clear_review()
  vim.fn.cursor(5, 1)
  qf.add_comment('ISSUE')
  local shown = with_select(function() error('picker shown for one comment') end, function()
    qf.delete_comment()
  end)
  assert.length(shown, 0, 'no picker')
  assert.length(qf.comments(), 0, 'comment deleted')
end)

assert.run_test('delete with an explicit one-line range deletes every overlapping comment', function()
  two_on_line_5()
  local shown = with_select(function() error('picker shown for a range') end, function()
    qf.delete_comment({ 5, 5 })
  end)
  assert.length(shown, 0, 'no picker')
  assert.length(qf.comments(), 0, 'both deleted')
end)

assert.run_test(':ReviewDelete picks one; :5ReviewDelete deletes all on the line', function()
  local ids = two_on_line_5()
  local shown = with_select(function(items) return items[1] end, function()
    vim.cmd('ReviewDelete')
  end)
  assert.length(shown, 1, ':ReviewDelete shows a picker')
  assert.length(qf.comments(), 1, 'one deleted')
  assert.equals(qf.comments()[1].id, ids[2], 'the unpicked one survives')

  two_on_line_5()
  shown = with_select(function() error('picker shown for a range') end, function()
    vim.cmd('5ReviewDelete')
  end)
  assert.length(shown, 0, ':5ReviewDelete shows no picker')
  assert.length(qf.comments(), 0, 'both deleted')
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
  same(store.pos(c), { sha = a.sha, lnum = 3, end_lnum = 4, state = 'current' }, 'pos starts at the anchor')
  same(c.pos, store.pos(c), 'comments() carries the same pos')
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

local edit_mod = require('quickfix-review.edit')

-- The editor float (edit.lua's open_editor), when it is the current window:
-- its window and buffer
local function editor()
  local buf = vim.api.nvim_get_current_buf()
  if vim.api.nvim_buf_get_name(buf):match('^quickfix%-review://edit/') then
    return vim.api.nvim_get_current_win(), buf
  end
end

-- Every window showing an editor buffer
local function editor_wins()
  local wins = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
    if name:match('^quickfix%-review://edit/') then table.insert(wins, win) end
  end
  return wins
end

-- Close any editor float left open
local function close_editors()
  for _, win in ipairs(editor_wins()) do pcall(vim.api.nvim_win_close, win, true) end
end

-- Type keys into the current window, as the user would, and run them now
local function keys(k)
  vim.api.nvim_feedkeys(vim.keycode(k), 'x', false)
end

local function set_lines(lines)
  local _, buf = editor()
  assert.truthy(buf, 'editor float is current')
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
end

-- Run fn; close any editor float it left open, whether or not it failed
local function with_editor(fn)
  local ok, err = pcall(fn)
  close_editors()
  if not ok then error(err, 0) end
end

local function updates()
  return test_helper.log_ops(test_helper.events_path(), 'update')
end

-- The sign text and highlight on a line of the test file
local function sign_on(lnum)
  local marks = vim.api.nvim_buf_get_extmarks(file_buf, utils.get_ns_id(), { lnum - 1, 0 }, { lnum - 1, -1 },
    { details = true })
  for _, m in ipairs(marks) do
    local d = m[4]
    if d and d.sign_text then
      return (d.sign_text:gsub('%s+$', ''):gsub('^%s+', '')), d.sign_hl_group
    end
  end
end

-- Edit the comment on line 5 (one ISSUE 'Test comment'): `lines` into the
-- float, then `save` ('<CR>' or ':w')
local function edit_body_test(save)
  qf.clear_review()
  vim.fn.cursor(5, 1)
  qf.add_comment('ISSUE')
  local before = vim.deepcopy(qf.comments()[1])
  local n = #updates()

  with_editor(function()
    qf.edit_comment()
    local win, buf = editor()
    assert.truthy(win, 'editor float entered')
    assert.equals(vim.api.nvim_buf_get_name(buf), 'quickfix-review://edit/' .. before.id, 'named for the comment')
    same(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { 'Test comment' }, 'holds the body')
    assert.equals(vim.api.nvim_win_get_config(win).title[1][1], ' ISSUE ', 'titled with the type')
    set_lines({ 'New body' })
    local printed = capture_print(function()
      if save == ':w' then vim.cmd('write') else keys('<CR>') end
    end)
    assert.equals(printed[1], 'Comment edited', 'says so')
    -- After :w the float closes once the write is done (a scheduled close)
    vim.wait(100, function() return not vim.api.nvim_win_is_valid(win) end)
    assert.falsy(vim.api.nvim_win_is_valid(win), 'float closed')
    assert.equals(vim.api.nvim_get_current_buf(), file_buf, 'back in the file')
  end)

  local c = qf.comments()[1]
  assert.equals(c.body, 'New body', 'body changed')
  assert.equals(c.id, before.id, 'id unchanged')
  assert.equals(c.kind, before.kind, 'kind unchanged')
  assert.equals(c.lnum, before.lnum, 'lnum unchanged')
  assert.equals(c.anchor.sha, before.anchor.sha, 'anchor unchanged')
  same(c.anchor.lines, before.anchor.lines, 'anchor lines unchanged')
  qf.show_list()
  local row = vim.fn.getqflist()[1]
  assert.truthy(row and row.text:find('New body', 1, true), 'quickfix text updated')
  vim.cmd('cclose')

  local ups = updates()
  assert.equals(#ups, n + 1, 'one update logged')
  assert.equals(ups[#ups].id, before.id, 'update names the comment')
  assert.equals(ups[#ups].set.body, 'New body', 'update sets the body')
  assert.equals(ups[#ups].prev.body, 'Test comment', 'update keeps the old body')
  assert.equals(vim.tbl_count(ups[#ups].set), 1, 'update sets only the body')
end

assert.run_test('edit in the float, saved with <CR>: one update; id and anchor unchanged', function()
  edit_body_test('<CR>')
end)

assert.run_test('edit in the float, saved with :w', function()
  edit_body_test(':w')
end)

-- :wq / :x quit the window that is current once the write returns: that must
-- be the float, not the code window it was opened from
for _, cmd in ipairs({ 'wq', 'x' }) do
  assert.run_test(':' .. cmd .. ' in the float saves and closes only the float', function()
    qf.clear_review()
    vim.fn.cursor(5, 1)
    qf.add_comment('ISSUE')
    local id = qf.comments()[1].id
    local n = #updates()
    local code_win = vim.api.nvim_get_current_win()
    -- A second split, so a quit that lands on the code window cannot exit Neovim
    vim.cmd('split')
    local other_win = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(code_win)
    local function non_floats()
      local count = 0
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_config(w).relative == '' then count = count + 1 end
      end
      return count
    end
    local before_wins = non_floats()

    local ok, err = pcall(with_editor, function()
      qf.edit_comment()
      local win = editor()
      assert.truthy(win, 'editor float entered')
      set_lines({ 'Quit body' })
      local printed = capture_print(function() vim.cmd(cmd) end)
      vim.wait(100, function() return not vim.api.nvim_win_is_valid(win) end)
      assert.equals(printed[1], 'Comment edited', 'says so')
      assert.falsy(vim.api.nvim_win_is_valid(win), 'float closed')
      assert.length(editor_wins(), 0, 'no editor left')
      assert.truthy(vim.api.nvim_win_is_valid(code_win), 'code window still open')
      assert.truthy(vim.api.nvim_win_is_valid(other_win), 'other split still open')
      assert.equals(non_floats(), before_wins, 'no other window closed')
      assert.equals(vim.api.nvim_win_get_buf(code_win), file_buf, 'code window still shows the file')
    end)
    if vim.api.nvim_win_is_valid(other_win) and #vim.api.nvim_list_wins() > 1 then
      vim.api.nvim_win_close(other_win, true)
    end
    if vim.api.nvim_win_is_valid(code_win) then vim.api.nvim_set_current_win(code_win) end
    if not ok then error(err, 0) end

    local c = qf.comments()[1]
    assert.equals(c.id, id, 'same comment')
    assert.equals(c.body, 'Quit body', 'body changed')
    local ups = updates()
    assert.equals(#ups, n + 1, 'one update logged')
    assert.equals(ups[#ups].set.body, 'Quit body', 'update sets the body')
  end)
end

assert.run_test('q after changing the text closes the float and logs nothing', function()
  qf.clear_review()
  vim.fn.cursor(5, 1)
  qf.add_comment('ISSUE')
  local n = #updates()
  for _, cancel in ipairs({ 'q', '<Esc>' }) do
    with_editor(function()
      qf.edit_comment()
      local win = editor()
      set_lines({ 'Thrown away' })
      keys(cancel)
      assert.falsy(vim.api.nvim_win_is_valid(win), cancel .. ' closed the float')
      assert.length(editor_wins(), 0, 'no editor left')
    end)
    assert.equals(qf.comments()[1].body, 'Test comment', 'body unchanged')
    assert.equals(#updates(), n, 'no update logged')
  end
end)

assert.run_test('saving unchanged text closes the float silently and logs nothing', function()
  qf.clear_review()
  vim.fn.cursor(5, 1)
  qf.add_comment('ISSUE')
  local n = #updates()
  with_editor(function()
    qf.edit_comment()
    local win = editor()
    local printed = capture_print(function() keys('<CR>') end)
    assert.length(printed, 0, 'nothing said')
    assert.falsy(vim.api.nvim_win_is_valid(win), 'float closed')
  end)
  assert.equals(#updates(), n, 'no update logged')
end)

assert.run_test('a multi-line body is edited as lines; unchanged save keeps its breaks', function()
  qf.clear_review()
  local body = 'first line\nsecond \\ line\n\nfourth'
  store.add({ filename = vim.fn.expand('%:p'), lnum = 5, end_lnum = 5, kind = 'note', body = body })
  vim.fn.cursor(5, 1)
  local n = #updates()
  with_editor(function()
    qf.edit_comment()
    local win, buf = editor()
    same(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { 'first line', 'second \\ line', '', 'fourth' },
      'one buffer line per line, backslashes as they are')
    assert.equals(vim.api.nvim_win_get_height(win), 4, 'as tall as the body')
    keys('<CR>')
    assert.falsy(vim.api.nvim_win_is_valid(win), 'float closed')
  end)
  assert.equals(#updates(), n, 'no update logged')
  assert.equals(qf.comments()[1].body, body, 'body intact')

  -- Trailing blank lines are dropped; a new line is a real edit
  with_editor(function()
    qf.edit_comment()
    set_lines({ 'a', 'b', '', '  ', '' })
    keys('<CR>')
  end)
  assert.equals(#updates(), n + 1, 'one update logged')
  assert.equals(qf.comments()[1].body, 'a\nb', 'lines joined with breaks, trailing blanks dropped')
end)

assert.run_test('cycling the type in the float saves it with the body in one update', function()
  qf.clear_review()
  vim.fn.cursor(5, 1)
  qf.add_comment('ISSUE')
  local id = qf.comments()[1].id
  local types = utils.get_comment_types()
  assert.equals(types[1], 'issue', 'issue is the first type')
  local cycle_before = edit_mod.current_cycle_type()
  local n = #updates()

  with_editor(function()
    qf.edit_comment()
    local win = editor()
    assert.truthy(vim.api.nvim_win_get_config(win).footer[1][1]:find('+/- type', 1, true), 'footer names the keys')
    keys('+')
    assert.equals(vim.api.nvim_win_get_config(win).title[1][1], ' ' .. types[2]:upper() .. ' ', 'retitled')
    assert.equals(vim.api.nvim_win_get_config(win).relative, 'win', 'still anchored where it opened')
    keys('+')
    keys('-')
    assert.equals(vim.api.nvim_win_get_config(win).title[1][1], ' ' .. types[2]:upper() .. ' ', 'back one')
    assert.equals(edit_mod.current_cycle_type(), cycle_before, 'the add cycle is untouched')
    set_lines({ 'Now a suggestion' })
    keys('<CR>')
    assert.falsy(vim.api.nvim_win_is_valid(win), 'float closed')
  end)

  local ups = updates()
  assert.equals(#ups, n + 1, 'one update logged')
  same(ups[#ups].set, { body = 'Now a suggestion', kind = types[2] }, 'sets body and kind')
  same(ups[#ups].prev, { body = 'Test comment', kind = 'issue' }, 'keeps the old ones')
  local c = store.get(id)
  assert.equals(c.kind, types[2], 'kind changed')
  assert.equals(edit_mod.current_cycle_type(), cycle_before, 'the add cycle is still untouched')

  local text, hl = sign_on(5)
  assert.equals(text, 'S', 'sign shows the new type')
  assert.equals(hl, 'DiagnosticWarn', 'sign highlight of the new type')
  qf.show_list()
  assert.equals(vim.fn.getqflist()[1].type, 'S', 'quickfix type changed')
  vim.cmd('cclose')

  -- The type alone
  with_editor(function()
    qf.edit_comment()
    keys('-')
    keys('<CR>')
  end)
  ups = updates()
  assert.equals(#ups, n + 2, 'second update logged')
  same(ups[#ups].set, { kind = 'issue' }, 'sets only the kind')
  same(ups[#ups].prev, { kind = types[2] }, 'previous kind kept')
end)

assert.run_test('an emptied float is not saved and stays open', function()
  qf.clear_review()
  vim.fn.cursor(5, 1)
  qf.add_comment('ISSUE')
  local n = #updates()
  with_editor(function()
    qf.edit_comment()
    local win = editor()
    set_lines({ '', '   ' })
    local printed = capture_print(function() keys('<CR>') end)
    assert.equals(printed[1], 'Comment text is empty (q to cancel)', 'says so')
    assert.truthy(vim.api.nvim_win_is_valid(win), 'float still open')
    assert.equals(vim.api.nvim_get_current_win(), win, 'still in it')
  end)
  assert.equals(#updates(), n, 'no update logged')
  assert.equals(qf.comments()[1].body, 'Test comment', 'body unchanged')
end)

assert.run_test('editing while the view float is open replaces it with the editor', function()
  qf.clear_review()
  vim.fn.cursor(5, 1)
  qf.add_comment('ISSUE')
  local id = qf.comments()[1].id
  local file_win = vim.api.nvim_get_current_win()
  with_editor(function()
    qf.view_comment()
    local floats = vim.tbl_filter(function(w) return vim.api.nvim_win_get_config(w).relative ~= '' end,
      vim.api.nvim_list_wins())
    assert.length(floats, 1, 'view float open')
    qf.edit_comment()
    floats = vim.tbl_filter(function(w) return vim.api.nvim_win_get_config(w).relative ~= '' end,
      vim.api.nvim_list_wins())
    assert.length(floats, 1, 'only one float')
    local win, buf = editor()
    assert.equals(floats[1], win, 'it is the editor, and current')
    assert.equals(vim.api.nvim_buf_get_name(buf), 'quickfix-review://edit/' .. id, 'for the comment')
    same(vim.api.nvim_get_autocmds({ group = 'QuickfixReviewFloat' }), {}, 'view float handler removed')

    -- Editing it again while it is open goes back to it
    vim.api.nvim_set_current_win(file_win)
    qf.edit_comment()
    assert.equals(vim.api.nvim_get_current_win(), win, 'back in the same editor')
    assert.length(editor_wins(), 1, 'still one editor')
  end)
end)

assert.run_test('editing from the review quickfix row edits that row\'s comment', function()
  qf.clear_review()
  vim.fn.cursor(2, 1)
  qf.add_comment('ISSUE')
  vim.fn.cursor(7, 1)
  qf.add_comment('NOTE')
  with_editor(function()
    qf.show_list()
    vim.cmd('copen')
    vim.fn.cursor(2, 1)
    local row = vim.fn.getqflist()[2]
    local id = row.user_data.id
    qf.edit_comment()
    local _, buf = editor()
    assert.equals(vim.api.nvim_buf_get_name(buf), 'quickfix-review://edit/' .. id, 'the row\'s comment')
    set_lines({ 'From the list' })
    keys('<CR>')
    assert.equals(store.get(id).body, 'From the list', 'that comment edited')
  end)
  vim.cmd('cclose')
  vim.api.nvim_set_current_buf(file_buf)
  local bodies = vim.tbl_map(function(c) return c.body end, qf.comments())
  table.sort(bodies)
  same(bodies, { 'From the list', 'Test comment' }, 'the other comment unchanged')
end)

assert.run_test('a failed save keeps the float open and the text in register "', function()
  qf.clear_review()
  vim.fn.cursor(5, 1)
  qf.add_comment('ISSUE')
  local n = #updates()
  local original = store.edit
  store.edit = function() return nil, 'disk full' end
  local ok, err = pcall(with_editor, function()
    qf.edit_comment()
    local win, buf = editor()
    set_lines({ 'kept', 'here' })
    local calls = capture_notify(function() keys('<CR>') end)
    assert.equals(count_level(calls, vim.log.levels.WARN), 1, 'one warning')
    assert.truthy(calls[1].msg:find('was not edited (disk full)', 1, true), 'gives the reason')
    assert.truthy(vim.api.nvim_win_is_valid(win), 'float still open')
    same(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { 'kept', 'here' }, 'text still there')
    assert.equals(vim.fn.getreg('"'), 'kept\nhere', 'text in register "')
  end)
  store.edit = original
  if not ok then error(err, 0) end
  assert.equals(#updates(), n, 'no update logged')
end)

assert.run_test('the type keys follow the cycle keymaps; one set to false is not mapped', function()
  local config = require('quickfix-review.config')
  local keymaps = config.options.keymaps
  local saved_next = keymaps.cycle_next
  local ok, err = pcall(function()
    qf.clear_review()
    vim.fn.cursor(5, 1)
    qf.add_comment('ISSUE')
    keymaps.cycle_next = false
    with_editor(function()
      qf.edit_comment()
      local win, buf = editor()
      local footer = vim.api.nvim_win_get_config(win).footer[1][1]
      assert.falsy(footer:find('+', 1, true), 'no + in the footer')
      assert.truthy(footer:find('- type', 1, true), '- still named')
      local lhs = {}
      for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do lhs[m.lhs] = true end
      assert.falsy(lhs['+'], 'no buffer-local +')
      assert.truthy(lhs['-'], 'buffer-local -')
    end)
  end)
  keymaps.cycle_next = saved_next
  if not ok then error(err, 0) end
end)

assert.run_test('a type no longer configured is shown as-is; + goes to the first, - to the last', function()
  qf.clear_review()
  store.add({ filename = vim.fn.expand('%:p'), lnum = 5, end_lnum = 5, kind = 'nit', body = 'old type' })
  local types = utils.get_comment_types()
  local ok, err = pcall(function()
    vim.fn.cursor(5, 1)
    with_editor(function()
      qf.edit_comment()
      local win = editor()
      assert.equals(vim.api.nvim_win_get_config(win).title[1][1], ' NIT ', 'shown as it is')
      keys('+')
      assert.equals(vim.api.nvim_win_get_config(win).title[1][1], ' ' .. types[1]:upper() .. ' ', '+ to the first')
    end)
    with_editor(function()
      qf.edit_comment()
      local win = editor()
      keys('-')
      assert.equals(vim.api.nvim_win_get_config(win).title[1][1], ' ' .. types[#types]:upper() .. ' ', '- to the last')
    end)
    -- Its text can still be saved, keeping the type
    local n = #updates()
    with_editor(function()
      qf.edit_comment()
      set_lines({ 'new text' })
      keys('<CR>')
    end)
    local ups = updates()
    assert.equals(#ups, n + 1, 'one update logged')
    same(ups[#ups].set, { body = 'new text' }, 'only the body')
  end)
  if not ok then error(err, 0) end
  local c = qf.comments()[1]
  assert.equals(c.kind, 'nit', 'type kept')
end)

assert.run_test('store.edit: kind alone, with the body, unchanged, unknown and non-string', function()
  qf.clear_review()
  vim.fn.cursor(5, 1)
  qf.add_comment('ISSUE')
  local id = qf.comments()[1].id
  local n = #updates()

  assert.equals(store.edit(id, 'Test comment', 'NOTE'), 'edited', 'kind alone')
  local ups = updates()
  assert.equals(#ups, n + 1, 'one update')
  same(ups[#ups].set, { kind = 'note' }, 'kind stored lowercase, body not set')
  same(ups[#ups].prev, { kind = 'issue' }, 'previous kind')

  assert.equals(store.edit(id, 'Both', 'suggestion'), 'edited', 'body and kind')
  ups = updates()
  assert.equals(#ups, n + 2, 'one more update')
  same(ups[#ups].set, { body = 'Both', kind = 'suggestion' }, 'both in one event')

  assert.equals(store.edit(id, 'Both', 'suggestion'), 'unchanged', 'same body and kind')
  assert.equals(store.edit(id, 'Both'), 'unchanged', 'same body, no kind')
  assert.equals(#updates(), n + 2, 'nothing logged')

  assert.equals(store.edit(id, 'Other', 'nonsense'), nil, 'unknown new kind refused')
  local okc, res = pcall(store.edit, id, 'Other', 42)
  assert.truthy(okc, 'non-string kind does not throw')
  assert.equals(res, nil, 'non-string kind refused')
  assert.equals(#updates(), n + 2, 'nothing logged')
  assert.equals(store.get(id).body, 'Both', 'body unchanged by refused edits')
  assert.equals(store.edit('no-such-id', 'x', 'note'), 'missing', 'missing comment')
end)

assert.run_test('edit on the middle line of a range comment', function()
  qf.clear_review()
  qf.add_comment('ISSUE', { 2, 6 })
  vim.fn.cursor(4, 1)
  with_editor(function()
    qf.edit_comment()
    set_lines({ 'Ranged' })
    keys('<CR>')
  end)
  assert.equals(qf.comments()[1].body, 'Ranged', 'range comment edited')
end)

assert.run_test('edit on a line with no comment opens nothing and logs nothing', function()
  qf.clear_review()
  vim.fn.cursor(5, 1)
  qf.add_comment('ISSUE')
  local n = #updates()
  vim.fn.cursor(8, 1)
  with_editor(function()
    local printed = capture_print(function() qf.edit_comment() end)
    assert.length(editor_wins(), 0, 'no editor')
    assert.equals(printed[1], 'No comment on this line', 'says so')
  end)
  assert.equals(#updates(), n, 'no update logged')
end)

assert.run_test('a comment hidden in a diff buffer: view, edit and delete say so', function()
  qf.clear_review()
  local diff_name = 'diffview:///no-such-repo/.git/abc123/test_file.txt'
  -- A legacy comment: no anchor snapshot, so no diff buffer shows it
  store.add({ filename = '/no-such-repo/test_file.txt', lnum = 2, end_lnum = 2, kind = 'note', body = 'legacy' })
  local miss = 'No comment on this line (diff buffer shows another revision)'
  in_scratch(diff_name, 'nofile', function()
    vim.fn.cursor(2, 1)
    local printed
    printed = capture_print(function() qf.view_comment() end)
    assert.equals(printed[1], miss, 'view says so')
    with_editor(function()
      printed = capture_print(function() qf.edit_comment() end)
      assert.length(editor_wins(), 0, 'edit: no editor')
    end)
    assert.equals(printed[1], miss, 'edit says so')
    printed = capture_print(function() qf.delete_comment() end)
    assert.equals(printed[1], miss, 'delete says so')
  end)
  assert.length(qf.comments(), 1, 'comment still there')
  assert.equals(qf.comments()[1].body, 'legacy', 'body unchanged')

  -- A diff buffer for a file with no comments: the usual message
  qf.clear_review()
  in_scratch(diff_name, 'nofile', function()
    vim.fn.cursor(2, 1)
    local printed = capture_print(function() qf.view_comment() end)
    assert.equals(printed[1], 'No comment on this line', 'generic message')
  end)
end)

assert.run_test('edit with overlapping comments edits only the chosen one', function()
  qf.clear_review()
  qf.add_comment('ISSUE', { 2, 6 })
  vim.fn.cursor(4, 1)
  qf.add_comment('NOTE')
  local original = vim.ui.select
  local offered
  vim.ui.select = function(items, opts, on_choice)
    offered = vim.tbl_map(opts.format_item, items)
    on_choice(items[2])
  end
  local ok, err = pcall(with_editor, function()
    qf.edit_comment()
    local win = editor()
    assert.equals(vim.api.nvim_win_get_config(win).title[1][1], ' NOTE ', 'the chosen comment\'s type')
    set_lines({ 'Chosen' })
    keys('<CR>')
  end)
  vim.ui.select = original
  if not ok then error(err, 0) end

  assert.length(offered, 2, 'both comments offered')
  assert.truthy(offered[1]:find('ISSUE', 1, true), 'range comment first (starts earlier)')
  local by_kind = {}
  for _, c in ipairs(qf.comments()) do by_kind[c.kind] = c.body end
  assert.equals(by_kind.note, 'Chosen', 'chosen comment edited')
  assert.equals(by_kind.issue, 'Test comment', 'other comment unchanged')
end)

assert.run_test('respond sets the response; replacing it keeps the old one in prev', function()
  qf.clear_review()
  vim.fn.cursor(5, 1)
  qf.add_comment('ISSUE')
  local before = vim.deepcopy(qf.comments()[1])
  local n = #updates()

  assert.equals(store.respond(before.id, 'Will fix'), 'responded', 'first response')
  local c = store.get(before.id)
  assert.equals(c.response, 'Will fix', 'response set')
  assert.equals(c.body, before.body, 'body unchanged')
  assert.equals(c.kind, before.kind, 'kind unchanged')
  assert.equals(c.lnum, before.lnum, 'lnum unchanged')
  assert.equals(c.anchor.sha, before.anchor.sha, 'anchor unchanged')
  local ups = updates()
  assert.equals(#ups, n + 1, 'one update logged')
  assert.equals(ups[#ups].id, before.id, 'update names the comment')
  assert.equals(ups[#ups].set.response, 'Will fix', 'update sets the response')
  assert.equals(vim.tbl_count(ups[#ups].set), 1, 'update sets only the response')
  assert.equals(ups[#ups].prev and ups[#ups].prev.response, nil, 'no previous response')

  assert.equals(store.respond(before.id, 'Fixed'), 'responded', 'second response')
  assert.equals(store.get(before.id).response, 'Fixed', 'response replaced')
  ups = updates()
  assert.equals(#ups, n + 2, 'second update logged')
  assert.equals(ups[#ups].prev.response, 'Will fix', 'update keeps the old response')
end)

assert.run_test('respond: same text, unknown id or bad text logs nothing', function()
  qf.clear_review()
  vim.fn.cursor(5, 1)
  qf.add_comment('ISSUE')
  local id = qf.comments()[1].id
  assert.equals(store.respond(id, 'ok'), 'responded', 'first response')
  local n = #updates()
  assert.equals(store.respond(id, 'ok'), 'unchanged', 'same response')
  assert.equals(store.respond('ffffffffffffffff', 'ok'), 'missing', 'unknown id')
  assert.equals(store.respond(id, ''), nil, 'empty text refused')
  assert.equals(store.respond(id, 42), nil, 'non-string text refused')
  assert.equals(store.respond(id, nil), nil, 'nil text refused')
  assert.equals(#updates(), n, 'no update logged')
  assert.equals(store.get(id).response, 'ok', 'response unchanged')
end)

assert.run_test('respond: a multi-line response round-trips', function()
  qf.clear_review()
  vim.fn.cursor(5, 1)
  qf.add_comment('ISSUE')
  local id = qf.comments()[1].id
  local text = 'first line\nsecond | Response: line\n'
  assert.equals(store.respond(id, text), 'responded', 'responded')
  assert.equals(store.get(id).response, text, 'response as given')
  assert.equals(store.reload(), true, 'journal replays')
  assert.equals(store.get(id).response, text, 'response survives a full replay')
end)

test_helper.cleanup_test_environment()

return assert
