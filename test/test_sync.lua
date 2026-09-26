-- Tests for multi-instance sync: another Neovim appends to the same event
-- log, and this one picks the change up on FocusGained, BufEnter, CursorHold
-- and before any change, redrawing the list view and signs only when the
-- review changed
local test_helper = dofile('test/init.lua')
local assert = dofile('test/assertions.lua')
local utils = require('quickfix-review.utils')

print('\nRunning multi-instance sync tests...')

local qf = test_helper.setup_test_environment()
local test_file = test_helper.create_test_file([[
line 1
line 2
line 3
line 4
line 5
]])
local abs = vim.fn.fnamemodify(test_file, ':p')
local file_buf = vim.api.nvim_get_current_buf()
local log_file = test_helper.log_path()

local function reset()
  vim.cmd('silent! cclose')
  vim.fn.setqflist({}, 'f')
  test_helper.remove_storage()
  qf.clear_review()
  vim.api.nvim_set_current_buf(file_buf)
end

-- Run `code` in another headless Neovim on the same review, with `store`
-- bound to its store
local function other(code)
  local result = vim.system({
    vim.v.progpath, '--headless', '--clean',
    '--cmd', 'set rtp^=' .. vim.fn.getcwd(),
    '-c', string.format('lua require("quickfix-review").setup({ storage_file = %q }); '
      .. 'local store = require("quickfix-review.store"); %s', test_helper.storage_file, code),
    '-c', 'qall!',
  }):wait(30000)
  assert.equals(result.code, 0, 'other Neovim exits cleanly: ' .. tostring(result.stderr))
end

local function other_add(lnum, body)
  other(string.format('assert(store.add({ filename = %q, lnum = %d, kind = "note", body = %q }))',
    abs, lnum, body or 'from the other one'))
end

local function has_sign_on_line(lnum)
  return #vim.api.nvim_buf_get_extmarks(file_buf, utils.get_ns_id(), { lnum - 1, 0 }, { lnum - 1, -1 }, {}) > 0
end

-- Run fn with print and vim.notify recorded; returns printed lines, notify calls
local function capture(fn)
  local printed, notified = {}, {}
  local orig_print, orig_notify = print, vim.notify
  print = function(...) table.insert(printed, table.concat(vim.tbl_map(tostring, { ... }), ' ')) end
  vim.notify = function(msg, level) table.insert(notified, { msg = msg, level = level }) end
  local ok, err = pcall(fn)
  print, vim.notify = orig_print, orig_notify
  if not ok then error(err, 0) end
  return printed, notified
end

local function view_tick(id)
  return vim.fn.getqflist({ id = id, changedtick = 0 }).changedtick
end

assert.run_test('a comment added by another Neovim shows on the next BufEnter', function()
  reset()
  assert.length(qf.comments(), 0, 'empty to start')
  qf.show_list()
  local view = vim.fn.getqflist({ id = 0 }).id

  other_add(2)
  assert.falsy(has_sign_on_line(2), 'not seen before any trigger')

  vim.api.nvim_exec_autocmds('BufEnter', { buffer = file_buf })
  assert.truthy(has_sign_on_line(2), 'sign drawn after BufEnter')
  local items = vim.fn.getqflist({ id = view, items = 0 }).items
  assert.length(items, 1, 'list view refreshed')
  assert.equals(items[1].lnum, 2, 'at its line')
  assert.equals(vim.fn.getqflist({ id = 0 }).id, view, 'the view is still the current list')
  reset()
end)

assert.run_test('FocusGained and CursorHold pick up another Neovim\'s change', function()
  for _, event in ipairs({ 'FocusGained', 'CursorHold' }) do
    reset()
    assert.length(qf.comments(), 0, event .. ': empty to start')
    other_add(3)
    assert.falsy(has_sign_on_line(3), event .. ': not seen before the event')
    vim.api.nvim_exec_autocmds(event, {})
    assert.truthy(has_sign_on_line(3), event .. ': sign drawn')
  end
  reset()
end)

assert.run_test('dd on a comment another Neovim deleted is a no-op', function()
  reset()
  vim.fn.cursor(1, 1)
  qf.add_comment('NOTE')
  local id = qf.comments()[1].id
  qf.open_list()
  vim.fn.cursor(1, 1)

  other(string.format('assert(store.remove(%q) == 1)', id))
  local printed, notified = capture(function() qf.delete_comment_from_qf() end)
  assert.truthy(vim.tbl_contains(printed, 'Comment no longer exists'), 'says so: ' .. vim.inspect(printed))
  assert.length(notified, 0, 'no error or warning')
  assert.length(test_helper.log_ops(log_file, 'delete'), 1, 'only the other one\'s delete is logged')
  assert.length(vim.fn.getqflist(), 0, 'the view no longer lists it')
  reset()
end)

