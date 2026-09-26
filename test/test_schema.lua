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

    -- Legacy comments are anchored at their line, with no snapshot, at read
    -- time: nothing derived is logged
    for i, c in ipairs(list) do
      assert.truthy(type(c.anchor) == 'table', 'comment ' .. i .. ' has an anchor')
      assert.equals(c.anchor.sha, nil, 'comment ' .. i .. ' anchor has no sha')
      assert.equals(c.anchor.lnum, c.lnum, 'comment ' .. i .. ' anchor lnum')
      assert.equals(c.anchor.end_lnum, c.end_lnum, 'comment ' .. i .. ' anchor end_lnum')
      assert.equals(c.pos.lnum, c.lnum, 'comment ' .. i .. ' pos lnum')
      assert.equals(c.pos.state, 'current', 'comment ' .. i .. ' pos state')
      assert.equals(on_disk[i].anchor, nil, 'comment ' .. i .. ' no anchor logged')
      assert.equals(on_disk[i].pos, nil, 'comment ' .. i .. ' no pos logged')
    end

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
    assert.equals(qf.comments()[2].extra, nil, 'an anchor is not an extra')
    assert.truthy(type(qf.comments()[2].anchor) == 'table', 'the new comment has an anchor')
    assert.truthy(type(on_disk[2].anchor) == 'table', 'the anchor is logged')

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

-- Every path that drops records keeps the original bytes: migration renames
-- the file to .pre-log.bak (above), and the legacy global import only reads
-- its file. There is no separate repair rewrite that needs its own backup.
assert.run_test('a non-finite lnum is dropped, not a save failure', function()
  -- Raw JSON: vim.json.encode refuses inf, but a file may hold it
  local json = '{"version":2,"comments":['
    .. '{"id":"00000000000000f1","filename":' .. vim.json.encode(abs)
    .. ',"lnum":"1e999","end_lnum":1,"kind":"note","body":"str inf","created_at":1700000000},'
    .. '{"id":"00000000000000f2","filename":' .. vim.json.encode(abs)
    .. ',"lnum":1e999,"end_lnum":1,"kind":"note","body":"num inf","created_at":1700000000},'
    .. '{"id":"00000000000000f3","filename":' .. vim.json.encode(abs)
    .. ',"lnum":2,"end_lnum":1e999,"kind":"note","body":"ok","created_at":1e999,'
    .. '"anchor":{"lnum":"1e999","end_lnum":2}},'
    .. '{"id":"00000000000000f4","filename":' .. vim.json.encode(abs)
    .. ',"lnum":3,"end_lnum":3,"kind":"note","body":"anchored","created_at":1700000000,'
    .. '"anchor":{"lnum":3,"end_lnum":"1e999"}}'
    .. ']}'
  with_file(json, function(path)
    local list
    local calls = capture_notify(function()
      qf = restart(path)
      list = qf.comments()
    end)
    assert.length(list, 2, 'the finite records load')
    assert.length(warnings(calls), 1, 'one warning for the dropped records')
    assert.truthy(warnings(calls)[1].msg:find('dropped 2', 1, true), 'both inf records dropped')
    assert.equals(read_bytes(path .. '.pre-log.bak'), json, 'original kept byte for byte')
    assert.equals(list[1].end_lnum, 2, 'inf end_lnum treated as unset')
    assert.truthy(list[1].created_at ~= math.huge, 'inf created_at replaced')
    assert.equals(list[1].anchor.sha, nil, 'inf anchor lnum: no logged anchor')
    assert.equals(list[2].anchor.end_lnum, 3, 'inf anchor end_lnum treated as unset')

    local on_disk = logged(path)
    assert.length(on_disk, 2, 'logged without the inf records')
    assert.equals(on_disk[1].anchor, nil, 'the inf anchor is not logged')

    -- A save after load works (encode would fail on inf)
    vim.cmd('edit ' .. test_file)
    vim.fn.cursor(4, 1)
    qf.add_comment('NOTE')
    assert.length(logged(path), 3, 'saved')

    -- An add with an inf lnum is refused, not logged
    local store = require('quickfix-review.store')
    assert.equals(store.add({ filename = abs, lnum = '1e999', kind = 'note', body = 'x' }), false, 'add refused')
    assert.length(logged(path), 3, 'nothing logged')

    qf = restart(path)
    assert.length(qf.comments(), 3, 'reloads')
  end)
end)

assert.run_test('a non-finite number in an unknown field or in context is dropped with a warning', function()
  local json = '{"version":2,"comments":['
    .. '{"id":"00000000000000f5","filename":' .. vim.json.encode(abs)
    .. ',"lnum":2,"end_lnum":2,"kind":"note","body":"weird","created_at":1700000000,'
    .. '"weird":1e999,"keep":[1,1e999,2],"context":{"x":1e999,"y":"kept"}}'
    .. ']}'
  with_file(json, function(path)
    local list
    local calls = capture_notify(function()
      qf = restart(path)
      list = qf.comments()
    end)
    assert.length(list, 1, 'the record loads')
    local warns = warnings(calls)
    assert.length(warns, 1, 'one warning: ' .. vim.inspect(warns))
    assert.truthy(warns[1].msg:find('00000000000000f5', 1, true), 'names the record: ' .. warns[1].msg)
    assert.equals(vim.fn.filereadable(path .. '.pre-log.bak'), 1, 'migrated')
    local on_disk = logged(path)
    assert.length(on_disk, 1, 'logged')
    assert.equals(on_disk[1].weird, nil, 'inf field dropped')
    assert.truthy(vim.deep_equal(on_disk[1].keep, { 1, 2 }), 'list kept without a hole: ' .. vim.inspect(on_disk[1].keep))
    assert.equals(on_disk[1].context.x, nil, 'inf context value dropped')
    assert.equals(on_disk[1].context.y, 'kept', 'the rest of context kept')

    vim.cmd('edit ' .. test_file)
    vim.fn.cursor(4, 1)
    qf.add_comment('NOTE')
    assert.length(logged(path), 2, 'a later add still logs')
  end)
end)

