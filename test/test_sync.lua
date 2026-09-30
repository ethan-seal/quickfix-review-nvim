-- Tests for multi-instance sync: another Neovim appends to the same event
-- log, and this one picks the change up on FocusGained, BufEnter, CursorHold
-- and before any change, redrawing the list view and signs only when the
-- review changed
local test_helper = dofile((vim.env.QFR_TEST_ROOT or '.') .. '/test/init.lua')
local assert = dofile(test_helper.root .. '/test/assertions.lua')
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
local log_file = test_helper.segment_path(1)

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
    '--cmd', 'set rtp^=' .. test_helper.root,
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
  -- The list is refilled after the enter (a quickfix jump may be under way)
  vim.wait(100, function() return #vim.fn.getqflist({ id = view, items = 0 }).items > 0 end)
  local items = vim.fn.getqflist({ id = view, items = 0 }).items
  assert.length(items, 1, 'list view refreshed')
  assert.equals(items[1].lnum, 2, 'at its line')
  assert.equals(vim.fn.getqflist({ id = 0 }).id, view, 'the view is still the current list')
  reset()
end)

assert.run_test('DirChanged from autochdir refills the list after the event, :cd at once', function()
  reset()
  qf.show_list()
  local view = vim.fn.getqflist({ id = 0 }).id

  -- 'autochdir' fires inside a quickfix jump: the refill waits
  other_add(2)
  local tick = view_tick(view)
  vim.api.nvim_exec_autocmds('DirChanged', { pattern = 'auto' })
  assert.truthy(has_sign_on_line(2), 'auto: sign drawn at once')
  assert.equals(view_tick(view), tick, 'auto: list not refilled during the event')
  vim.wait(100, function() return #vim.fn.getqflist({ id = view, items = 0 }).items > 0 end)
  assert.length(vim.fn.getqflist({ id = view, items = 0 }).items, 1, 'auto: list refilled after')

  -- :cd refills straight away
  other_add(4)
  vim.api.nvim_exec_autocmds('DirChanged', { pattern = 'global' })
  assert.length(vim.fn.getqflist({ id = view, items = 0 }).items, 2, 'global: list refilled at once')
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

assert.run_test('a sync that finds nothing new stats only the active segment and the next', function()
  reset()
  vim.fn.cursor(1, 1)
  qf.add_comment('NOTE')
  qf.comments()
  local stats = {}
  local orig = vim.uv.fs_stat
  vim.uv.fs_stat = function(path, ...)
    table.insert(stats, path)
    return orig(path, ...)
  end
  local ok, err = pcall(qf.comments)
  vim.uv.fs_stat = orig
  if not ok then error(err, 0) end
  assert.length(stats, 2, 'two stats: ' .. table.concat(stats, ', '))
  assert.equals(stats[1], log_file, 'of the active segment')
  assert.equals(stats[2], test_helper.segment_path(2), 'and of the next, which would seal it')
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

assert.run_test('sealing by another Neovim leaves comments, signs and trash as they were', function()
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

  -- The other one seals with its tiny limit, on a change that changes
  -- nothing here (an edit to the same body is not logged, so edit to
  -- another and back): each change seals the segment it lands in
  local seal = 'require("quickfix-review.config").options.segment_max_bytes = 1; '
  other(seal .. string.format('assert(store.edit(%q, "tmp") == "edited")', before[1]))
  other(seal .. string.format('assert(store.edit(%q, "Test comment") == "edited")', before[1]))
  assert.truthy(vim.uv.fs_stat(test_helper.segment_path(3)) ~= nil, 'sealed twice')
  assert.equals(vim.uv.fs_stat(log_file).ino, ino, 'segment 1 is the same file')
  assert.truthy(vim.uv.fs_stat(test_helper.events_path() .. '/000002.refs') ~= nil, 'sealed with its refs')

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

assert.run_test('a journal replaced by another one (a new segment 1) is loaded from the start', function()
  reset()
  vim.fn.cursor(1, 1)
  qf.add_comment('NOTE')
  assert.length(qf.comments(), 1, 'one comment')
  local ino = vim.uv.fs_stat(log_file).ino

  -- Another journal (as if the review's files were restored from elsewhere):
  -- a new file, so a new inode
  local log = require('quickfix-review.log')
  local lines = { vim.json.encode(log.segment_header(log.new_journal_id(), 1)) }
  for i = 1, 3 do
    table.insert(lines, vim.json.encode(log.event('add', { comment = {
      id = string.format('%016x', i), kind = 'issue', filename = abs, lnum = i + 1, body = 'replaced ' .. i,
      created_at = os.time(),
    } })))
  end
  local tmp = log_file .. '.new'
  vim.fn.writefile(lines, tmp)
  assert.truthy(vim.uv.fs_rename(tmp, log_file), 'replaced')
  assert.not_equals(vim.uv.fs_stat(log_file).ino, ino, 'another inode')

  vim.api.nvim_exec_autocmds('CursorHold', {})
  local list = qf.comments()
  assert.length(list, 3, 'only the new journal\'s comments')
  assert.equals(list[1].body, 'replaced 1', 'from the new journal')
  assert.falsy(has_sign_on_line(1), 'the old comment\'s sign is gone')
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
  store.gc_snapshots({ force = true })
  assert.truthy(vim.uv.fs_stat(path), 'fresh: kept')

  -- An old one the other Neovim puts again (about to reference it) is touched
  local day_ago = os.time() - 25 * 3600
  vim.uv.fs_utime(path, day_ago, day_ago)
  other(string.format('assert(require("quickfix-review.snapshots").put(%s))', vim.inspect(lines)))
  store.gc_snapshots({ force = true })
  assert.truthy(vim.uv.fs_stat(path), 'touched by the put: kept')

  -- Untouched, it goes
  vim.uv.fs_utime(path, day_ago, day_ago)
  assert.equals(store.gc_snapshots({ force = true }), 1, 'collected once old')
  assert.falsy(vim.uv.fs_stat(path), 'deleted')
end)

assert.run_test('two BufEnters 50 ms apart read the journal once; FocusGained still reads', function()
  reset()
  vim.fn.cursor(1, 1)
  qf.add_comment('NOTE')
  qf.comments()
  local events_dir = test_helper.events_path()
  local stats = {}
  local orig = vim.uv.fs_stat
  vim.uv.fs_stat = function(path, ...)
    if type(path) == 'string' and path:sub(1, #events_dir) == events_dir then table.insert(stats, path) end
    return orig(path, ...)
  end
  local ok, err = pcall(function()
    vim.api.nvim_exec_autocmds('BufEnter', { buffer = file_buf })
    vim.wait(50)
    vim.api.nvim_exec_autocmds('BufEnter', { buffer = file_buf })
    assert.length(stats, 2, 'one sync (active segment and the next): ' .. table.concat(stats, ', '))
    vim.api.nvim_exec_autocmds('FocusGained', {})
    assert.length(stats, 4, 'FocusGained is not debounced: ' .. table.concat(stats, ', '))
  end)
  vim.uv.fs_stat = orig
  if not ok then error(err, 0) end
  reset()
end)

-- A repo with file.txt committed twice (so HEAD~1 exists and its diff has a
-- hunk at line 2); returns its dir and the file's path
local function repo_file()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  local function git(...)
    local r = vim.system(vim.list_extend({ 'git', '-C', dir, '-c', 'user.name=T', '-c', 'user.email=t@x',
      '-c', 'commit.gpgsign=false' }, { ... }), { text = true }):wait()
    assert.equals(r.code, 0, 'git ' .. table.concat({ ... }, ' ') .. ': ' .. tostring(r.stderr))
  end
  git('init', '-q')
  vim.fn.writefile({ 'a', 'b', 'c' }, dir .. '/file.txt')
  git('add', 'file.txt')
  git('commit', '-q', '-m', 'one')
  vim.fn.writefile({ 'a', 'changed', 'c' }, dir .. '/file.txt')
  git('commit', '-q', '-am', 'two')
  return dir, dir .. '/file.txt'
end

-- Run fn with the context's background git calls (rev-parse HEAD, diff)
-- answering 1 s late; fn gets a function returning how many answered
local function with_slow_git(fn)
  local real = vim.system
  local answered = 0
  vim.system = function(cmd, opts, on_exit)
    if on_exit and cmd[1] == 'git' and (vim.tbl_contains(cmd, 'HEAD') or vim.tbl_contains(cmd, 'diff')) then
      return real(cmd, opts, function(r)
        vim.schedule(function()
          vim.defer_fn(function()
            answered = answered + 1
            on_exit(r)
          end, 1000)
        end)
      end)
    end
    return real(cmd, opts, on_exit)
  end
  local ok, err = pcall(fn, function() return answered end)
  vim.system = real
  if not ok then error(err, 0) end
end

assert.run_test('add_comment does not wait for git; the context is logged by an update', function()
  reset()
  local dir, file = repo_file()
  local buf = vim.fn.bufadd(file)
  vim.fn.bufload(buf)
  vim.api.nvim_set_current_buf(buf)
  with_slow_git(function(answered)
    vim.fn.cursor(2, 1)
    local t0 = vim.uv.hrtime()
    qf.add_comment('NOTE')
    local ms = (vim.uv.hrtime() - t0) / 1e6
    assert.truthy(ms < 100, 'returns in under 100 ms, took ' .. ms)
    local c = qf.comments()[1]
    assert.truthy(c, 'added')
    assert.equals(c.context.snippet_source, 'buffer', 'the buffer snippet for now')
    assert.falsy(c.context.commit, 'no commit yet')
    assert.length(test_helper.log_ops(log_file, 'update'), 0, 'no update yet')

    assert.truthy(vim.wait(5000, function()
      local now = qf.comments()[1]
      return now and now.context.commit ~= nil
    end, 20), 'the commit appears on the record')
    local now = qf.comments()[1]
    assert.equals(now.context.snippet_source, 'diff', 'the diff snippet')
    assert.contains(now.context.snippet, '+changed', 'hunk of the change')
    assert.equals(answered(), 2, 'rev-parse and diff HEAD~1 (no fallback to HEAD)')
    local updates = test_helper.log_ops(log_file, 'update')
    assert.length(updates, 1, 'one update')
    assert.equals(updates[1].id, now.id, 'of the comment')
    assert.truthy(updates[1].set and updates[1].set.context, 'setting the context')
  end)
  vim.api.nvim_set_current_buf(file_buf)
  vim.api.nvim_buf_delete(buf, { force = true })
  vim.fn.delete(dir, 'rf')
  reset()
end)

assert.run_test('a context git finds after the review switched is not logged in either review', function()
  reset()
  local config = require('quickfix-review.config')
  local dir, file = repo_file()
  local buf = vim.fn.bufadd(file)
  vim.fn.bufload(buf)
  vim.api.nvim_set_current_buf(buf)
  local other_file = vim.fn.tempname() .. '-other-review.json'
  local original = config.options.storage_file
  local ok, err = pcall(with_slow_git, function(answered)
    vim.fn.cursor(2, 1)
    qf.add_comment('NOTE')
    assert.length(qf.comments(), 1, 'added')
    config.options.storage_file = other_file
    assert.length(qf.comments(), 0, 'the other review is empty')
    assert.truthy(vim.wait(5000, function() return answered() >= 2 end, 20), 'git answered')
    -- Let the scheduled callbacks run
    vim.wait(200)
    config.options.storage_file = original
    assert.length(test_helper.log_ops(log_file, 'update'), 0, 'no update in the first review')
    assert.falsy(qf.comments()[1].context.commit, 'its comment keeps the buffer context')
    assert.falsy(vim.uv.fs_stat(test_helper.events_path(other_file)), 'nothing written to the other review')
  end)
  config.options.storage_file = original
  test_helper.remove_storage(other_file)
  vim.api.nvim_set_current_buf(file_buf)
  vim.api.nvim_buf_delete(buf, { force = true })
  vim.fn.delete(dir, 'rf')
  if not ok then error(err, 0) end
  reset()
end)

test_helper.cleanup_test_environment()

return assert
