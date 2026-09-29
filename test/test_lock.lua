-- Tests for the storage lock (store/lock.lua): flock, and the mkdir fallback
local test_helper = dofile('test/init.lua')
local assert = dofile('test/assertions.lua')

print('\nRunning storage lock tests...')

test_helper.setup_test_environment()
local config = require('quickfix-review.config')
local journal = require('quickfix-review.store.journal')
local location = require('quickfix-review.store.location')
local lock = require('quickfix-review.store.lock')
local uv = vim.uv or vim.loop

local MODULE = 'quickfix-review.store.lock'

local function write_bytes(path, content, mode)
  local fh = io.open(path, mode or 'wb')
  assert.truthy(fh, 'can open ' .. path)
  fh:write(content)
  fh:close()
end

local function read_bytes(path)
  local fh = io.open(path, 'rb')
  if not fh then return nil end
  local data = fh:read('*a')
  fh:close()
  return data
end

-- Children a test started, killed (and reaped) after it however it ends, so
-- a failing test never leaks one
local children = {}

local function kill_children()
  for _, child in ipairs(children) do
    pcall(child.kill, child, 9)
    pcall(child.wait, child, 5000)
  end
  children = {}
end

local function run_test(name, fn)
  assert.run_test(name, function()
    local ok, err = pcall(fn)
    kill_children()
    if not ok then error(err, 0) end
  end)
end

local function sleeper()
  local child = vim.system({ 'sleep', '30' })
  table.insert(children, child)
  return child
end

-- A loc-shaped table for the lock of a review stored at `base`
local function loc_at(base)
  return { flock = base .. '.journal.lock', lock = base .. '.lock', log = base .. '.log.jsonl' }
end

-- The location of a review kept in the explicit storage file `file`
local function resolve_for(file)
  local original = config.options.storage_file
  config.options.storage_file = file
  local ok, loc = pcall(location.resolve)
  config.options.storage_file = original
  if not ok then error(loc, 0) end
  return loc
end

-- A child Neovim that takes the lock of `loc` and holds it (for 30 s), ready
-- once this returns. Killed after the test (see run_test).
local holder_script = vim.fn.tempname() .. '-holder.lua'
vim.fn.writefile({
  'local rtp, flock, lockdir = arg[1], arg[2], arg[3]',
  'vim.opt.rtp:prepend(rtp)',
  'local lock = require("quickfix-review.store.lock")',
  'local ok, err = lock.with_lock({ flock = flock, lock = lockdir }, function()',
  '  io.stdout:write("ready " .. lock.backend .. "\\n")',
  '  io.stdout:flush()',
  '  vim.uv.sleep(30000)',
  'end)',
  'io.stderr:write("not taken: " .. tostring(err) .. "\\n")',
}, holder_script)

local function hold_in_child(loc)
  local ready = nil
  local child = vim.system({ vim.v.progpath, '--clean', '-l', holder_script, vim.fn.getcwd(), loc.flock, loc.lock }, {
    stdout = function(_, data)
      if data and data:find('ready') then ready = data:match('ready (%a+)') end
    end,
  })
  table.insert(children, child)
  assert.truthy(vim.wait(10000, function() return ready ~= nil end, 10), 'the child took the lock')
  assert.equals(ready, 'flock', 'the child uses flock')
  return child
end

local function remove_lock_files(loc)
  os.remove(loc.flock)
  vim.fn.delete(loc.lock, 'rf')
end

run_test('flock is the backend where the FFI is available', function()
  if vim.fn.has('win32') == 1 then return end
  assert.equals(lock.backend, 'flock', 'flock')
end)

run_test('the flock runs fn, releases it, re-raises its errors, and nests', function()
  local loc = loc_at(vim.fn.tempname())
  write_bytes(loc.flock, 'left alone\n')
  local ok, a, b = lock.with_lock(loc, function()
    assert.truthy(lock.held(loc.flock), 'held during fn')
    -- A nested call on the same lock runs under it
    local nested, x = lock.with_lock(loc, function() return 'inner' end)
    assert.truthy(nested, 'nested call runs')
    assert.equals(x, 'inner', 'with its result')
    assert.truthy(lock.held(loc.flock), 'still held after the nested call')
    return 1, 2
  end)
  assert.truthy(ok, 'locked')
  assert.equals(a, 1, 'first result')
  assert.equals(b, 2, 'second result')
  assert.falsy(lock.held(loc.flock), 'released')
  local raised, err = pcall(lock.with_lock, loc, function() error('boom', 0) end)
  assert.falsy(raised, 'error re-raised')
  assert.equals(err, 'boom', 'as it was')
  assert.falsy(lock.held(loc.flock), 'released after an error')
  assert.equals(read_bytes(loc.flock), 'left alone\n', 'the lock file is neither truncated nor written')
  assert.equals(vim.fn.isdirectory(loc.lock), 0, 'no mkdir lock taken')
  remove_lock_files(loc)
end)

