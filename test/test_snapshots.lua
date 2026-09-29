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

assert.run_test('put rewrites a same-size snapshot with the wrong content', function()
  use_dir()
  local sha = snapshots.put({ 'good' })
  local path = store.snapshots_dir() .. '/' .. sha
  write_bytes(path, 'gooX\n')
  snapshots._clear_cache()
  assert.equals(snapshots.put({ 'good' }), sha, 'same sha')
  snapshots._clear_cache()
  same_lines(snapshots.get(sha), { 'good' }, 'repaired')
  assert.equals(read_bytes(path), 'good\n', 'the bytes on disk')
end)

assert.run_test('lines holding a NUL round-trip as one line each, trailing CRs stripped', function()
  use_dir()
  local lines = { 'a', 'x\ny', 'b\r\nc', 'z', 'cr\r\r', '\n' }
  local sha = snapshots.put(lines)
  snapshots._clear_cache()
  same_lines(snapshots.get(sha), { 'a', 'x\ny', 'b\r\nc', 'z', 'cr', '\n' }, 'one line each (trailing CRs stripped)')
  assert.equals(snapshots.hash(lines), sha, 'hash matches put')
  assert.equals(snapshots.hash({ 'a', 'b\r' }), vim.fn.sha256('a\nb\n'), 'ordinary lines hash as before')
  -- NVIM 0.12 buffers give a NUL as "\0", readfile() as "\n": both hash as
  -- the escape stored before, "\r0"
  assert.equals(snapshots.hash({ 'x\0y' }), snapshots.hash({ 'x\ny' }), 'a NUL as "\\0" or "\\n" hashes alike')
  assert.equals(snapshots.hash({ 'x\ny' }), vim.fn.sha256('x\r0y\r\n'), 'the NUL escape is unchanged')
end)

assert.run_test('canonical is idempotent on what get returns', function()
  use_dir()
  for _, line in ipairs({ 'x\r', 'x\r\r', 'x\r\r\r', 'x\r1', 'a\0\r\r', 'a\nb\r\r', 'a\rb\r\r' }) do
    local label = vim.inspect(line)
    local sha = snapshots.put({ line })
    snapshots._clear_cache()
    local got = snapshots.get(sha)
    assert.equals(snapshots.canonical(got), snapshots.canonical({ line }), 'canonical of ' .. label)
    assert.equals(snapshots.hash(got), sha, 'hash of ' .. label)
  end
  -- A CR CR line stored in the old form, escaped as "x\r1\r", reads back as
  -- the same canonical line as the live "x\r\r"
  local old = 'x\r1\r\n'
  local old_sha = vim.fn.sha256(old)
  write_bytes(store.snapshots_dir() .. '/' .. old_sha, old)
  snapshots._clear_cache()
  local got = snapshots.get(old_sha)
  assert.truthy(got, 'old snapshot read')
  assert.equals(snapshots.canonical(got), snapshots.canonical({ 'x\r\r' }), 'old CR CR snapshot')
end)

-- GC: snapshots unreferenced by the review's logs and untouched for a day
local DAY_AGO = os.time() - 25 * 3600

local function backdate(sha)
  vim.uv.fs_utime(store.snapshots_dir() .. '/' .. sha, DAY_AGO, DAY_AGO)
end

local function exists(sha)
  return vim.uv.fs_stat(store.snapshots_dir() .. '/' .. sha) ~= nil
end

-- A comment anchored to a new snapshot of `lines`; returns its id and sha
local function anchored(lines, body)
  local sha = snapshots.put(lines)
  assert.truthy(sha, "snapshot written")
  assert.truthy(store.add({
    filename = vim.fn.tempname(), lnum = 1, kind = 'note', body = body or 'x',
    anchor = { sha = sha, lnum = 1, end_lnum = 1 },
  }), 'added')
  local id
  for _, c in ipairs(store.all()) do
    if c.anchor and c.anchor.sha == sha then id = c.id end
  end
  return id, sha
end

assert.run_test('gc: unreferenced old deleted; fresh, live and trash kept', function()
  use_dir()
  local _, live = anchored({ 'live' })
  local trashed_id, trashed = anchored({ 'trashed' })
  assert.equals(store.remove(trashed_id), 1, 'moved to the trash')
  local old = snapshots.put({ 'old' })
  local fresh = snapshots.put({ 'fresh' })
  local tmp = store.snapshots_dir() .. '/' .. old .. '.tmp.123'
  write_bytes(tmp, 'x')
  vim.uv.fs_utime(tmp, DAY_AGO, DAY_AGO)
  for _, sha in ipairs({ live, trashed, old }) do backdate(sha) end

  assert.equals(store.gc_snapshots(), 1, 'one deleted')
  assert.falsy(exists(old), 'unreferenced old snapshot deleted')
  assert.truthy(exists(fresh), 'unreferenced fresh snapshot kept')
  assert.truthy(exists(live), 'a live comment\'s kept')
  assert.truthy(exists(trashed), 'a trash entry\'s kept')
  assert.truthy(vim.uv.fs_stat(tmp), 'a non-sha file kept')
end)

