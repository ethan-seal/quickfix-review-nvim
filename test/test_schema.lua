-- Tests for the storage schema: version 2 records, and upgrading version 1
-- files (bare lists of quickfix-shaped items with the kind, range and
-- response encoded in the text)
local test_helper = dofile('test/init.lua')
local assert = dofile('test/assertions.lua')

print('\nRunning schema tests...')

local qf = test_helper.setup_test_environment()
local test_file = test_helper.create_test_file('line 1\nline 2\nline 3\nline 4\nline 5\n')
local abs = vim.fn.fnamemodify(test_file, ':p')
local storage = require('quickfix-review.storage')

local function read_bytes(path)
  local fh = io.open(path, 'rb')
  assert.truthy(fh, 'can open ' .. path)
  local content = fh:read('*a')
  fh:close()
  return content
end

local function write_bytes(path, content)
  local fh = io.open(path, 'wb')
  fh:write(content)
  fh:close()
end

-- The live records in the event log of the review at `path`
local function logged(path)
  return test_helper.saved(test_helper.log_path(path))
end

-- The import events in the log of the review at `path`
local function imports(path)
  return test_helper.log_ops(test_helper.log_path(path), 'import')
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

local function warnings(calls)
  local found = {}
  for _, c in ipairs(calls) do
    if c.level == vim.log.levels.WARN then table.insert(found, c) end
  end
  return found
end

-- Simulate quitting and reopening Neovim on `path`
local function restart(path)
  for name, _ in pairs(package.loaded) do
    if name:match('^quickfix%-review') then package.loaded[name] = nil end
  end
  local fresh = require('quickfix-review')
  fresh.setup({ storage_file = path or test_helper.storage_file })
  return fresh
end

-- A fresh storage path in its own directory, so its backup is its own too
local function fresh_path()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  return dir .. '/review.json', dir
end

-- Run fn against a v1 file holding `json`; cleans up afterwards
local function with_file(json, fn)
  local path, dir = fresh_path()
  write_bytes(path, json)
  local ok, err = pcall(fn, path)
  qf = restart()
  vim.fn.delete(dir, 'rf')
  if not ok then error(err, 0) end
end

-- A v1 fixture: a single line with context, a range with a response and
-- context holding a null commit, a stale end_lnum 0, and text with no prefix
local V1 = string.format(table.concat({
  '[',
  '{"id":"00000000000000a1","filename":%q,"lnum":2,"end_lnum":2,"col":1,"type":"I","text":"[ISSUE] off by one",',
  '"user_data":{"commit":"0123456789abcdef0123456789abcdef01234567","commit_short":"01234567",',
  '"snippet":["@@ -1,2 +1,2 @@","-old line","+new line"]}},',
  '{"filename":%q,"lnum":3,"end_lnum":5,"col":1,"type":"S","text":"[SUGGESTION:L3-5] extract this | Response: done in abc123",',
  '"user_data":{"commit":null,"commit_short":null,"snippet":["   3  line 3","   4  line 4"]}},',
  '{"filename":%q,"lnum":4,"end_lnum":0,"col":1,"type":"I","text":"[INSIGHT] nice pattern"},',
  '{"filename":%q,"lnum":1,"end_lnum":1,"col":1,"text":"no prefix here"}',
  ']',
}), abs, abs, abs, abs)

-- What the plugin exported for V1 before the schema change (generated with
-- the version 1 code, not written by hand)
local GOLDEN = table.concat({
  '# Review',
  'Types: ISSUE',
  '1. **[ISSUE]** `test_file.txt:2` - off by one',
  '   - commit: `01234567`',
  '',
  '   ```diff',
  '   @@ -1,2 +1,2 @@',
  '   -old line',
  '   +new line',
  '   ```',
  '2. **[SUGGESTION]** `test_file.txt:3-5` - extract this | Response: done in abc123',
  '',
  '   ```diff',
  '      3  line 3',
  '      4  line 4',
  '   ```',
  '3. **[INSIGHT]** `test_file.txt:4` - nice pattern',
  '4. **[NOTE]** `test_file.txt:1` - no prefix here',
}, '\n')

local EXPORT_CONFIG = { export = { header = '# Review', type_legend = 'Types: ISSUE' } }

local function export(comments)
  local md, err = require('quickfix-review.export').to_markdown(comments, EXPORT_CONFIG)
  assert.truthy(md, 'export succeeds: ' .. tostring(err))
  return md
end

