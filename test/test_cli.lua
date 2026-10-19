-- Tests for the headless entry point (scripts/qfr.lua, cli.lua): each run is
-- a separate `nvim --clean -l` in a temp git repo, with its own
-- XDG_DATA_HOME and no setup(), as the external review tools run it
local test_helper = dofile((vim.env.QFR_TEST_ROOT or '.') .. '/test/init.lua')
local assert = dofile(test_helper.root .. '/test/assertions.lua')

print('\nRunning headless CLI tests...')

local script = test_helper.root .. '/scripts/qfr.lua'

-- An empty dir for stdpath('data') of the children
local function fresh_data()
  local dir = vim.fn.tempname() .. '-data'
  vim.fn.mkdir(dir, 'p')
  return dir
end

-- A temp git repo holding `name`.txt with lines 1-5; returns its real path
-- and the file
local function make_repo(name)
  local dir = vim.fn.tempname() .. '-' .. name
  vim.fn.mkdir(dir, 'p')
  local r = vim.system({ 'git', 'init', '-q', dir }, { text = true }):wait()
  assert.equals(r.code, 0, 'git init ' .. dir)
  local real = vim.uv.fs_realpath(dir)
  local file = real .. '/' .. name .. '.txt'
  vim.fn.writefile({ 'line 1', 'line 2', 'line 3', 'line 4', 'line 5' }, file)
  return real, file
end

-- Run qfr.lua with `args` in `dir`; returns { code, stdout, stderr }
local function qfr(dir, data, ...)
  return vim.system({ vim.v.progpath, '--clean', '-l', script, ... },
    { cwd = dir, env = { XDG_DATA_HOME = data }, text = true }):wait()
end

local function export(dir, data)
  local r = qfr(dir, data, 'export')
  assert.equals(r.code, 0, 'export exits 0: ' .. tostring(r.stderr))
  local ok, list = pcall(vim.json.decode, r.stdout, { luanil = { object = true } })
  assert.truthy(ok, 'export stdout is JSON: ' .. tostring(r.stdout))
  return list, r
end

-- Add a comment in another headless Neovim in `dir` (no setup() either),
-- anchored to its file's lines as the plugin anchors one
local function add(dir, data, item)
  local code = string.format("local store = require('quickfix-review.store') "
    .. "local item = vim.json.decode(%q) "
    .. "vim.cmd.edit(vim.fn.fnameescape(item.filename)) "
    .. "local ok = store.with_location(function() "
    .. "  item.anchor = require('quickfix-review.context').anchor(item.lnum, item.end_lnum, 0) "
    .. "  return store.add(item) end) "
    .. "if not ok then vim.cmd('cquit 3') end", vim.json.encode(item))
  local r = vim.system({ vim.v.progpath, '--clean', '--headless', '--cmd', 'set rtp^=' .. test_helper.root,
    '-c', 'lua ' .. code, '-c', 'qall!' }, { cwd = dir, env = { XDG_DATA_HOME = data }, text = true }):wait()
  assert.equals(r.code, 0, 'add exits 0: ' .. tostring(r.stderr))
end

local function events_path(dir, data)
  local root = vim.uv.fs_realpath(dir)
  return string.format('%s/nvim/quickfix-review/%s-%s/events', data, vim.fn.fnamemodify(root, ':t'),
    vim.fn.sha256(root):sub(1, 12))
end

assert.run_test('export of an empty project prints []', function()
  local dir = make_repo('empty')
  local r = qfr(dir, fresh_data(), 'export')
  assert.equals(r.code, 0, 'exit 0')
  assert.equals(r.stdout, '[]\n', 'an empty array')
end)

assert.run_test('export prints every comment with its fields', function()
  local dir, file = make_repo('fields')
  local data = fresh_data()
  add(dir, data, { filename = file, lnum = 2, end_lnum = 4, kind = 'issue', body = 'range one' })
  add(dir, data, { filename = file, lnum = 5, end_lnum = 5, kind = 'note', body = 'multi\nline' })
  local list = export(dir, data)
  assert.length(list, 2, 'two comments')
  local a, b = list[1], list[2]
  assert.truthy(type(a.id) == 'string' and a.id ~= '', 'id exported')
  assert.equals(a.filename, file, 'absolute filename')
  assert.equals(a.kind, 'issue', 'kind')
  assert.equals(a.body, 'range one', 'body')
  assert.equals(a.lnum, 2, 'lnum')
  assert.equals(a.end_lnum, 4, 'end_lnum')
  assert.equals(a.response, nil, 'no response yet')
  assert.equals(b.body, 'multi\nline', 'multi-line body')
  assert.equals(b.lnum, 5, 'second lnum')
end)

assert.run_test('respond sets the response that export then shows', function()
  local dir, file = make_repo('respond')
  local data = fresh_data()
  add(dir, data, { filename = file, lnum = 3, end_lnum = 3, kind = 'issue', body = 'fix me' })
  local id = export(dir, data)[1].id
  local r = qfr(dir, data, 'respond', id, 'Will fix: it\'s "quoted"')
  assert.equals(r.code, 0, 'respond exits 0: ' .. tostring(r.stderr))
  assert.equals(r.stdout, '', 'respond prints nothing')
  assert.equals(export(dir, data)[1].response, 'Will fix: it\'s "quoted"', 'response exported')
  r = qfr(dir, data, 'respond', id, 'Will fix: it\'s "quoted"')
  assert.equals(r.code, 0, 'an unchanged response exits 0')
  assert.length(test_helper.log_ops(events_path(dir, data), 'update'), 1, 'one update logged')
end)

