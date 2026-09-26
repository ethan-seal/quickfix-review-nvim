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
local function restart(path)
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
  assert.matches(list[1].text, '%[ISSUE%]', 'correct comment type')

  qf.delete_comment({ 3, 3 })
  assert.length(saved(), 0, 'deletion saved')
  assert.equals(vim.fn.glob(storage_file .. '.tmp.*'), '', 'no temp files left behind')
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

  local calls = capture_notify(function()
    vim.fn.cursor(1, 1)
    qf.add_comment('ISSUE')
    qf.add_comment('NOTE')
    qf.comments()
  end)

  assert.equals(vim.fn.readfile(storage_file)[1], 'not json', 'file untouched')
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
  local seed = vim.fn.json_encode({
    { filename = vim.fn.fnamemodify(test_file, ':p'), lnum = 2, col = 1, text = '[NOTE] seeded' },
  })
  local fh = io.open(path, 'w')
  fh:write(seed)
  fh:close()

  local ok, err = pcall(function()
    qf = restart(path)
    vim.fn.setfperm(dir, 'r-xr-xr-x')

    local calls = capture_notify(function()
      vim.fn.cursor(1, 1)
      qf.add_comment('ISSUE')
    end)

    assert.equals(read_bytes(path), seed, 'file byte-identical')
    assert.truthy(#errors_mentioning(calls, path) >= 1, 'error notified with the path')
    assert.equals(vim.fn.glob(path .. '.tmp.*'), '', 'no temp files left behind')
    local list = qf.comments()
    assert.length(list, 1, 'failed change not kept in memory')
    assert.equals(list[1].text, '[NOTE] seeded', 'memory matches disk')

    vim.fn.setfperm(dir, 'rwxr-xr-x')
    vim.fn.cursor(3, 1)
    qf.add_comment('ISSUE')
    local on_disk = vim.fn.json_decode(read_bytes(path))
    assert.length(on_disk, 2, 'saving works again once writable')
    assert.equals(vim.fn.glob(path .. '.tmp.*'), '', 'no temp files after recovering')
  end)

  vim.fn.setfperm(dir, 'rwxr-xr-x')
  qf = restart()
  vim.fn.delete(dir, 'rf')
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
  assert.matches(list[1].text, '%[ISSUE%]', 'the selected comment was deleted')
  assert.length(saved(), 1, 'deletion saved')
end)

-- Write raw JSON to the storage file, as an older version or migrate.ts would
local function seed_legacy(json)
  vim.fn.setqflist({}, 'f')
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

  local ctx = qf.comments()[1].user_data
  assert.equals(ctx.commit, nil, 'nested null commit is nil')
  assert.equals(ctx.commit_short, nil, 'nested null commit_short is nil')

  local md = export_markdown()
  assert.falsy(md:find('commit', 1, true), 'export has no commit line')
  assert.truthy(md:find('line 2', 1, true), 'snippet still exported')
end)

-- Final cleanup
test_helper.cleanup_test_environment()

return assert