-- storage.upgrade on single v1 items
local function upgrade_one(item)
  local doc = storage.upgrade({ item })
  assert.equals(doc.version, 2, 'upgraded to version 2')
  return doc.comments[1]
end

assert.run_test('upgrade parses the kind prefix and drops the range', function()
  local cases = {
    { '[ISSUE] a', 'issue', 'a' },
    { '[SUGGESTION] b', 'suggestion', 'b' },
    { '[ISSUE:L3-7] ranged', 'issue', 'ranged' },
    { '[INSIGHT] c', 'insight', 'c' },
    { '[CUSTOM] d', 'custom', 'd' },
    { 'No brackets here', 'note', 'No brackets here' },
    { '', 'note', '' },
    { 'foo [BAR] mid-text', 'note', 'foo [BAR] mid-text' },
  }
  for _, case in ipairs(cases) do
    local c = upgrade_one({ filename = abs, lnum = 1, text = case[1] })
    assert.equals(c.kind, case[2], 'kind of ' .. vim.inspect(case[1]))
    assert.equals(c.body, case[3], 'body of ' .. vim.inspect(case[1]))
    assert.equals(c.response, nil, 'no response in ' .. vim.inspect(case[1]))
    assert.equals(c.text, nil, 'no text field')
    assert.equals(c.type, nil, 'no type field')
    assert.equals(c.col, nil, 'no col field')
  end
end)

assert.run_test('upgrade splits a response off the text', function()
  local c = upgrade_one({ filename = abs, lnum = 1, text = '[ISSUE] broken | Response: fixed | Response: really' })
  assert.equals(c.body, 'broken', 'body before the first separator')
  assert.equals(c.response, 'fixed | Response: really', 'everything after it is the response')
  c = upgrade_one({ filename = abs, lnum = 1, text = '[NOTE] a|Response:b' })
  assert.equals(c.body, 'a', 'tight separator: body')
  assert.equals(c.response, 'b', 'tight separator: response')
end)

assert.run_test('upgrade moves user_data to context, flat or nested', function()
  local flat = { commit = 'abc', commit_short = 'abc', snippet = { 'x' } }
  local c = upgrade_one({ filename = abs, lnum = 1, text = '[NOTE] a', user_data = flat })
  assert.equals(c.context.commit_short, 'abc', 'flat user_data is the context')
  assert.equals(c.user_data, nil, 'no user_data field')

  c = upgrade_one({ filename = abs, lnum = 1, text = '[NOTE] a', user_data = { context = { commit_short = 'def' } } })
  assert.equals(c.context.commit_short, 'def', 'nested context used')

  c = upgrade_one({ filename = abs, lnum = 1, text = '[NOTE] a', user_data = { id = 'x', commit_short = 'ghi' } })
  assert.equals(c.context.commit_short, 'ghi', 'context kept')
  assert.equals(c.context.id, nil, 'a qf row id is not context')

  c = upgrade_one({ filename = abs, lnum = 1, text = '[NOTE] a', user_data = { id = 'x' } })
  assert.equals(c.context, nil, 'only an id: no context')

  c = upgrade_one({ filename = abs, lnum = 1, text = '[NOTE] a' })
  assert.equals(c.context, nil, 'no user_data: no context')
end)

assert.run_test('upgrade keeps id and lines, and stamps created_at', function()
  local before = os.time()
  local c = upgrade_one({ id = '00000000000000aa', filename = abs, lnum = 2, end_lnum = 4, text = '[NOTE] a' })
  assert.equals(c.id, '00000000000000aa', 'id kept')
  assert.equals(c.filename, abs, 'filename kept')
  assert.equals(c.lnum, 2, 'lnum kept')
  assert.equals(c.end_lnum, 4, 'end_lnum kept')
  assert.truthy(type(c.created_at) == 'number' and c.created_at >= before, 'created_at stamped')

  c = upgrade_one({ filename = abs, lnum = 2, text = '[NOTE] a' })
  assert.equals(c.id, nil, 'missing id left for the store to assign')
end)

assert.run_test('upgrade leaves a version 2 document alone', function()
  local doc = { version = 2, comments = { { kind = 'issue', body = 'x' } } }
  assert.equals(storage.upgrade(doc), doc, 'same document')
end)