run_test('a holder killed with kill -9 releases the lock at once', function()
  local loc = loc_at(vim.fn.tempname())
  local child = hold_in_child(loc)
  child:kill(9)
  child:wait(5000)
  local start = uv.hrtime()
  local ran = false
  local ok = lock.with_lock(loc, function() ran = true end)
  local waited = (uv.hrtime() - start) / 1e6
  assert.truthy(ok, 'taken')
  assert.truthy(ran, 'fn ran')
  assert.truthy(waited < 100, 'within 100 ms, got ' .. waited .. 'ms')
  remove_lock_files(loc)
end)

run_test('a live holder is waited on, then times out', function()
  local loc = loc_at(vim.fn.tempname())
  hold_in_child(loc)
  local start = uv.hrtime()
  local ran = false
  local ok, err = lock.with_lock(loc, function() ran = true end)
  local waited = (uv.hrtime() - start) / 1e6
  assert.falsy(ok, 'not taken')
  assert.truthy(tostring(err):find('Timed out', 1, true), 'times out: ' .. tostring(err))
  assert.falsy(ran, 'fn not run')
  assert.falsy(lock.held(loc.flock), 'not counted as held')
  assert.truthy(waited >= 900, 'waited about a second, got ' .. waited .. 'ms')
  kill_children()
  assert.truthy(lock.with_lock(loc, function() end), 'taken once the holder is gone')
  remove_lock_files(loc)
end)

run_test('holding one review\'s lock does not skip locking another\'s', function()
  local dir = vim.fn.tempname() .. '-reviews'
  vim.fn.mkdir(dir, 'p')
  local loc_a, loc_b = resolve_for(dir .. '/a.json'), resolve_for(dir .. '/b.json')
  assert.truthy(loc_a.flock ~= loc_b.flock, 'distinct lock files: ' .. loc_a.flock)
  hold_in_child(loc_b)
  local ran_b = false
  local ok, got, err = journal.locked(loc_a, function()
    assert.truthy(lock.held(loc_a.flock), 'A held')
    return journal.locked(loc_b, function() ran_b = true end)
  end)
  assert.truthy(ok, 'A taken')
  assert.falsy(got, 'B not taken while another process holds it')
  assert.truthy(tostring(err):find('Timed out', 1, true), 'times out: ' .. tostring(err))
  assert.falsy(ran_b, 'B\'s fn not run')
  kill_children()
  vim.fn.delete(dir, 'rf')
end)

-- The mkdir fallback, with the FFI made unavailable and the module reloaded

