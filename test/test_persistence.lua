-- Tests for persistence: the review lives in the plugin, every change is
-- appended to its event log on disk, and the quickfix list is only a view of it
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
local log_file = test_helper.log_path()

local function reset()
  vim.fn.setqflist({}, 'f')
  test_helper.remove_storage()
  qf.clear_review()
end

-- The live comments in the log of `path` (default: the test storage file)
local function saved(path)
  return test_helper.saved(test_helper.log_path(path))
end

-- A version 2 file holding these comments
local function envelope(list)
  return vim.json.encode({ version = 2, comments = list })
end

-- Simulate quitting and reopening Neovim: drop every module and set up again.
-- Quitting writes the cache (VimLeavePre), unless opts.no_flush.
local function restart(path, opts)
  if not (opts and opts.no_flush) and package.loaded['quickfix-review.store'] then
    package.loaded['quickfix-review.store'].flush()
  end
  for name, _ in pairs(package.loaded) do
    if name:match('^quickfix%-review') then package.loaded[name] = nil end
  end
  local fresh = require('quickfix-review')
  fresh.setup({ storage_file = path or storage_file })
  return fresh
end

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

local function errors_mentioning(calls, text)
  local found = {}
  for _, c in ipairs(calls) do
    if c.level == vim.log.levels.ERROR and c.msg:find(text, 1, true) then table.insert(found, c) end
  end
  return found
end

local function read_bytes(path)
  local fh = io.open(path, 'rb')
  assert.truthy(fh, 'can open ' .. path)
  local content = fh:read('*a')
  fh:close()
  return content
end

assert.run_test('every change is written through to disk', function()
  reset()
  vim.fn.cursor(3, 1)
  qf.add_comment('ISSUE')

  local list = saved()
  assert.length(list, 1, 'comment saved without calling save_review')
  assert.equals(list[1].lnum, 3, 'correct line number')
  assert.equals(list[1].kind, 'issue', 'correct comment type')

  qf.delete_comment({ 3, 3 })
  assert.length(saved(), 0, 'deletion saved')
  assert.length(test_helper.log_ops(log_file, 'delete'), 1, 'as a delete event')
  assert.equals(vim.fn.filereadable(storage_file), 0, 'no comments.json written')
  assert.equals(vim.fn.glob(storage_file .. '*.tmp.*'), '', 'no temp files left behind')
  assert.equals(vim.fn.isdirectory(test_helper.lock_path()), 0, 'no lock left behind')
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
  assert.equals(list[1].kind, 'issue', 'first comment intact')
  assert.equals(list[2].kind, 'note', 'second comment intact')
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

  -- Another Neovim appends to the log
  local log = require('quickfix-review.log')
  assert.truthy(log.append(log_file, { log.event('add', { comment = {
    id = '00000000000000e1', filename = vim.fn.fnamemodify(test_file, ':p'), lnum = 4, end_lnum = 4,
    kind = 'note', body = 'from elsewhere', created_at = 1700000000,
  } }) }), 'appended')

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
  assert.length(test_helper.log_ops(log_file, 'clear'), 1, 'as a clear event')
  qf = restart()
  assert.length(qf.comments(), 0, 'still cleared after restart')
  local trash = vim.tbl_values(require('quickfix-review.store').trash())
  assert.length(trash, 1, 'the cleared comment is in the trash')
  assert.equals(trash[1].kind, 'issue', 'with its content')
end)

assert.run_test('an unreadable file is not overwritten', function()
  reset()
  vim.fn.writefile({ 'not json' }, storage_file)

  local calls = capture_notify(function()
    vim.fn.cursor(1, 1)
    qf.add_comment('ISSUE')
    qf.add_comment('NOTE')
    qf.comments()
  end)

  assert.equals(vim.fn.readfile(storage_file)[1], 'not json', 'file untouched')
  assert.equals(vim.fn.filereadable(log_file), 0, 'no log written')
  assert.equals(vim.fn.filereadable(storage_file .. '.pre-log.bak'), 0, 'not moved aside')
  assert.length(errors_mentioning(calls, storage_file), 1, 'reported exactly once, with the path')
  assert.length(errors_mentioning(calls, 'will not be modified'), 1, 'says the file will not be modified')
end)