assert.run_test('a v1 file is migrated to the log as v2 records, the original kept', function()
  with_file(V1, function(path)
    qf = restart(path)
    local list = qf.comments()
    assert.length(list, 4, 'all comments loaded')
    assert.equals(list[1].kind, 'issue', 'first kind')
    assert.equals(list[2].kind, 'suggestion', 'second kind')
    assert.equals(list[2].body, 'extract this', 'second body')
    assert.equals(list[2].response, 'done in abc123', 'second response')
    assert.equals(list[3].kind, 'insight', 'third kind')
    assert.equals(list[3].end_lnum, 4, 'end_lnum 0 clamped')
    assert.equals(list[4].kind, 'note', 'unprefixed text is a note')
    assert.equals(list[4].body, 'no prefix here', 'unprefixed body')
    for i, c in ipairs(list) do
      assert.equals(c.extra, nil, 'comment ' .. i .. ': quickfix-only fields are not extras')
      assert.equals(c.col, nil, 'comment ' .. i .. ' has no col')
      assert.equals(c.type, nil, 'comment ' .. i .. ' has no type')
      assert.equals(c.bufnr, nil, 'comment ' .. i .. ' has no bufnr')
    end

    assert.equals(read_bytes(path .. '.pre-log.bak'), V1, 'original kept, byte for byte')
    assert.equals(vim.fn.filereadable(path), 0, 'comments.json moved aside')
    assert.length(imports(path), 1, 'one import event')
    local on_disk = logged(path)
    assert.length(on_disk, 4, 'all comments logged')
    for i, c in ipairs(on_disk) do
      assert.equals(c.text, nil, 'comment ' .. i .. ' has no text')
      assert.equals(c.user_data, nil, 'comment ' .. i .. ' has no user_data')
      assert.equals(c.id, list[i].id, 'comment ' .. i .. ' id written')
      assert.equals(type(c.created_at), 'number', 'comment ' .. i .. ' has created_at')
    end
    assert.equals(on_disk[1].context.commit_short, '01234567', 'context logged')

    -- The qf view looks as it did in v1
    qf.show_list()
    local rows = vim.fn.getqflist()
    assert.equals(rows[1].text, '[ISSUE] off by one', 'row 1 text')
    assert.equals(rows[2].text, '[SUGGESTION:L3-5] extract this | Response: done in abc123', 'row 2 text')
    assert.equals(rows[3].type, 'I', 'insight row type')
    assert.equals(rows[2].user_data.id, list[2].id, 'row carries the id')
    vim.fn.setqflist({}, 'f')

    -- Loading again leaves the log and the original alone
    local bytes = read_bytes(test_helper.log_path(path))
    qf = restart(path)
    assert.length(qf.comments(), 4, 'reloads')
    assert.equals(read_bytes(test_helper.log_path(path)), bytes, 'log not appended to')

    -- Another v1 write (e.g. an older tool) is not read once a log exists: it
    -- is warned about once and left alone
    local other = string.format('[{"filename":%q,"lnum":1,"text":"[NOTE] later"}]', abs)
    write_bytes(path, other)
    local later
    local calls = capture_notify(function()
      later = qf.comments()
      qf.comments()
    end)
    assert.length(later, 4, 'the review is still the log')
    local warns = warnings(calls)
    assert.length(warns, 1, 'warned once')
    assert.truthy(warns[1].msg:find('reappeared', 1, true), 'says the file reappeared: ' .. warns[1].msg)
    assert.equals(read_bytes(path), other, 'the new file left alone')
    assert.equals(read_bytes(path .. '.pre-log.bak'), V1, 'first original not overwritten')
  end)
end)

assert.run_test('an empty v1 file upgrades cleanly', function()
  with_file('[]', function(path)
    qf = restart(path)
    assert.length(qf.comments(), 0, 'no comments')
    assert.equals(read_bytes(path .. '.pre-log.bak'), '[]', 'original kept')
    assert.length(imports(path), 1, 'an (empty) import logged')
    assert.length(logged(path), 0, 'empty review')

    vim.fn.cursor(2, 1)
    qf.add_comment('NOTE')
    assert.length(logged(path), 1, 'adding works')
  end)
end)

assert.run_test('an empty comments object loads as an empty list', function()
  with_file('{"version":2,"comments":{}}', function(path)
    qf = restart(path)
    assert.length(qf.comments(), 0, 'no comments')
    assert.truthy(vim.uv.fs_stat(path .. '.pre-log.bak'), 'migrated')
  end)
end)