assert.run_test(':ReviewEdit on a comment another Neovim deleted says so and logs nothing', function()
  reset()
  vim.fn.cursor(2, 1)
  qf.add_comment('NOTE')
  local id = qf.comments()[1].id
  local original = vim.ui.input
  -- Deleted elsewhere while the prompt is open
  vim.ui.input = function(_, on_confirm)
    other(string.format('assert(store.remove(%q) == 1)', id))
    on_confirm('too late')
  end
  local ok, printed, notified = pcall(capture, function() qf.edit_comment() end)
  vim.ui.input = original
  if not ok then error(printed, 0) end
  assert.truthy(vim.tbl_contains(printed, 'Comment no longer exists'), 'says so: ' .. vim.inspect(printed))
  assert.length(notified, 0, 'no error or warning')
  assert.length(test_helper.log_ops(log_file, 'update'), 0, 'no update logged')
  reset()
end)

assert.run_test(':ReviewDelete on a comment another Neovim deleted is a no-op', function()
  reset()
  vim.fn.cursor(2, 1)
  qf.add_comment('NOTE')
  local id = qf.comments()[1].id

  other(string.format('assert(store.remove(%q) == 1)', id))
  local printed, notified = capture(function() qf.delete_comment() end)
  assert.truthy(printed[1] and printed[1]:match('^No comments found'), 'says so: ' .. vim.inspect(printed))
  assert.length(notified, 0, 'no error or warning')
  assert.length(test_helper.log_ops(log_file, 'delete'), 1, 'only the other one\'s delete is logged')
  assert.falsy(has_sign_on_line(2), 'its sign is gone')
  reset()
end)

assert.run_test('a sync that finds nothing new does not rebuild the list view', function()
  reset()
  vim.fn.cursor(1, 1)
  qf.add_comment('NOTE')
  qf.show_list()
  local view = vim.fn.getqflist({ id = 0 }).id
  local tick = view_tick(view)
  for _, event in ipairs({ 'FocusGained', 'CursorHold', 'BufEnter' }) do
    vim.api.nvim_exec_autocmds(event, { buffer = event == 'BufEnter' and file_buf or nil })
  end
  qf.comments()
  assert.equals(view_tick(view), tick, 'changedtick unchanged')
  assert.equals(vim.fn.getqflist({ id = 0 }).id, view, 'same list')
  reset()
end)