assert.run_test('gc: a sha in a torn log line still counts; a newer log stops it', function()
  use_dir()
  anchored({ 'something' })
  local torn = snapshots.put({ 'torn' })
  local old = snapshots.put({ 'old' })
  backdate(torn)
  backdate(old)
  local fh = io.open(store.events_dir() .. '/000001.jsonl', 'ab')
  fh:write('{"op":"add","comment":{"anchor":{"sha":"' .. torn:upper() .. '"')
  fh:close()
  assert.equals(store.gc_snapshots(), 1, 'one deleted')
  assert.truthy(exists(torn), 'named only by a torn line: kept')
  assert.falsy(exists(old), 'the unreferenced one deleted')

  use_dir()
  local sha = snapshots.put({ 'future' })
  backdate(sha)
  vim.fn.mkdir(vim.fn.fnamemodify(store.log_path(), ':h'), 'p')
  write_bytes(store.log_path(), '{"op":"header","log_id":"abc","v":99}\n')
  assert.equals(store.gc_snapshots(), 0, 'nothing deleted')
  assert.truthy(exists(sha), 'kept')

  use_dir()
  assert.equals(store.gc_snapshots(), 0, 'no snapshots dir: nothing to do')
end)


assert.run_test('gc: an unreferenced snapshot 25 h old is deleted, 1 h old kept', function()
  use_dir()
  anchored({ 'something' })
  local aged = snapshots.put({ 'aged' })
  local recent = snapshots.put({ 'recent' })
  backdate(aged)
  local hour_ago = os.time() - 3600
  vim.uv.fs_utime(store.snapshots_dir() .. '/' .. recent, hour_ago, hour_ago)
  assert.equals(store.gc_snapshots(), 1, 'one deleted')
  assert.falsy(exists(aged), '25 h old: deleted')
  assert.truthy(exists(recent), '1 h old: kept')
end)

assert.run_test('gc: runs at most once a day, gated by gc.stamp', function()
  use_dir()
  anchored({ 'something' })
  local first = snapshots.put({ 'first' })
  backdate(first)
  assert.equals(store.gc_snapshots(), 1, 'the first run collects')
  assert.falsy(exists(first), 'deleted')
  local stamp = store.snapshots_dir() .. '/gc.stamp'
  assert.truthy(vim.uv.fs_stat(stamp), 'gc.stamp written')
  local second = snapshots.put({ 'second' })
  backdate(second)
  assert.equals(store.gc_snapshots(), 0, 'within a day: a no-op')
  assert.truthy(exists(second), 'kept meanwhile')
  vim.uv.fs_utime(stamp, DAY_AGO, DAY_AGO)
  assert.equals(store.gc_snapshots(), 1, 'a day later: collects again')
  assert.falsy(exists(second), 'deleted')
  assert.truthy(os.time() - vim.uv.fs_stat(stamp).mtime.sec < 3600, 'gc.stamp touched')
end)

assert.run_test('gc: a snapshot named by the newest checkpoint\'s refs is kept', function()
  use_dir()
  anchored({ 'something' })
  assert.truthy(store.save(), 'checkpoint written')
  local cps = vim.fn.glob(store.checkpoints_dir() .. '/*.json', true, true)
  assert.length(cps, 1, 'one checkpoint')
  -- Only the checkpoint names it: its refs cover the segment up to its
  -- offset, which the tail scan does not read again
  local only = snapshots.put({ 'only in the checkpoint' })
  local other = snapshots.put({ 'unreferenced' })
  backdate(only)
  backdate(other)
  local raw, n = read_bytes(cps[1]):gsub('"refs":%[(%]?)', function(close)
    return '"refs":["' .. only .. '"' .. (close == ']' and ']' or ',')
  end)
  assert.equals(n, 1, 'the checkpoint has refs')
  write_bytes(cps[1], raw)
  assert.equals(store.gc_snapshots({ force = true }), 1, 'one deleted')
  assert.truthy(exists(only), 'named by the checkpoint\'s refs: kept')
  assert.falsy(exists(other), 'the unreferenced one deleted')
end)
assert.run_test('gc: no segments and no log.jsonl (events/ unlisted) collects nothing', function()
  use_dir()
  local _, live = anchored({ 'live' })
  local orphan = snapshots.put({ 'orphan' })
  backdate(live)
  backdate(orphan)
  local events = store.events_dir()
  local aside = events .. '.aside'
  assert.truthy(os.rename(events, aside), 'events/ moved aside')
  local stamp = store.snapshots_dir() .. '/gc.stamp'
  assert.falsy(vim.uv.fs_stat(stamp), 'no gc.stamp yet')
  assert.equals(store.gc_snapshots({ force = true }), 0, 'nothing deleted')
  assert.truthy(exists(live), 'the referenced one kept')
  assert.truthy(exists(orphan), 'the orphan kept too')
  assert.falsy(vim.uv.fs_stat(stamp), 'gc.stamp not written')
  os.rename(aside, events)
end)

assert.run_test('gc: a checkpoint with empty refs past the header is not trusted', function()
  use_dir()
  local _, named = anchored({ 'named before the checkpoint' })
  assert.truthy(store.save(), 'checkpoint written')
  local cps = vim.fn.glob(store.checkpoints_dir() .. '/*.json', true, true)
  assert.length(cps, 1, 'one checkpoint')
  -- As a writer whose read of the segment failed would have written it
  local raw, n = read_bytes(cps[1]):gsub('"refs":%b[]', '"refs":[]')
  assert.equals(n, 1, 'the checkpoint has refs')
  write_bytes(cps[1], raw)
  backdate(named)
  assert.equals(store.gc_snapshots({ force = true }), 0, 'nothing deleted')
  assert.truthy(exists(named), 'named before the offset: kept')
end)

config.options.storage_file = original_file
config.options.storage_dir = original_dir
snapshots._clear_cache()
test_helper.cleanup_test_environment()

return assert