assert.run_test('export of a v1 file is byte-identical before and after migration', function()
  with_file(V1, function(path)
    qf = restart(path)
    assert.equals(export(qf.comments()), GOLDEN, 'first load (upgraded in memory)')
    qf = restart(path)
    assert.equals(export(qf.comments()), GOLDEN, 'after restart (read as version 2)')
  end)
end)

assert.run_test('issue and insight keep distinct kinds through save and load', function()
  local path, dir = fresh_path()
  local ok, err = pcall(function()
    qf = restart(path)
    vim.fn.cursor(1, 1)
    qf.add_comment('ISSUE')
    vim.fn.cursor(2, 1)
    qf.add_comment('INSIGHT')

    qf = restart(path)
    local list = qf.comments()
    assert.equals(list[1].kind, 'issue', 'issue in memory')
    assert.equals(list[2].kind, 'insight', 'insight in memory')
    local on_disk = logged(path)
    assert.equals(on_disk[1].kind, 'issue', 'issue on disk')
    assert.equals(on_disk[2].kind, 'insight', 'insight on disk')

    local counts = {}
    for _, entry in ipairs(qf.summary_data().by_type) do counts[entry[1]] = entry[2] end
    assert.equals(counts.issue, 1, 'one issue counted')
    assert.equals(counts.insight, 1, 'one insight counted')
  end)
  qf = restart()
  vim.fn.delete(dir, 'rf')
  if not ok then error(err, 0) end
end)

assert.run_test('view_comment shows the response on its own line', function()
  with_file(V1, function(path)
    qf = restart(path)
    vim.cmd('edit ' .. test_file)
    vim.fn.cursor(3, 1)
    local wins_before = {}
    for _, w in ipairs(vim.api.nvim_list_wins()) do wins_before[w] = true end
    qf.view_comment()
    local float
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if not wins_before[w] and vim.api.nvim_win_get_config(w).relative ~= '' then float = w end
    end
    assert.truthy(float, 'float opened')
    local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(float), 0, -1, false)
    -- Close it the way moving the cursor does, so its close autocmds go too
    vim.api.nvim_exec_autocmds('CursorMoved', {})
    assert.falsy(vim.api.nvim_win_is_valid(float), 'float closed')
    assert.equals(lines[1], '[SUGGESTION:L3-5] extract this', 'headline without the response')
    assert.equals(lines[2], '', 'blank separator')
    assert.equals(lines[3], 'Response: done in abc123', 'response line')
  end)
end)

-- A v2 file holding `records` (Lua tables, encoded as JSON)
local function v2_json(records)
  return vim.json.encode({ version = 2, comments = records })
end

assert.run_test('a legacy text field in a v2 record is merged and dropped', function()
  local json = v2_json({ {
    id = '00000000000000b1', filename = abs, lnum = 1, end_lnum = 2, kind = 'issue', body = 'foo',
    created_at = 1700000000, text = '[ISSUE:L1-2] foo | Response: fixed',
  } })
  with_file(json, function(path)
    qf = restart(path)
    local list = qf.comments()
    assert.length(list, 1, 'loaded')
    assert.equals(list[1].response, 'fixed', 'response taken from text')
    assert.equals(list[1].body, 'foo', 'body kept')
    assert.equals(list[1].extra, nil, 'text is not an extra')
    local on_disk = logged(path)
    assert.equals(on_disk[1].text, nil, 'text dropped from the logged record')
    assert.equals(on_disk[1].response, 'fixed', 'response logged')
    assert.truthy(export(list):find(' | Response: fixed', 1, true), 'export shows the response')
    assert.equals(read_bytes(path .. '.pre-log.bak'), json, 'original kept as it was')

    local bytes = read_bytes(test_helper.log_path(path))
    qf = restart(path)
    assert.equals(qf.comments()[1].response, 'fixed', 'response after restart')
    assert.equals(read_bytes(test_helper.log_path(path)), bytes, 'not logged again')
  end)

  -- Text without a headline keeps the record's kind and body
  json = v2_json({ {
    id = '00000000000000b2', filename = abs, lnum = 1, end_lnum = 1, kind = 'issue', body = 'b',
    created_at = 1700000000, text = ' | Response: x',
  } })
  with_file(json, function(path)
    qf = restart(path)
    local c = qf.comments()[1]
    assert.equals(c.kind, 'issue', 'kind kept')
    assert.equals(c.body, 'b', 'body kept')
    assert.equals(c.response, 'x', 'response from headline-less text')
  end)

  -- A response in the text replaces the record's
  json = v2_json({ {
    id = '00000000000000b3', filename = abs, lnum = 1, end_lnum = 1, kind = 'note', body = 'b',
    response = 'old', created_at = 1700000000, text = '[NOTE] b | Response: new',
  } })
  with_file(json, function(path)
    qf = restart(path)
    assert.equals(qf.comments()[1].response, 'new', 'text response wins')
  end)

  -- A record with only text gets its kind and body from it
  json = v2_json({ {
    id = '00000000000000b4', filename = abs, lnum = 1, end_lnum = 1, created_at = 1700000000,
    text = '[ISSUE] bar',
  } })
  with_file(json, function(path)
    qf = restart(path)
    local c = qf.comments()[1]
    assert.equals(c.kind, 'issue', 'kind from text')
    assert.equals(c.body, 'bar', 'body from text')
    assert.equals(c.response, nil, 'no response')
  end)
end)