local saved_ffi, saved_preload = package.loaded.ffi, package.preload.ffi
local fallback_ok, fallback_err = pcall(function()
  package.loaded.ffi = nil
  package.preload.ffi = function() error('ffi made unavailable by test_lock.lua') end
  package.loaded[MODULE] = nil
  local fallback = require(MODULE)

  local function with_lock(dir, fn)
    return fallback.with_lock({ lock = dir, flock = dir .. '.journal.lock' }, fn)
  end

  run_test('without the FFI, the mkdir lock is used', function()
    assert.equals(fallback.backend, 'mkdir', 'mkdir')
    local dir = vim.fn.tempname() .. '-lock'
    local nested
    assert.truthy(with_lock(dir, function()
      assert.equals(vim.fn.isdirectory(dir), 1, 'the lock dir is made')
      assert.truthy(fallback.held(dir), 'held')
      nested = with_lock(dir, function() return true end)
    end), 'taken')
    assert.truthy(nested, 'a nested call runs under it')
    assert.falsy(uv.fs_stat(dir .. '.journal.lock'), 'no flock file made')
  end)

  local function seed_lock(dir, pid)
    vim.fn.mkdir(dir, 'p')
    write_bytes(dir .. '/pid', tostring(pid) .. '\n')
  end

  -- The pid in the lock `dir`, or nil
  local function read_pid_of(dir)
    local fh = io.open(dir .. '/pid', 'r')
    if not fh then return nil end
    local pid = tonumber(fh:read('*l') or '')
    fh:close()
    return pid
  end

  run_test('the lock runs fn, releases it, and re-raises its errors', function()
    local dir = vim.fn.tempname() .. '-lock'
    local ok, a, b = with_lock(dir, function() return 1, 2 end)
    assert.truthy(ok, 'locked')
    assert.equals(a, 1, 'first result')
    assert.equals(b, 2, 'second result')
    assert.equals(vim.fn.isdirectory(dir), 0, 'released')
    local raised = pcall(with_lock, dir, function() error('boom') end)
    assert.falsy(raised, 'error re-raised')
    assert.equals(vim.fn.isdirectory(dir), 0, 'released after an error')
  end)

  run_test('a lock left by a dead process or by this one is broken', function()
    local dir = vim.fn.tempname() .. '-lock'
    local child = vim.system({ 'true' })
    child:wait()
    seed_lock(dir, child.pid)
    assert.truthy(with_lock(dir, function() end), 'dead holder: broken')
    seed_lock(dir, uv.os_getpid())
    assert.truthy(with_lock(dir, function() end), 'own pid (a crash before unlock): broken')
    assert.equals(vim.fn.isdirectory(dir), 0, 'released')
  end)

  run_test('a broken lock leaves nothing aside, and the new holder\'s pid is in it', function()
    local dir = vim.fn.tempname() .. '-lock'
    local child = vim.system({ 'true' })
    child:wait()
    seed_lock(dir, child.pid)
    local held
    assert.truthy(with_lock(dir, function()
      local fh = io.open(dir .. '/pid', 'r')
      held = fh and tonumber(fh:read('*l'))
      if fh then fh:close() end
    end), 'broken and taken')
    assert.equals(held, uv.os_getpid(), 'this process holds it')
    assert.length(vim.fn.glob(dir .. '.stale-*', true, true), 0, 'no stale lock left aside')
    assert.equals(vim.fn.isdirectory(dir), 0, 'released')
  end)

  run_test('a lock moved away by a breaker before its pid is written is taken again', function()
    local dir = vim.fn.tempname() .. '-lock'
    local original_open = io.open
    local moved = false
    io.open = function(path, mode)
      if not moved and path == dir .. '/pid' and mode == 'w' then
        moved = true
        uv.fs_rename(dir, dir .. '.stale-test')
      end
      return original_open(path, mode)
    end
    local runs, held = 0, nil
    local ok, a, b = pcall(with_lock, dir, function()
      runs = runs + 1
      local fh = original_open(dir .. '/pid', 'r')
      held = fh and tonumber(fh:read('*l'))
      if fh then fh:close() end
    end)
    io.open = original_open
    vim.fn.delete(dir .. '.stale-test', 'rf')
    assert.truthy(ok, 'no error raised: ' .. tostring(a))
    assert.truthy(moved, 'the lock was moved away once')
    assert.equals(a, true, 'taken on retry: ' .. tostring(b))
    assert.equals(runs, 1, 'fn ran once')
    assert.equals(held, uv.os_getpid(), 'this process holds it')
    assert.equals(vim.fn.isdirectory(dir), 0, 'released')
  end)

  run_test('a stale lock whose pid changed since it was judged is not broken', function()
    local dir = vim.fn.tempname() .. '-lock'
    local child = vim.system({ 'true' })
    child:wait()
    seed_lock(dir, child.pid)
    local holder = sleeper()
    -- Between stale() reading the dead pid and break_lock re-reading it, the
    -- lock is broken and retaken by a live process
    local original_kill = uv.kill
    uv.kill = function(pid, sig)
      if pid == child.pid then write_bytes(dir .. '/pid', tostring(holder.pid) .. '\n') end
      return original_kill(pid, sig)
    end
    local ok, taken = pcall(with_lock, dir, function() error('must not run') end)
    uv.kill = original_kill
    holder:kill(9)
    local left = vim.fn.isdirectory(dir)
    vim.fn.delete(dir, 'rf')
    assert.truthy(ok, 'no error raised')
    assert.falsy(taken, 'not taken')
    assert.equals(left, 1, 'the retaken lock is left alone')
    assert.length(vim.fn.glob(dir .. '.stale-*', true, true), 0, 'nothing moved aside')
  end)

  run_test('a stale lock that can never be broken times out rather than spinning', function()
    local dir = vim.fn.tempname() .. '-lock'
    local child = vim.system({ 'true' })
    child:wait()
    seed_lock(dir, child.pid)
    -- Every rename (of the stale lock aside) fails; after LIMIT calls the real
    -- one is back, so a regression breaks the lock instead of hanging the suite
    local LIMIT = 1000000
    local original_rename, calls = uv.fs_rename, 0
    uv.fs_rename = function(a, b)
      calls = calls + 1
      if calls > LIMIT then return original_rename(a, b) end
      return nil, 'EPERM: operation not permitted', 'EPERM'
    end
    local start = uv.hrtime()
    local ran = false
    local ok, taken, err = pcall(with_lock, dir, function() ran = true end)
    local waited = (uv.hrtime() - start) / 1e6
    uv.fs_rename = original_rename
    vim.fn.delete(dir, 'rf')
    assert.truthy(ok, 'no error raised: ' .. tostring(taken))
    assert.falsy(taken, 'not taken')
    assert.truthy(tostring(err):find('Timed out', 1, true), 'times out: ' .. tostring(err))
    assert.falsy(ran, 'fn not run')
    assert.truthy(calls <= LIMIT, 'gave up before the rename was restored (' .. calls .. ' calls)')
    assert.truthy(waited < 3000, 'within about the wait, got ' .. waited .. 'ms')
  end)

  run_test('a holder whose lock was broken meanwhile leaves the new holder\'s lock', function()
    local dir = vim.fn.tempname() .. '-lock'
    local holder = sleeper()
    local ok, taken = pcall(with_lock, dir, function()
      -- Judged stale while held: broken (moved aside) and taken by another
      -- process before this one is done
      assert.truthy(os.rename(dir, dir .. '.gone'), 'moved aside')
      seed_lock(dir, holder.pid)
    end)
    local left = vim.fn.isdirectory(dir)
    local fh = io.open(dir .. '/pid', 'r')
    local pid = fh and tonumber(fh:read('*l'))
    if fh then fh:close() end
    holder:kill(9)
    vim.fn.delete(dir, 'rf')
    vim.fn.delete(dir .. '.gone', 'rf')
    assert.truthy(ok, 'no error raised: ' .. tostring(taken))
    assert.equals(left, 1, 'the other holder\'s lock is left')
    assert.equals(pid, holder.pid, 'with its pid')
  end)

  run_test('a live lock is waited on, then times out, however old it is', function()
    local dir = vim.fn.tempname() .. '-lock'
    local holder = sleeper()
    seed_lock(dir, holder.pid)
    local start = uv.hrtime()
    local ok, err = with_lock(dir, function() error('must not run') end)
    local waited = (uv.hrtime() - start) / 1e6
    assert.falsy(ok, 'not taken')
    assert.truthy(err:find('Timed out', 1, true), 'times out: ' .. tostring(err))
    assert.truthy(waited >= 900, 'waited about a second, got ' .. waited .. 'ms')
    assert.equals(vim.fn.isdirectory(dir), 1, 'the live lock is left alone')

    -- A holder paused (or rendering slowly) past STALE_SECONDS is still alive
    local old = os.time() - 60
    uv.fs_utime(dir, old, old)
    local ok2, err2 = with_lock(dir, function() error('must not run') end)
    local pid = read_pid_of(dir)
    holder:kill(9)
    holder:wait()
    vim.fn.delete(dir, 'rf')
    assert.falsy(ok2, 'an old lock with a live holder is not taken')
    assert.truthy(tostring(err2):find('Timed out', 1, true), 'times out: ' .. tostring(err2))
    assert.equals(pid, holder.pid, 'the live holder\'s lock is left in place')
  end)

  run_test('an old lock with a dead pid, or with no pid, is broken', function()
    local old = os.time() - 60
    local dir = vim.fn.tempname() .. '-lock'
    local child = vim.system({ 'true' })
    child:wait()
    seed_lock(dir, child.pid)
    uv.fs_utime(dir, old, old)
    assert.truthy(with_lock(dir, function() end), 'old, dead holder: broken')
    assert.equals(vim.fn.isdirectory(dir), 0, 'released')

    -- A holder that crashed between its mkdir and writing the pid
    vim.fn.mkdir(dir, 'p')
    uv.fs_utime(dir, old, old)
    assert.truthy(with_lock(dir, function() end), 'old, no pid: broken')
    assert.equals(vim.fn.isdirectory(dir), 0, 'released')
  end)

  run_test('a fresh lock with no pid yet is waited on', function()
    local dir = vim.fn.tempname() .. '-lock'
    vim.fn.mkdir(dir, 'p')
    local ok, err = with_lock(dir, function() error('must not run') end)
    local left = vim.fn.isdirectory(dir)
    vim.fn.delete(dir, 'rf')
    assert.falsy(ok, 'not taken')
    assert.truthy(tostring(err):find('Timed out', 1, true), 'times out: ' .. tostring(err))
    assert.equals(left, 1, 'the dir is left')
  end)
end)
package.loaded.ffi, package.preload.ffi = saved_ffi, saved_preload
package.loaded[MODULE] = lock
kill_children()
os.remove(holder_script)
if not fallback_ok then error(fallback_err, 0) end

test_helper.cleanup_test_environment()

return assert