assert.run_test('legacy text the record did not take is kept as extra.legacy_text', function()
  local json = v2_json({
    { id = '00000000000000a1', filename = abs, lnum = 1, end_lnum = 1, kind = 'issue', body = 'a',
      created_at = 1700000000, text = '[ISSUE:L1] b' },
    { id = '00000000000000a2', filename = abs, lnum = 2, end_lnum = 2, kind = 'note', body = 'a',
      created_at = 1700000000, text = '[NOTE] a | response: lower' },
    { id = '00000000000000a3', filename = abs, lnum = 3, end_lnum = 3, kind = 'note', body = 'same',
      created_at = 1700000000, text = '[ISSUE] same' },
    { id = '00000000000000a4', filename = abs, lnum = 4, end_lnum = 4, kind = 'issue', body = 'c',
      created_at = 1700000000, text = '[ISSUE:L4] c | Response: done' },
  })
  with_file(json, function(path)
    qf = restart(path)
    local list = qf.comments()
    assert.length(list, 4, 'loaded')
    assert.equals(list[1].body, 'a', 'record body kept')
    assert.equals(list[1].extra.legacy_text, '[ISSUE:L1] b', 'differing body: text kept')
    assert.equals(list[2].extra.legacy_text, '[NOTE] a | response: lower', 'lowercase response: text kept')
    assert.equals(list[3].kind, 'note', 'record kind kept')
    assert.equals(list[3].extra.legacy_text, '[ISSUE] same', 'differing kind: text kept')
    assert.equals(list[4].extra, nil, 'fully taken text is dropped')
    assert.equals(list[4].response, 'done', 'response merged')

    local on_disk = logged(path)
    assert.equals(on_disk[1].legacy_text, '[ISSUE:L1] b', 'logged at the top level')
    assert.equals(on_disk[1].text, nil, 'text itself not logged')

    -- Survives a later add event and a replay of the log
    vim.cmd('edit ' .. test_file)
    vim.fn.cursor(5, 1)
    qf.add_comment('NOTE')
    require('quickfix-review.store').reload()
    assert.equals(qf.comments()[1].extra.legacy_text, '[ISSUE:L1] b', 'after reload')
    qf = restart(path)
    assert.equals(qf.comments()[1].extra.legacy_text, '[ISSUE:L1] b', 'after restart')
    assert.equals(qf.comments()[2].extra.legacy_text, '[NOTE] a | response: lower', 'second after restart')
  end)

  -- An add event carrying unconsumed text keeps it too
  local path, dir = fresh_path()
  local ok, err = pcall(function()
    qf = restart(path)
    local store = require('quickfix-review.store')
    assert.truthy(store.add({ filename = abs, lnum = 1, kind = 'issue', body = 'a', text = '[ISSUE:L1] b' }), 'added')
    assert.equals(logged(path)[1].legacy_text, '[ISSUE:L1] b', 'logged')
    store.reload()
    assert.equals(store.all()[1].extra.legacy_text, '[ISSUE:L1] b', 'replayed')
  end)
  qf = restart()
  vim.fn.delete(dir, 'rf')
  if not ok then error(err, 0) end
end)

assert.run_test('a logged add event without an anchor is shown at its line after a restart', function()
  local path, dir = fresh_path()
  local ok, err = pcall(function()
    qf = restart(path)
    -- As a version before anchors logged it
    assert.truthy(require('quickfix-review.store').add({
      id = '00000000000000e1', filename = abs, lnum = 3, end_lnum = 4,
      kind = 'issue', body = 'legacy', created_at = 1700000000,
    }), 'added')
    assert.equals(logged(path)[1].anchor, nil, 'logged without an anchor')

    qf = restart(path)
    local c = qf.comments()[1]
    assert.equals(c.anchor.sha, nil, 'no sha')
    assert.equals(c.anchor.lnum, 3, 'anchor lnum')
    assert.equals(c.anchor.end_lnum, 4, 'anchor end_lnum')
    assert.equals(c.pos.lnum, 3, 'pos lnum')
    assert.equals(c.pos.end_lnum, 4, 'pos end_lnum')
    qf.show_list()
    local rows = vim.fn.getqflist()
    assert.equals(rows[1].lnum, 3, 'qf row at its line')
    assert.equals(rows[1].end_lnum, 4, 'qf row end')
    vim.fn.setqflist({}, 'f')
    local on_disk = logged(path)[1]
    assert.equals(on_disk.anchor, nil, 'still no anchor logged')
    assert.equals(on_disk.pos, nil, 'no pos logged')
  end)
  qf = restart()
  vim.fn.delete(dir, 'rf')
  if not ok then error(err, 0) end
end)

-- Final cleanup
test_helper.cleanup_test_environment()

return assert