assert.run_test('an unknown record field survives load and save', function()
  local json = v2_json({ {
    id = '00000000000000c1', filename = abs, lnum = 1, end_lnum = 1, kind = 'note', body = 'a',
    created_at = 1700000000, foo = 1,
  } })
  with_file(json, function(path)
    qf = restart(path)
    assert.equals(qf.comments()[1].extra.foo, 1, 'kept in memory as an extra')
    assert.equals(read_bytes(path .. '.pre-log.bak'), json, 'original kept byte for byte')

    vim.cmd('edit ' .. test_file)
    vim.fn.cursor(2, 1)
    qf.add_comment('NOTE')
    local on_disk = logged(path)
    assert.length(on_disk, 2, 'saved')
    assert.equals(on_disk[1].foo, 1, 'logged at the top level')
    assert.equals(on_disk[1].extra, nil, 'no extra key on disk')
    assert.equals(on_disk[2].extra, nil, 'no extra key on a new comment')

    qf = restart(path)
    assert.equals(qf.comments()[1].extra.foo, 1, 'an extra again after restart')
    vim.fn.cursor(3, 1)
    qf.add_comment('NOTE')
    on_disk = logged(path)
    assert.length(on_disk, 3, 'saved again')
    assert.equals(on_disk[1].foo, 1, 'still at the top level')
    assert.equals(on_disk[1].extra, nil, 'still no extra key')
  end)
end)

assert.run_test('a record with a bad lnum is dropped with a warning, the original kept', function()
  local json = v2_json({
    { id = '00000000000000d1', filename = abs, lnum = 'x', end_lnum = 1, kind = 'note', body = 'bad',
      created_at = 1700000000 },
    { id = '00000000000000d2', filename = abs, lnum = '12', end_lnum = '13', kind = 'issue', body = 'str',
      created_at = 1700000000 },
    { id = '00000000000000d3', filename = abs, lnum = 2, end_lnum = 2, kind = 'note', body = 'ok',
      created_at = 1700000000 },
  })
  with_file(json, function(path)
    local list
    local calls = capture_notify(function()
      qf = restart(path)
      list = qf.comments()
    end)
    assert.length(list, 2, 'the other records load')
    local warns = warnings(calls)
    assert.length(warns, 1, 'one warning')
    assert.truthy(warns[1].msg:find(path, 1, true), 'warning names the file')
    assert.equals(read_bytes(path .. '.pre-log.bak'), json, 'original kept byte for byte')

    assert.equals(list[1].lnum, 12, 'numeric string lnum coerced')
    assert.equals(list[1].end_lnum, 13, 'numeric string end_lnum coerced')
    local on_disk = logged(path)
    assert.length(on_disk, 2, 'logged without the bad record')
    assert.equals(on_disk[1].lnum, 12, 'lnum logged as a number')
    assert.equals(on_disk[1].end_lnum, 13, 'end_lnum logged as a number')

    qf.show_list()
    assert.length(vim.fn.getqflist(), 2, 'quickfix view built')
    vim.fn.setqflist({}, 'f')
    assert.truthy(export(list), 'export works')

    local bytes = read_bytes(test_helper.log_path(path))
    calls = capture_notify(function()
      qf = restart(path)
      assert.length(qf.comments(), 2, 'reloads')
    end)
    assert.length(warnings(calls), 0, 'no warning on the second load')
    assert.equals(read_bytes(test_helper.log_path(path)), bytes, 'not logged again')
  end)
end)

-- Final cleanup
test_helper.cleanup_test_environment()

return assert
