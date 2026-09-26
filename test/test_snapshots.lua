-- Tests for the content-addressed snapshot store (snapshots.lua)
local test_helper = dofile('test/init.lua')
local assert = dofile('test/assertions.lua')

print('\nRunning snapshot store tests...')

test_helper.setup_test_environment()
local config = require('quickfix-review.config')
local snapshots = require('quickfix-review.snapshots')
local store = require('quickfix-review.store')

local original_file = config.options.storage_file
local original_dir = config.options.storage_dir

-- Use the per-project mode with storage dir `dir` (a fresh temp dir by default)
local function use_dir(dir)
  dir = dir or (vim.fn.tempname() .. '-snapdir')
  config.options.storage_file = nil
  config.options.storage_dir = dir
  snapshots._clear_cache()
  return dir
end

local function write_bytes(path, bytes)
  local fh = io.open(path, 'wb')
  fh:write(bytes)
  fh:close()
end

local function read_bytes(path)
  local fh = io.open(path, 'rb')
  if not fh then return nil end
  local s = fh:read('*a')
  fh:close()
  return s
end

local function entries(dir)
  local names = {}
  for name in vim.fs.dir(dir) do table.insert(names, name) end
  table.sort(names)
  return names
end

local function same_lines(actual, expected, msg)
  assert.truthy(actual, msg .. ' (got nil)')
  assert.equals(vim.inspect(actual), vim.inspect(expected), msg)
end