assert.run_test('a failed save leaves the file intact', function()
  local uv = vim.uv or vim.loop
  if uv.getuid and uv.getuid() == 0 then
    print('  (skipped: running as root ignores directory permissions)')
    return
  end

  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  local path = dir .. '/review.json'
  -- A version 2 comment with an id and a creation time, so loading doesn't rewrite it
  local seed = envelope({
    { id = '0123456789abcdef', filename = vim.fn.fnamemodify(test_file, ':p'), lnum = 2, end_lnum = 2,
      kind = 'note', body = 'seeded', created_at = 1700000000 },
  })
  local fh = io.open(path, 'w')
  fh:write(seed)
  fh:close()

  local log_path = test_helper.log_path(path)

  local ok, err = pcall(function()
    qf = restart(path)
    assert.equals(read_bytes(path .. '.pre-log.bak'), seed, 'migrated, original kept')
    local logged = read_bytes(log_path)
    vim.fn.setfperm(dir, 'r-xr-xr-x')

    local calls = capture_notify(function()
      vim.fn.cursor(1, 1)
      qf.add_comment('ISSUE')
    end)

    assert.equals(read_bytes(log_path), logged, 'log byte-identical')
    assert.truthy(#errors_mentioning(calls, path) >= 1, 'error notified with the path')
    assert.equals(vim.fn.glob(path .. '.tmp.*'), '', 'no temp files left behind')
    local list = qf.comments()
    assert.length(list, 1, 'failed change not kept in memory')
    assert.equals(list[1].body, 'seeded', 'memory matches disk')

    vim.fn.setfperm(dir, 'rwxr-xr-x')
    vim.fn.cursor(3, 1)
    qf.add_comment('ISSUE')
    local on_disk = saved(path)
    assert.length(on_disk, 2, 'saving works again once writable')
    assert.equals(vim.fn.glob(path .. '.tmp.*'), '', 'no temp files after recovering')
  end)

  vim.fn.setfperm(dir, 'rwxr-xr-x')
  qf = restart()
  vim.fn.delete(dir, 'rf')
  if not ok then error(err, 0) end
end)

-- Run fn with print replaced by a recorder; returns the printed lines
local function capture_print(fn)
  local lines = {}
  local original = _G.print
  _G.print = function(...)
    local parts = {}
    for i = 1, select('#', ...) do parts[i] = tostring((select(i, ...))) end
    table.insert(lines, table.concat(parts, ' '))
  end
  local ok, err = pcall(fn)
  _G.print = original
  if not ok then error(err, 0) end
  return lines
end

local function any_mentions(list, text)
  for _, s in ipairs(list) do
    if (type(s) == 'table' and s.msg or s):find(text, 1, true) then return true end
  end
  return false
end

assert.run_test('an add into a read-only storage dir is not reported as added', function()
  local uv = vim.uv or vim.loop
  if uv.getuid and uv.getuid() == 0 then
    print('  (skipped: running as root ignores directory permissions)')
    return
  end

  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  local path = dir .. '/review.json'

  local ok, err = pcall(function()
    qf = restart(path)
    vim.fn.cursor(1, 1)
    qf.add_comment('NOTE')
    assert.length(qf.comments(), 1, 'seeded while writable')
    vim.fn.setfperm(dir, 'r-xr-xr-x')

    local store = require('quickfix-review.store')
    local added, printed
    local calls = capture_notify(function()
      added = store.add({ filename = test_file, kind = 'note', body = 'direct', lnum = 2, end_lnum = 2 })
      vim.fn.cursor(3, 1)
      printed = capture_print(function() qf.add_comment('ISSUE') end)
    end)

    assert.equals(added, false, 'store.add returns false')
    assert.falsy(any_mentions(printed, 'added'), 'no "added" message: ' .. vim.inspect(printed))
    assert.truthy(#errors_mentioning(calls, dir) >= 1, 'error notified with the path')
    assert.truthy(any_mentions(calls, 'ISSUE comment was not added'), 'add_comment warns instead')
    assert.length(qf.comments(), 1, 'count unchanged')
    assert.length(saved(path), 1, 'nothing written')
  end)

  vim.fn.setfperm(dir, 'rwxr-xr-x')
  qf = restart()
  vim.fn.delete(dir, 'rf')
  if not ok then error(err, 0) end
end)

assert.run_test('a failed log append is reported as a failure by every change', function()
  reset()
  vim.fn.cursor(2, 1)
  qf.add_comment('ISSUE')
  assert.length(qf.comments(), 1, 'seeded')

  local store = require('quickfix-review.store')
  local log = require('quickfix-review.log')
  local original_append = log.append
  log.append = function() return false, 'short write (0 of 10 bytes)' end

  local ok, err = pcall(function()
    local added, removed, updated, edited, cleared, printed
    local calls = capture_notify(function()
      added = store.add({ filename = test_file, kind = 'note', body = 'direct', lnum = 4, end_lnum = 4 })
      local c = qf.comments()[1]
      updated = store.update({ { id = c.id, anchor = { sha = string.rep('a', 64), lnum = 5, end_lnum = 5 } } })
      edited = store.edit(c.id, 'not saved')
      cleared = store.clear()
      removed = store.remove(c.id)
      printed = capture_print(function()
        vim.fn.cursor(2, 1)
        local original_input = vim.ui.input
        vim.ui.input = function(_, on_confirm) on_confirm('edited body') end
        local eok, eerr = pcall(qf.edit_comment)
        vim.ui.input = original_input
        if not eok then error(eerr, 0) end
        vim.fn.cursor(4, 1)
        qf.add_comment('NOTE')
        qf.delete_comment({ 2, 2 })
      end)
    end)

    assert.equals(added, false, 'add returns false')
    assert.equals(updated, nil, 'update returns nil')
    assert.equals(edited, nil, 'edit returns nil')
    assert.falsy(any_mentions(printed, 'edited'), 'no "edited" message: ' .. vim.inspect(printed))
    assert.truthy(any_mentions(calls, 'the comment was not edited'), 'edit reports the failure')
    assert.equals(qf.comments()[1].body, 'Test comment', 'body unchanged')
    assert.equals(cleared, nil, 'clear returns nil')
    assert.equals(removed, nil, 'remove returns nil')
    assert.falsy(any_mentions(printed, 'added'), 'no "added" message: ' .. vim.inspect(printed))
    assert.falsy(any_mentions(printed, 'Deleted'), 'no "Deleted" message: ' .. vim.inspect(printed))
    assert.truthy(#errors_mentioning(calls, 'short write') >= 1, 'the write error is notified')
    assert.truthy(any_mentions(calls, 'no comment was deleted'), 'delete reports the failure')
    local list = qf.comments()
    assert.length(list, 1, 'comment still listed')
    assert.equals(list[1].lnum, 2, 'not re-anchored')
    assert.length(saved(), 1, 'log unchanged')
  end)

  log.append = original_append
  if not ok then error(err, 0) end
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
  assert.equals(list[1].kind, 'issue', 'the selected comment was deleted')
  assert.length(saved(), 1, 'deletion saved')
end)

-- Write raw JSON to the storage file, as an older version or another tool would
local function seed_legacy(json)
  vim.fn.setqflist({}, 'f')
  test_helper.remove_storage()
  local fh = io.open(storage_file, 'w')
  fh:write(json)
  fh:close()
  qf = restart()
end

local function export_markdown()
  local config = require('quickfix-review.config')
  local content, err = require('quickfix-review.export').to_markdown(qf.comments(), config.options)
  assert.truthy(content, 'export succeeds: ' .. tostring(err))
  return content
end

assert.run_test('legacy end_lnum = 0 loads as a single line', function()
  local abs = vim.fn.fnamemodify(test_file, ':p')
  seed_legacy(string.format(
    '[{"filename":%q,"lnum":5,"end_lnum":0,"col":1,"text":"[ISSUE] legacy"}]', abs))

  assert.equals(qf.comments()[1].end_lnum, 5, 'end_lnum clamped to lnum')

  vim.cmd('edit ' .. test_file)
  local ok, err = pcall(vim.cmd, 'doautocmd BufEnter')
  assert.truthy(ok, 'BufEnter does not error: ' .. tostring(err))

  local md = export_markdown()
  assert.truthy(md:find('test_file.txt:5`', 1, true), 'export shows :5')
  assert.falsy(md:find(':5-0', 1, true), 'export does not show :5-0')

  qf.delete_comment({ 5, 5 })
  assert.length(qf.comments(), 0, 'delete on line 5 removes it')
  assert.length(saved(), 0, 'deletion saved')
end)

assert.run_test('legacy JSON null decodes as nil, even nested', function()
  local abs = vim.fn.fnamemodify(test_file, ':p')
  seed_legacy(string.format(
    '[{"filename":%q,"lnum":2,"end_lnum":2,"col":1,"text":"[NOTE] migrated",'
      .. '"user_data":{"commit":null,"commit_short":null,"snippet":["   2  line 2"]}}]', abs))

  local ctx = qf.comments()[1].context
  assert.equals(ctx.commit, nil, 'nested null commit is nil')
  assert.equals(ctx.commit_short, nil, 'nested null commit_short is nil')

  local md = export_markdown()
  assert.falsy(md:find('commit', 1, true), 'export has no commit line')
  assert.truthy(md:find('line 2', 1, true), 'snippet still exported')
end)

local function is_id(id)
  return type(id) == 'string' and #id == 16 and id:match('^%x+$') ~= nil
end

assert.run_test('adding a comment gives it a 16 hex char id', function()
  reset()
  vim.fn.cursor(3, 1)
  qf.add_comment('ISSUE')

  local id = saved()[1].id
  assert.truthy(is_id(id), 'saved id is 16 hex chars: ' .. tostring(id))
  assert.equals(qf.comments()[1].id, id, 'memory has the same id')
  assert.equals(require('quickfix-review.store').get(id), qf.comments()[1], 'store.get finds it')
end)

assert.run_test('comments without ids get them on migration, logged once', function()
  local abs = vim.fn.fnamemodify(test_file, ':p')
  seed_legacy(string.format(
    '[{"filename":%q,"lnum":1,"col":1,"text":"[NOTE] a"},{"filename":%q,"lnum":3,"col":1,"text":"[NOTE] b"}]',
    abs, abs))

  local list = qf.comments()
  assert.length(list, 2, 'both loaded')
  assert.truthy(is_id(list[1].id) and is_id(list[2].id), 'both got ids')
  assert.not_equals(list[1].id, list[2].id, 'ids differ')
  local on_disk = saved()
  assert.equals(on_disk[1].id, list[1].id, 'first id logged')
  assert.equals(on_disk[2].id, list[2].id, 'second id logged')

  local bytes = read_bytes(log_file)
  qf = restart()
  local again = qf.comments()
  assert.equals(read_bytes(log_file), bytes, 'second load does not append')
  assert.length(test_helper.log_ops(log_file, 'import'), 1, 'imported once')
  assert.equals(again[1].id, list[1].id, 'first id stable')
  assert.equals(again[2].id, list[2].id, 'second id stable')
end)

assert.run_test('two Neovim processes give their comments different ids', function()
  local abs = vim.fn.fnamemodify(test_file, ':p')
  local ids = {}
  for i = 1, 2 do
    local file = vim.fn.tempname() .. '-ids-' .. i .. '.json'
    local result = vim.system({
      vim.v.progpath, '--headless', '--clean',
      '--cmd', 'set rtp^=' .. vim.fn.getcwd(),
      '-c', string.format(
        'lua require("quickfix-review").setup({storage_file=%q}); '
          .. 'require("quickfix-review.store").add({filename=%q,lnum=1,kind="note",body="x"})', file, abs),
      '-c', 'qall!',
    }):wait()
    assert.equals(result.code, 0, 'child nvim exits cleanly: ' .. tostring(result.stderr))
    local list = saved(file)
    test_helper.remove_storage(file)
    assert.length(list, 1, 'child saved its comment')
    ids[i] = list[1].id
    assert.truthy(is_id(ids[i]), 'child id is 16 hex chars: ' .. tostring(ids[i]))
  end
  assert.not_equals(ids[1], ids[2], 'ids differ across processes')
end)

assert.run_test('two Neovims appending at once lose nothing and tear nothing', function()
  local abs = vim.fn.fnamemodify(test_file, ':p')
  local file = vim.fn.tempname() .. '-concurrent.json'
  local script = vim.fn.tempname() .. '-writer.lua'
  -- Each writer adds 50 comments whose lines are over 8 KB, so a line is
  -- larger than any stdio buffer or pipe atomicity guarantee
  vim.fn.writefile({
    'local who = ...',
    string.format('require("quickfix-review").setup({ storage_file = %q })', file),
    'local store = require("quickfix-review.store")',
    'local ok = 0',
    'for i = 1, 50 do',
    string.format('  if store.add({ filename = %q, lnum = 1, kind = "note",', abs),
    '    body = who .. " " .. i .. " " .. string.rep("x", 9000) }) then ok = ok + 1 end',
    'end',
    'if ok ~= 50 then io.stderr:write("only " .. ok .. " adds succeeded\\n") vim.cmd("cquit 3") end',
  }, script)
  local function writer(who)
    return vim.system({
      vim.v.progpath, '--headless', '--clean',
      '--cmd', 'set rtp^=' .. vim.fn.getcwd(),
      '-c', string.format('lua assert(loadfile(%q))(%q)', script, who),
      '-c', 'qall!',
    })
  end
  -- Both started before either is waited on
  local one, two = writer('one'), writer('two')
  local r1, r2 = one:wait(60000), two:wait(60000)
  local ok, err = pcall(function()
    assert.equals(r1.code, 0, 'writer one exits cleanly: ' .. tostring(r1.stderr))
    assert.equals(r2.code, 0, 'writer two exits cleanly: ' .. tostring(r2.stderr))

    local lines = vim.split(read_bytes(test_helper.log_path(file)), '\n', { plain = true })
    assert.equals(lines[#lines], '', 'the log ends in a newline')
    table.remove(lines)
    assert.length(lines, 101, 'a header and 100 records')
    local eids, per_writer = {}, { one = 0, two = 0 }
    for i, line in ipairs(lines) do
      local decoded, ev = pcall(vim.json.decode, line)
      assert.truthy(decoded and type(ev) == 'table', 'line ' .. i .. ' decodes')
      if i == 1 then
        assert.equals(ev.op, 'header', 'first line is the header')
      else
        assert.equals(ev.op, 'add', 'line ' .. i .. ' is an add')
        assert.truthy(#line > 8192, 'line ' .. i .. ' is over 8 KB')
        assert.falsy(eids[ev.eid], 'eid ' .. tostring(ev.eid) .. ' is unique')
        eids[ev.eid] = true
        local who = ev.comment.body:match('^(%a+) ')
        per_writer[who] = per_writer[who] + 1
      end
    end
    assert.equals(per_writer.one, 50, 'all of writer one')
    assert.equals(per_writer.two, 50, 'all of writer two')
    assert.length(saved(file), 100, '100 live comments')
    assert.equals(vim.fn.isdirectory(test_helper.lock_path(file)), 0, 'no lock left behind')
  end)
  test_helper.remove_storage(file)
  os.remove(script)
  if not ok then error(err, 0) end
end)

assert.run_test('deleting state.json rebuilds the identical state from the log', function()
  reset()
  vim.fn.cursor(1, 1)
  qf.add_comment('ISSUE')
  vim.fn.cursor(2, 1)
  qf.add_comment('NOTE')
  vim.fn.cursor(4, 1)
  qf.add_comment('SUGGESTION')
  qf.delete_comment({ 2, 2 })
  vim.fn.cursor(5, 1)
  qf.add_comment('PRAISE')

  qf = restart() -- writes the cache on the way out
  local store = require('quickfix-review.store')
  assert.equals(vim.fn.filereadable(test_helper.state_path()), 1, 'state.json written')
  local cached_comments, cached_trash = store.all(), store.trash()
  assert.length(cached_comments, 3, 'three live comments')
  assert.length(vim.tbl_keys(cached_trash), 1, 'one in the trash')

  os.remove(test_helper.state_path())
  qf = restart(nil, { no_flush = true })
  store = require('quickfix-review.store')
  assert.truthy(vim.deep_equal(store.all(), cached_comments), 'same comments after a rebuild')
  assert.truthy(vim.deep_equal(store.trash(), cached_trash), 'same trash after a rebuild')
end)

assert.run_test('a migration that crashed before its rename is finished without duplicates', function()
  reset()
  local abs = vim.fn.fnamemodify(test_file, ':p')
  local records = {
    { id = '00000000000000c1', filename = abs, lnum = 1, end_lnum = 1, kind = 'issue', body = 'one',
      created_at = 1700000000 },
    { id = '00000000000000c2', filename = abs, lnum = 3, end_lnum = 3, kind = 'note', body = 'two',
      created_at = 1700000000 },
  }
  local raw = envelope(records)
  local fh = io.open(storage_file, 'wb')
  fh:write(raw)
  fh:close()
  -- What the migration had written when it crashed: the log, with the import
  -- of comments.json, but comments.json not yet renamed
  local log = require('quickfix-review.log')
  assert.truthy(log.append(log_file, {
    log.new_header(),
    log.event('import', { source_sha256 = vim.fn.sha256(raw), comments = records }),
  }), 'seeded')

  local calls = capture_notify(function() qf = restart() end)
  local list = qf.comments()
  assert.length(list, 2, 'no duplicates')
  assert.equals(list[1].body, 'one', 'first comment')
  assert.length(test_helper.log_ops(log_file, 'import'), 1, 'imported once')
  assert.equals(read_bytes(storage_file .. '.pre-log.bak'), raw, 'original kept as .pre-log.bak')
  assert.equals(vim.fn.filereadable(storage_file), 0, 'comments.json moved aside')
  for _, c in ipairs(calls) do
    assert.falsy(c.level == vim.log.levels.WARN or c.level == vim.log.levels.ERROR, 'no warning: ' .. c.msg)
  end

  qf = restart()
  assert.length(qf.comments(), 2, 'still two after another restart')
end)

assert.run_test('a comments.json written next to the log is warned about once and ignored', function()
  reset()
  vim.fn.cursor(1, 1)
  qf.add_comment('ISSUE')
  local other = envelope({ { id = '00000000000000d9', filename = vim.fn.fnamemodify(test_file, ':p'),
    lnum = 2, end_lnum = 2, kind = 'note', body = 'stray', created_at = 1700000000 } })
  local fh = io.open(storage_file, 'wb')
  fh:write(other)
  fh:close()
  local calls = capture_notify(function()
    qf.comments()
    vim.fn.cursor(3, 1)
    qf.add_comment('NOTE')
    qf.comments()
  end)
  local warns = {}
  for _, c in ipairs(calls) do
    if c.level == vim.log.levels.WARN then table.insert(warns, c) end
  end
  assert.length(warns, 1, 'warned once')
  assert.truthy(warns[1].msg:find(storage_file, 1, true), 'names the file')
  assert.length(qf.comments(), 2, 'the stray file is not read')
  assert.equals(read_bytes(storage_file), other, 'and is left alone')
end)

assert.run_test('an empty object round-trips as {}', function()
  local abs = vim.fn.fnamemodify(test_file, ':p')
  seed_legacy(string.format(
    '[{"id":"00000000000000aa","filename":%q,"lnum":1,"col":1,"text":"[NOTE] seeded","user_data":{}}]', abs))
  assert.equals(type(qf.comments()[1].context), 'table', 'loads as a table')

  local bytes = read_bytes(log_file) -- the import of the seeded comment
  assert.truthy(bytes:find('"context":{}', 1, true), 'seeded {} logged as {}: ' .. bytes)
  assert.falsy(bytes:find('"context":[]', 1, true), 'not logged as []')
  vim.fn.cursor(3, 1)
  qf.add_comment('NOTE')
  qf = restart() -- writes and then reads the cache
  assert.truthy(read_bytes(test_helper.state_path()):find('"context":{}', 1, true), 'cached as {}')
  assert.equals(type(qf.comments()[1].context), 'table', 'reloads from the cache as a table')

  reset()
  require('quickfix-review.store').add({ filename = abs, lnum = 2, kind = 'note', body = 'x', context = vim.empty_dict() })
  bytes = read_bytes(log_file)
  assert.truthy(bytes:find('"context":{}', 1, true), 'empty_dict logged as {}: ' .. bytes)
  assert.falsy(bytes:find('[]', 1, true), 'no [] in the log')
  qf = restart()
  assert.equals(type(qf.comments()[1].context), 'table', 'reloads as a table')
end)

assert.run_test('a null in the comment list is rejected, not truncated', function()
  local abs = vim.fn.fnamemodify(test_file, ':p')
  local c1 = string.format('{"filename":%q,"lnum":1,"col":1,"text":"[NOTE] a"}', abs)
  local c3 = string.format('{"filename":%q,"lnum":3,"col":1,"text":"[NOTE] b"}', abs)
  local cases = {
    ['middle null'] = '[' .. c1 .. ',null,' .. c3 .. ']',
    ['two holes'] = '[' .. c1 .. ',null,' .. c3 .. ',null,' .. c1 .. ']',
    ['leading null'] = '[null,' .. c1 .. ',' .. c3 .. ']',
    ['top-level object'] = '{"a":1}',
    ['no version'] = '{"comments":[' .. c1 .. ']}',
    ['unknown version'] = '{"version":3,"comments":[]}',
    ['string version'] = '{"version":"2","comments":[]}',
    ['non-list comments'] = '{"version":2,"comments":{"a":1}}',
    ['null in v2 comments'] = '{"version":2,"comments":[' .. c1 .. ',null,' .. c3 .. ']}',
  }
  for name, json in pairs(cases) do
    local calls = capture_notify(function()
      seed_legacy(json)
      vim.fn.cursor(1, 1)
      qf.add_comment('ISSUE')
      qf.comments()
    end)
    assert.equals(read_bytes(storage_file), json, name .. ': file untouched')
    assert.equals(vim.fn.filereadable(log_file), 0, name .. ': no log written')
    assert.length(errors_mentioning(calls, storage_file), 1, name .. ': reported exactly once, with the path')
  end
  test_helper.remove_storage()
  qf = restart()
end)

assert.run_test('duplicate ids are split on migration', function()
  local abs = vim.fn.fnamemodify(test_file, ':p')
  seed_legacy(string.format(
    '[{"id":"00000000000000aa","filename":%q,"lnum":1,"col":1,"text":"[NOTE] a"},'
      .. '{"id":"00000000000000aa","filename":%q,"lnum":3,"col":1,"text":"[NOTE] copy"}]', abs, abs))

  local list = qf.comments()
  assert.length(list, 2, 'both loaded')
  assert.equals(list[1].id, '00000000000000aa', 'first keeps its id')
  assert.truthy(is_id(list[2].id), 'copy got a fresh id')
  assert.not_equals(list[2].id, list[1].id, 'ids differ')
  local on_disk = saved()
  assert.equals(on_disk[2].id, list[2].id, 'fresh id logged')

  assert.equals(require('quickfix-review.store').remove('00000000000000aa'), 1, 'remove deletes one')
  local left = qf.comments()
  assert.length(left, 1, 'one left')
  assert.equals(left[1].body, 'copy', 'the copy remains')
end)

assert.run_test('a symlinked storage file is migrated without touching its target', function()
  local target = vim.fn.tempname() .. '-target.json'
  local link = vim.fn.tempname() .. '-link.json'
  local abs = vim.fn.fnamemodify(test_file, ':p')
  local seed = envelope({ { id = '00000000000000f1', filename = abs, lnum = 1, end_lnum = 1, kind = 'note',
    body = 'linked', created_at = 1700000000 } })
  vim.fn.writefile({ seed }, target)
  assert.truthy(vim.uv.fs_symlink(target, link), 'symlink created')
  local ok, err = pcall(function()
    qf = restart(link)
    assert.equals(qf.comments()[1].body, 'linked', 'read through the link')
    vim.fn.cursor(2, 1)
    qf.add_comment('ISSUE')
    assert.equals(vim.uv.fs_lstat(link .. '.pre-log.bak').type, 'link', 'the link is moved aside, still a link')
    assert.length(saved(link), 2, 'the log next to the link has both comments')
    assert.equals(read_bytes(target), seed .. '\n', 'target untouched')
  end)
  qf = restart()
  test_helper.remove_storage(link)
  os.remove(target)
  if not ok then error(err, 0) end
end)

assert.run_test('the storage file keeps its permission bits', function()
  local path = vim.fn.tempname() .. '-private.json'
  vim.fn.writefile({ '[]' }, path)
  vim.fn.setfperm(path, 'rw-------')
  local ok, err = pcall(function()
    qf = restart(path)
    vim.fn.cursor(2, 1)
    qf.add_comment('ISSUE')
    assert.length(saved(path), 1, 'comment saved')
    assert.equals(vim.fn.getfperm(test_helper.log_path(path)), 'rw-------', 'log gets mode 0600')
    require('quickfix-review.store').flush()
    assert.equals(vim.fn.getfperm(test_helper.state_path(path)), 'rw-------', 'cache gets mode 0600')
  end)
  qf = restart()
  test_helper.remove_storage(path)
  if not ok then error(err, 0) end
end)

assert.run_test('export.item_format is applied, and a bad one falls back with a warning', function()
  reset()
  vim.fn.cursor(3, 1)
  qf.add_comment('ISSUE')
  local export_opts = require('quickfix-review.config').options.export
  local original = export_opts.item_format
  local ok, err = pcall(function()
    export_opts.item_format = '%d) %s @ %s: %s'
    assert.truthy(export_markdown():find('1) ISSUE @ test_file.txt:3: Test comment', 1, true), 'custom format used')

    export_opts.item_format = '%d. [%s] %s:%d - %s' -- the old 5-placeholder shape
    local md
    local calls = capture_notify(function() md = export_markdown() end)
    assert.truthy(md:find('1. **[ISSUE]** `test_file.txt:3` - Test comment', 1, true), 'default format used')
    local warned = {}
    for _, c in ipairs(calls) do
      if c.level == vim.log.levels.WARN and c.msg:find('item_format', 1, true) then table.insert(warned, c.msg) end
    end
    assert.length(warned, 1, 'warned once')
    local default = require('quickfix-review.export').default_item_format
    assert.truthy(warned[1]:find('using the default ' .. vim.inspect(default), 1, true),
      'names the default format: ' .. warned[1])
    assert.falsy(warned[1]:find('1. **[ISSUE]**', 1, true), 'not a formatted line: ' .. warned[1])
  end)
  export_opts.item_format = original
  if not ok then error(err, 0) end
end)

assert.run_test('an export that cannot be written fails with a message', function()
  local uv = vim.uv or vim.loop
  if uv.getuid and uv.getuid() == 0 then
    print('  (skipped: running as root ignores directory permissions)')
    return
  end
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  vim.fn.setfperm(dir, 'r-xr-xr-x')
  local original_setreg = vim.fn.setreg
  vim.fn.setreg = function() end
  local ok, err = pcall(function()
    local out = dir .. '/review.md'
    local success, message = require('quickfix-review.export').to_clipboard_and_file('# x', out)
    assert.equals(success, false, 'reported as a failure')
    assert.truthy(message:find('could not write ' .. out, 1, true), 'message names the file: ' .. message)
    assert.equals(vim.fn.glob(dir .. '/*', true), '', 'no file or temp file left behind')
  end)
  vim.fn.setreg = original_setreg
  vim.fn.setfperm(dir, 'rwxr-xr-x')
  vim.fn.delete(dir, 'rf')
  if not ok then error(err, 0) end
end)

assert.run_test('a state.json without `removed` (older cache) is replayed from the log', function()
  reset()
  vim.fn.cursor(1, 1)
  qf.add_comment('ISSUE')
  vim.fn.cursor(3, 1)
  qf.add_comment('NOTE')
  local store = require('quickfix-review.store')
  local target = qf.comments()[2].id
  qf.delete_comment({ 3, 3 })
  qf = restart() -- writes the cache
  local doc = vim.json.decode(read_bytes(test_helper.state_path()))
  assert.truthy(type(doc.state.removed) == 'table', 'the cache holds removed')
  doc.state.removed = nil
  local fh = io.open(test_helper.state_path(), 'wb')
  fh:write(vim.json.encode(doc))
  fh:close()
  qf = restart(nil, { no_flush = true })
  store = require('quickfix-review.store')
  local last = store.last_removal()
  assert.truthy(last ~= nil, 'a removal is known')
  assert.equals(last.op, 'delete', 'a delete')
  assert.equals(table.concat(last.ids, ','), target, 'the deleted comment')
  -- And a current cache is used as is, with the same result
  qf = restart()
  store = require('quickfix-review.store')
  assert.equals(table.concat(store.last_removal().ids, ','), target, 'same after a cached restart')
end)

assert.run_test('history of one comment shows add, update, delete in order', function()
  reset()
  vim.fn.cursor(2, 1)
  qf.add_comment('ISSUE')
  local id = qf.comments()[1].id
  vim.fn.cursor(4, 1)
  qf.add_comment('NOTE') -- another comment, not in this history
  assert.equals(require('quickfix-review.store').edit(id, 'new'), 'edited', 'body edited')
  qf.delete_comment({ 2, 2 })
  local rows = qf.history_rows(id)
  local ops = {}
  for i, r in ipairs(rows) do ops[i] = r.op end
  assert.equals(table.concat(ops, ','), 'add,update,delete', 'ops in order')
  assert.truthy(rows[2].text:find('body: Test comment -> new', 1, true), 'update shows prev -> set: ' .. rows[2].text)
  assert.equals(rows[1].kind, 'issue', 'kind shown')
  assert.truthy(rows[1].text:find('test_file.txt:2', 1, true), 'file:line shown: ' .. rows[1].text)
  assert.truthy(rows[1].text:find(id, 1, true), 'id shown')
  -- An update without prev shows only the new value
  local plain = require('quickfix-review.history').rows({
    { op = 'add', comment = { id = 'x', kind = 'note', filename = '/f', lnum = 1 }, ts = 0 },
    { op = 'update', id = 'x', set = { body = 'b' }, ts = 0 },
  }, 'x')
  assert.truthy(plain[2].text:find('body: b', 1, true), 'no prev: ' .. plain[2].text)
  -- An anchor update reads as its lines and abbreviated sha, without the
  -- lnum/end_lnum it also sets
  local anchored = require('quickfix-review.history').rows({
    { op = 'add', comment = { id = 'x', kind = 'note', filename = '/f', lnum = 5 }, ts = 0 },
    { op = 'update', id = 'x', ts = 0,
      set = { anchor = { sha = 'abcdef123456', lnum = 7, end_lnum = 9, lines = { 'a', 'b', 'c' } },
              lnum = 7, end_lnum = 9 },
      prev = { anchor = { sha = '1234567890ab', lnum = 5, end_lnum = 5, lines = { 'x' } },
               lnum = 5, end_lnum = 5 } },
  }, 'x')
  local text = anchored[2].text
  assert.truthy(text:find('anchor: L5-5 (1234567) -> L7-9 (abcdef1)', 1, true), 'anchor shown: ' .. text)
  assert.falsy(text:find('{', 1, true), 'no inspect braces: ' .. text)
  assert.falsy(text:find('...', 1, true), 'not truncated: ' .. text)
  assert.falsy(text:find('lnum:', 1, true), 'lnum not listed separately: ' .. text)
  -- An anchor with no snapshot says so
  local legacy = require('quickfix-review.history').rows({
    { op = 'update', id = 'y', ts = 0, set = { anchor = { lnum = 3, end_lnum = 4 }, lnum = 3, end_lnum = 4 } },
  }, 'y')
  assert.truthy(legacy[1].text:find('anchor: L3-4 (no snapshot)', 1, true), 'no sha: ' .. legacy[1].text)
  vim.cmd('ReviewHistory ' .. id) -- prints without error
  qf.clear_review()
end)

assert.run_test('history without an id is the last 50 events', function()
  local events = {}
  for i = 1, 60 do
    table.insert(events, { op = 'add', comment = { id = 'c' .. i, kind = 'note', filename = '/f', lnum = i }, ts = i })
  end
  local rows = require('quickfix-review.history').rows(events)
  assert.length(rows, 50, 'capped at 50')
  assert.equals(rows[1].id, 'c11', 'the last 50')
  assert.equals(rows[50].id, 'c60', 'newest last')
  reset()
  vim.fn.cursor(1, 1)
  qf.add_comment('ISSUE')
  assert.truthy(#qf.history_rows() > 0, 'rows from the log')
  vim.cmd('ReviewHistory')
  qf.clear_review()
end)

-- Final cleanup
test_helper.cleanup_test_environment()

return assert