assert.run_test('a synced change keeps the selected entry and opens no window', function()
  reset()
  vim.fn.cursor(3, 1)
  qf.add_comment('NOTE')
  vim.fn.cursor(4, 1)
  qf.add_comment('NOTE')
  qf.show_list()
  local view = vim.fn.getqflist({ id = 0 }).id
  vim.fn.setqflist({}, 'a', { id = view, idx = 2 })
  local selected = vim.fn.getqflist({ id = view, idx = 0, items = 0 })
  local selected_id = selected.items[selected.idx].user_data.id
  local win = vim.api.nvim_get_current_win()
  local wins = #vim.api.nvim_list_wins()

  -- Added before both: the selected comment moves to the third row
  other_add(1)
  vim.api.nvim_exec_autocmds('CursorHold', {})
  local after = vim.fn.getqflist({ id = view, idx = 0, items = 0 })
  assert.length(after.items, 3, 'refreshed')
  assert.equals(after.items[after.idx].user_data.id, selected_id, 'the same comment is selected')
  assert.equals(vim.api.nvim_get_current_win(), win, 'focus kept')
  assert.equals(#vim.api.nvim_list_wins(), wins, 'no window opened')
  reset()
end)

assert.run_test('a rotation by another Neovim leaves comments, signs and trash as they were', function()
  reset()
  vim.fn.cursor(1, 1)
  qf.add_comment('NOTE')
  vim.fn.cursor(3, 1)
  qf.add_comment('ISSUE')
  vim.fn.cursor(5, 1)
  qf.add_comment('NOTE')
  qf.delete_comment({ 3, 3 })
  local store = require('quickfix-review.store')
  local before = vim.tbl_map(function(c) return c.id end, qf.comments())
  local trashed = vim.tbl_keys(store.trash())
  local ino = vim.uv.fs_stat(log_file).ino

  -- The other one rotates with its tiny limit, on a change that changes nothing
  -- here (an edit to the same body is not logged, so edit to another and back)
  other(string.format('require("quickfix-review.config").options.log_max_bytes = 1; '
    .. 'assert(store.edit(%q, "tmp") == "edited")', before[1]))
  other(string.format('assert(store.edit(%q, "Test comment") == "edited")', before[1]))
  assert.truthy(#vim.fn.glob(test_helper.storage_file .. '.log.*.jsonl', true, true) >= 1, 'rotated')
  assert.not_equals(vim.uv.fs_stat(log_file).ino, ino, 'a new log')

  local _, notified = capture(function() vim.api.nvim_exec_autocmds('CursorHold', {}) end)
  local errors = vim.tbl_filter(function(n) return n.level == vim.log.levels.ERROR end, notified)
  assert.length(errors, 0, 'no error: ' .. vim.inspect(notified))
  local after = vim.tbl_map(function(c) return c.id end, qf.comments())
  assert.equals(table.concat(after, ','), table.concat(before, ','), 'same comments')
  assert.equals(qf.comments()[1].body, 'Test comment', 'the latest body')
  assert.truthy(has_sign_on_line(1) and has_sign_on_line(5), 'signs kept')
  assert.falsy(has_sign_on_line(3), 'the deleted one has none')
  assert.truthy(vim.deep_equal(vim.tbl_keys(store.trash()), trashed), 'same trash')
  reset()
end)

assert.run_test('a log rewritten in place with another log_id is replayed from the start', function()
  reset()
  vim.fn.cursor(1, 1)
  qf.add_comment('NOTE')
  assert.length(qf.comments(), 1, 'one comment')
  local ino = vim.uv.fs_stat(log_file).ino

  -- Same inode, a new header, and longer than what was read
  local log = require('quickfix-review.log')
  local lines = { vim.json.encode(log.new_header()) }
  for i = 1, 3 do
    table.insert(lines, vim.json.encode(log.event('add', { comment = {
      id = string.format('%016x', i), kind = 'issue', filename = abs, lnum = i + 1, body = 'rotated ' .. i,
      created_at = os.time(),
    } })))
  end
  local f = io.open(log_file, "w")
  assert.truthy(f, "log opened for writing")
  f:write(table.concat(lines, '\n') .. '\n')
  f:close()
  assert.equals(vim.uv.fs_stat(log_file).ino, ino, 'same inode')

  vim.api.nvim_exec_autocmds('CursorHold', {})
  local list = qf.comments()
  assert.length(list, 3, 'only the new log\'s comments')
  assert.equals(list[1].body, 'rotated 1', 'from the new log')
  assert.falsy(has_sign_on_line(1), 'the old comment\'s sign is gone')
  reset()
end)

assert.run_test('a log rewritten in place to the same size with another log_id is replayed', function()
  reset()
  vim.fn.cursor(1, 1)
  qf.add_comment('NOTE')
  assert.length(qf.comments(), 1, 'one comment')
  local fh = io.open(log_file, 'rb')
  local old = fh:read('*a')
  fh:close()

  -- A new header log_id and another body, both of the same length
  local old_id = old:match('"log_id":"(%x+)"')
  local new_id = require('quickfix-review.log').new_header().log_id
  assert.equals(#new_id, #old_id, 'log_ids of one length')
  local new = old:gsub(old_id, new_id, 1):gsub('"body":"([^"]*)"', function(b)
    return '"body":"' .. string.rep('z', #b) .. '"'
  end)
  assert.equals(#new, #old, 'same size')
  fh = io.open(log_file, 'r+b')
  fh:write(new)
  fh:close()

  vim.api.nvim_exec_autocmds('CursorHold', {})
  local list = qf.comments()
  assert.length(list, 1, 'one comment')
  assert.truthy(list[1].body:match('^z+$'), 'the new log\'s comment: ' .. list[1].body)
  reset()
end)

local FIVE = { 'line 1', 'line 2', 'line 3', 'line 4', 'line 5' }

local function outdated_sign_on_line(lnum)
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(file_buf, utils.get_ns_id(),
      { lnum - 1, 0 }, { lnum - 1, -1 }, { details = true })) do
    if m[4].sign_hl_group == utils.OUTDATED_HL then return true end
  end
  return false
end

-- The other Neovim opens the test file and re-anchors the comment on line 2
local function other_reanchor()
  other(string.format('vim.cmd("edit " .. vim.fn.fnameescape(%q)); vim.fn.cursor(2, 1); '
    .. 'require("quickfix-review").reanchor(); '
    .. 'assert(store.pos(store.all()[1]).state == "current", "re-anchored there")', abs))
end

assert.run_test('an anchor update from another Neovim clears the outdated state here', function()
  reset()
  vim.fn.cursor(2, 1)
  qf.add_comment('ISSUE')
  local lines = vim.deepcopy(FIVE)
  lines[2] = 'line 2 rewritten'
  local ok, err = pcall(function()
    vim.fn.writefile(lines, abs)
    vim.cmd('silent edit!')
    assert.equals(require('quickfix-review.store').pos(qf.comments()[1]).state, 'outdated', 'outdated first')
    assert.truthy(outdated_sign_on_line(2), 'outdated sign first')

    other_reanchor()
    vim.api.nvim_exec_autocmds('CursorHold', {})
    local c = qf.comments()[1]
    assert.equals(c.anchor.lnum, 2, 'synced anchor')
    assert.equals(require('quickfix-review.store').pos(c).state, 'current', 'current after the sync')
    assert.truthy(has_sign_on_line(2), 'sign on line 2')
    assert.falsy(outdated_sign_on_line(2), 'sign no longer outdated')
  end)
  vim.fn.writefile(FIVE, abs)
  vim.api.nvim_set_current_buf(file_buf)
  vim.cmd('silent edit!')
  reset()
  if not ok then error(err, 0) end
end)

assert.run_test('an anchor update from another Neovim clears the outdated state of an unloaded file', function()
  reset()
  vim.fn.cursor(2, 1)
  qf.add_comment('ISSUE')
  local store = require('quickfix-review.store')
  local lines = vim.deepcopy(FIVE)
  lines[2] = 'line 2 rewritten'
  -- Named, so :edit below doesn't reuse it for the file
  local scratch = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_buf_set_name(scratch, 'sync-scratch')
  local ok, err = pcall(function()
    vim.api.nvim_set_current_buf(scratch)
    vim.cmd('bwipeout ' .. file_buf)
    vim.fn.writefile(lines, abs)
    -- Relocated from disk: caches the outdated pos for this file's content
    assert.equals(store.pos(qf.comments()[1]).state, 'outdated', 'outdated from disk first')

    other_reanchor()
    vim.api.nvim_exec_autocmds('CursorHold', {})
    local c = qf.comments()[1]
    assert.equals(store.pos(c).state, 'current', 'current from disk after the sync')
    assert.equals((store.range(c)), 2, 'line 2')
  end)
  vim.fn.writefile(FIVE, abs)
  vim.cmd('edit ' .. vim.fn.fnameescape(abs))
  file_buf = vim.api.nvim_get_current_buf()
  vim.cmd('bwipeout! ' .. scratch)
  reset()
  if not ok then error(err, 0) end
end)

assert.run_test('a snapshot another Neovim wrote, before its event is appended, survives GC here', function()
  reset()
  local store = require('quickfix-review.store')
  local snapshots = require('quickfix-review.snapshots')
  other_add(1) -- the review's log exists
  local lines = { 'written by the other one', 'no event yet' }
  other(string.format('assert(require("quickfix-review.snapshots").put(%s))', vim.inspect(lines)))
  local path = store.snapshots_dir() .. '/' .. snapshots.hash(lines)
  assert.truthy(vim.uv.fs_stat(path), 'written')
  store.gc_snapshots()
  assert.truthy(vim.uv.fs_stat(path), 'fresh: kept')

  -- An old one the other Neovim puts again (about to reference it) is touched
  local day_ago = os.time() - 25 * 3600
  vim.uv.fs_utime(path, day_ago, day_ago)
  other(string.format('assert(require("quickfix-review.snapshots").put(%s))', vim.inspect(lines)))
  store.gc_snapshots()
  assert.truthy(vim.uv.fs_stat(path), 'touched by the put: kept')

  -- Untouched, it goes
  vim.uv.fs_utime(path, day_ago, day_ago)
  assert.equals(store.gc_snapshots(), 1, 'collected once old')
  assert.falsy(vim.uv.fs_stat(path), 'deleted')
end)

test_helper.cleanup_test_environment()

return assert