assert.run_test('put/get round-trip in <storage_dir>/snapshots', function()
  local dir = use_dir()
  local lines = { 'local x = 1', '', 'return x' }
  local sha, err = snapshots.put(lines)
  assert.equals(err, nil, 'no error')
  assert.equals(sha, snapshots.hash(lines), 'put returns the hash')
  assert.equals(#sha, 64, 'sha256 hex')
  assert.equals(store.snapshots_dir(), vim.fn.fnamemodify(dir, ':p'):gsub('/$', '') .. '/snapshots', 'dir')
  assert.equals(read_bytes(store.snapshots_dir() .. '/' .. sha), 'local x = 1\n\nreturn x\n', 'canonical content')
  snapshots._clear_cache()
  same_lines(snapshots.get(sha), lines, 'read back from disk')
  same_lines(snapshots.get(sha), lines, 'read back from cache')
end)

assert.run_test('identical content is stored once and its mtime touched', function()
  use_dir()
  local sha = snapshots.put({ 'a', 'b' })
  local path = store.snapshots_dir() .. '/' .. sha
  vim.uv.fs_utime(path, 1000, 1000)
  assert.equals(snapshots.put({ 'a', 'b' }), sha, 'same sha')
  assert.length(entries(store.snapshots_dir()), 1, 'one file')
  assert.truthy(vim.uv.fs_stat(path).mtime.sec > 1000, 'mtime touched')
end)

assert.run_test('CRLF and a missing final newline hash like LF content', function()
  use_dir()
  local lf = snapshots.hash({ 'one', 'two', 'three' })
  assert.equals(snapshots.hash({ 'one\r', 'two\r', 'three\r' }), lf, 'buffer lines with CR')
  local tmp = vim.fn.tempname()
  write_bytes(tmp, 'one\r\ntwo\r\nthree\r\n')
  assert.equals(snapshots.hash(vim.fn.readfile(tmp)), lf, 'readfile of CRLF')
  -- readfile() keeps the CR of a last line with no NL after it
  write_bytes(tmp, 'one\r\ntwo\r\nthree\r')
  assert.equals(snapshots.hash(vim.fn.readfile(tmp)), lf, 'readfile of CRLF, no final newline')
  write_bytes(tmp, 'one\ntwo\nthree')
  assert.equals(snapshots.hash(vim.fn.readfile(tmp)), lf, 'readfile of LF, no final newline')
  write_bytes(tmp, '\239\187\191one\ntwo\nthree\n')
  assert.equals(snapshots.hash(vim.fn.readfile(tmp)), lf, 'readfile of LF with a BOM')
  os.remove(tmp)

  local sha = snapshots.put({ 'one\r', 'two\r', 'three\r' })
  assert.equals(sha, lf, 'put of CRLF lines')
  assert.equals(read_bytes(store.snapshots_dir() .. '/' .. sha), 'one\ntwo\nthree\n', 'stored as LF')
  assert.length(entries(store.snapshots_dir()), 1, 'one file')
end)

assert.run_test('corrupt snapshot file: get returns nil and warns', function()
  use_dir()
  local sha = snapshots.put({ 'good' })
  local path = store.snapshots_dir() .. '/' .. sha
  write_bytes(path, 'bad\n')
  snapshots._clear_cache()
  local warnings = {}
  local original = vim.notify
  vim.notify = function(msg, level) table.insert(warnings, { msg = msg, level = level }) end
  local got = snapshots.get(sha)
  local again = snapshots.get(sha)
  vim.notify = original
  assert.equals(got, nil, 'corrupt -> nil')
  assert.equals(again, nil, 'still nil')
  assert.length(warnings, 1, 'warned once')
  assert.equals(warnings[1].level, vim.log.levels.WARN, 'a warning')

  -- A truncated file (wrong size) is rewritten by the next put
  assert.equals(snapshots.put({ 'good' }), sha, 'put again')
  same_lines(snapshots.get(sha), { 'good' }, 'repaired')
end)

assert.run_test('missing or malformed sha: get returns nil', function()
  use_dir()
  assert.equals(snapshots.get(snapshots.hash({ 'never stored' })), nil, 'missing')
  assert.equals(snapshots.get('../../etc/passwd'), nil, 'not a sha')
  assert.equals(snapshots.get(nil), nil, 'nil')
end)

assert.run_test('no tmp files left behind', function()
  use_dir()
  for i = 1, 5 do snapshots.put({ 'file ' .. i }) end
  snapshots.put({ 'file 1' })
  for _, name in ipairs(entries(store.snapshots_dir())) do
    assert.matches(name, '^%x+$', 'only sha-named files')
  end
  assert.length(entries(store.snapshots_dir()), 5, 'five snapshots')
end)

assert.run_test('empty content and a single empty line are the same snapshot', function()
  use_dir()
  local sha = snapshots.put({})
  assert.equals(snapshots.put({ '' }), sha, 'same sha')
  same_lines(snapshots.get(sha), { '' }, 'reads back as one empty line')
end)

assert.run_test('the dir is resolved per call; the cache does not cross dirs', function()
  local a = use_dir()
  local sha = snapshots.put({ 'in a' })
  same_lines(snapshots.get(sha), { 'in a' }, 'cached in a')
  use_dir()
  assert.falsy(store.snapshots_dir():find(a, 1, true), 'switched dir')
  assert.equals(snapshots.get(sha), nil, 'not served from a')
  use_dir(a)
  same_lines(snapshots.get(sha), { 'in a' }, 'back in a')
end)

assert.run_test('get returns a copy', function()
  use_dir()
  local sha = snapshots.put({ 'x' })
  local lines = snapshots.get(sha)
  lines[1] = 'changed'
  same_lines(snapshots.get(sha), { 'x' }, 'cache unchanged')
end)

assert.run_test('storage_file: snapshots in <storage_file>.snapshots', function()
  config.options.storage_file = test_helper.storage_file
  config.options.storage_dir = original_dir
  snapshots._clear_cache()
  assert.equals(store.snapshots_dir(), test_helper.storage_file .. '.snapshots', 'dir')
  local sha = snapshots.put({ 'legacy' })
  same_lines(snapshots.get(sha), { 'legacy' }, 'round-trip')
end)

assert.run_test('a dir that cannot be created: put returns nil and a message', function()
  local blocker = vim.fn.tempname() .. '-file'
  write_bytes(blocker, 'x')
  use_dir(blocker .. '/sub')
  local sha, err = snapshots.put({ 'x' })
  assert.equals(sha, nil, 'no sha')
  assert.truthy(type(err) == 'string' and err:find('Could not', 1, true), 'message: ' .. tostring(err))
  os.remove(blocker)
end)

config.options.storage_file = original_file
config.options.storage_dir = original_dir
snapshots._clear_cache()
test_helper.cleanup_test_environment()

return assert