assert.run_test('respond to an unknown id fails on stderr', function()
  local dir, file = make_repo('missing')
  local data = fresh_data()
  add(dir, data, { filename = file, lnum = 1, end_lnum = 1, kind = 'note', body = 'x' })
  local r = qfr(dir, data, 'respond', 'ffffffffffffffff', 'text')
  assert.equals(r.code, 1, 'exit 1')
  assert.equals(r.stdout, '', 'nothing on stdout')
  assert.truthy(r.stderr:find('ffffffffffffffff', 1, true), 'stderr names the id')
  assert.length(test_helper.log_ops(events_path(dir, data), 'update'), 0, 'no update logged')
end)

assert.run_test('clear empties the review with one clear event', function()
  local dir, file = make_repo('clear')
  local data = fresh_data()
  add(dir, data, { filename = file, lnum = 1, end_lnum = 1, kind = 'note', body = 'a' })
  add(dir, data, { filename = file, lnum = 2, end_lnum = 2, kind = 'note', body = 'b' })
  local r = qfr(dir, data, 'clear')
  assert.equals(r.code, 0, 'clear exits 0: ' .. tostring(r.stderr))
  assert.equals(r.stdout, '', 'clear prints nothing')
  assert.length(export(dir, data), 0, 'review empty')
  assert.length(test_helper.log_ops(events_path(dir, data), 'clear'), 1, 'one clear logged')
  assert.equals(qfr(dir, data, 'clear').code, 0, 'clearing an empty review exits 0')
  assert.length(test_helper.log_ops(events_path(dir, data), 'clear'), 1, 'nothing more logged')
end)

assert.run_test('legacy import notice goes to stderr; stdout stays JSON; no re-import after clear', function()
  local dir = make_repo('legacy')
  local data = fresh_data()
  local legacy = data .. '/nvim/quickfix-review.json'
  vim.fn.mkdir(data .. '/nvim', 'p')
  vim.fn.writefile({ vim.json.encode({
    { filename = dir .. '/legacy.txt', lnum = 2, col = 1, text = '[ISSUE] from legacy | Response: ok' },
  }) }, legacy)
  local list, r = export(dir, data)
  assert.length(list, 1, 'legacy comment imported')
  assert.equals(list[1].kind, 'issue', 'kind parsed from the legacy text')
  assert.equals(list[1].body, 'from legacy', 'body parsed from the legacy text')
  assert.equals(list[1].response, 'ok', 'response parsed from the legacy text')
  assert.truthy(r.stderr:find('imported 1 comments', 1, true), 'import notice on stderr')
  assert.equals(qfr(dir, data, 'clear').code, 0, 'clear exits 0')
  assert.length(export(dir, data), 0, 'review empty after clear')
  assert.length(export(dir, data), 0, 'still empty: legacy not re-imported')
  assert.equals(vim.fn.filereadable(legacy), 1, 'legacy file left in place')
end)

assert.run_test('export of a review that cannot be read fails with nothing on stdout', function()
  local dir = make_repo('unreadable')
  local data = fresh_data()
  local store_dir = vim.fn.fnamemodify(events_path(dir, data), ':h')
  vim.fn.mkdir(store_dir, 'p')
  vim.fn.writefile({ '{ not json' }, store_dir .. '/comments.json')
  local r = qfr(dir, data, 'export')
  assert.equals(r.code, 1, 'exit 1: ' .. tostring(r.stderr))
  assert.equals(r.stdout, '', 'nothing on stdout')
  assert.truthy(r.stderr:find('could not read the review', 1, true), 'error on stderr: ' .. tostring(r.stderr))
end)

assert.run_test('export gives the line a comment moved to after an edit on disk', function()
  local dir, file = make_repo('moved')
  local data = fresh_data()
  add(dir, data, { filename = file, lnum = 3, end_lnum = 4, kind = 'issue', body = 'tracked' })
  local lines = vim.fn.readfile(file)
  table.insert(lines, 1, 'new first line')
  table.insert(lines, 1, 'another')
  vim.fn.writefile(lines, file)
  local c = export(dir, data)[1]
  assert.equals(c.lnum, 5, 'lnum relocated')
  assert.equals(c.end_lnum, 6, 'end_lnum relocated')
end)

assert.run_test('each project sees its own review', function()
  local a, fa = make_repo('proja')
  local b = make_repo('projb')
  local data = fresh_data()
  add(a, data, { filename = fa, lnum = 1, end_lnum = 1, kind = 'note', body = 'in a' })
  assert.length(export(a, data), 1, 'a has its comment')
  assert.length(export(b, data), 0, 'b has none')
  assert.equals(qfr(b, data, 'clear').code, 0, 'clear in b')
  assert.length(export(a, data), 1, 'a untouched by clear in b')
end)

assert.run_test('usage errors exit 2 with usage on stderr', function()
  local dir = make_repo('usage')
  local data = fresh_data()
  for _, args in ipairs({ {}, { 'bogus' }, { 'respond' }, { 'respond', 'id' }, { 'export', 'extra' } }) do
    local r = qfr(dir, data, unpack(args))
    local label = table.concat(args, ' ')
    assert.equals(r.code, 2, 'exit 2 for "' .. label .. '"')
    assert.equals(r.stdout, '', 'nothing on stdout for "' .. label .. '"')
    assert.truthy(r.stderr:find('usage', 1, true), 'usage on stderr for "' .. label .. '"')
  end
end)

return assert
