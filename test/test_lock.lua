-- Tests for the storage lock (store/lock.lua): flock, and the mkdir fallback
local test_helper = dofile((vim.env.QFR_TEST_ROOT or '.') .. '/test/init.lua')
local assert = dofile(test_helper.root .. '/test/assertions.lua')

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
  local child = vim.system({ vim.v.progpath, '--clean', '-l', holder_script, test_helper.root, loc.flock, loc.lock }, {
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
    assert.equals(vim.fn.isdirectory(loc.lock), 1, 'the mkdir lock is taken inside the flock')
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
  assert.equals(vim.fn.isdirectory(loc.lock), 0, 'the mkdir lock is released')
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

-- A mkdir lock left by a Neovim running older code, next to a flock
local function seed_old_lock(dir, pid)
  vim.fn.mkdir(dir, 'p')
  if pid then write_bytes(dir .. '/pid', tostring(pid) .. '\n') end
end

run_test('under the flock, an old mkdir lock with a dead pid is removed', function()
  local loc = loc_at(vim.fn.tempname())
  local child = vim.system({ 'true' })
  child:wait()
  seed_old_lock(loc.lock, child.pid)
  assert.truthy(lock.with_lock(loc, function() end), 'taken')
  assert.equals(vim.fn.isdirectory(loc.lock), 0, 'the dead lock dir is removed')
  assert.length(vim.fn.glob(loc.lock .. '.stale-*', true, true), 0, 'nothing left aside')
  remove_lock_files(loc)
end)

-- The pid in the lock dir `dir`, or nil
local function pid_in(dir)
  local fh = io.open(dir .. '/pid', 'r')
  if not fh then return nil end
  local pid = tonumber(fh:read('*l') or '')
  fh:close()
  return pid
end

run_test('under the flock, a mkdir lock with a live pid, or a fresh one with none, is waited on and kept', function()
  local loc = loc_at(vim.fn.tempname())
  local live = sleeper().pid
  for _, case in ipairs({
    { 'live pid (with_lock)', live, lock.with_lock },
    { 'live pid (with_both)', live, lock.with_both },
    { 'no pid', nil, lock.with_lock },
  }) do
    seed_old_lock(loc.lock, case[2])
    local ran = false
    local start = uv.hrtime()
    local ok, err = case[3](loc, function() ran = true end)
    local waited = (uv.hrtime() - start) / 1e6
    assert.falsy(ok, case[1] .. ': not taken')
    assert.truthy(tostring(err):find('Timed out', 1, true), case[1] .. ': times out: ' .. tostring(err))
    assert.falsy(ran, case[1] .. ': fn not run')
    assert.truthy(waited >= 900, case[1] .. ': waited about a second, got ' .. waited .. 'ms')
    assert.falsy(lock.held(loc.flock), case[1] .. ': the flock is released')
    assert.equals(vim.fn.isdirectory(loc.lock), 1, case[1] .. ': the lock dir is kept')
    assert.equals(pid_in(loc.lock), case[2], case[1] .. ': with its pid')
    vim.fn.delete(loc.lock, 'rf')
  end
  remove_lock_files(loc)
end)

run_test('under the flock, a mkdir lock naming this process is broken', function()
  local loc = loc_at(vim.fn.tempname())
  seed_old_lock(loc.lock, uv.os_getpid())
  local ran = false
  assert.truthy(lock.with_lock(loc, function() ran = true end), 'taken')
  assert.truthy(ran, 'fn ran')
  assert.equals(vim.fn.isdirectory(loc.lock), 0, 'the lock dir is gone')
  assert.length(vim.fn.glob(loc.lock .. '.stale-*', true, true), 0, 'nothing left aside')
  remove_lock_files(loc)
end)

-- flock's errnos, with the FFI replaced by a fake whose flock fails with a
-- settable errno, and the module reloaded

local notify = require('quickfix-review.notify')
local saved_ffi_e, saved_preload_e = package.loaded.ffi, package.preload.ffi
local errno_ok, errno_err = pcall(function()
  local fake = { errno_value = 0, calls = 0, fail = math.huge }
  local fake_ffi = {
    os = 'Linux',
    cdef = function() end,
    errno = function() return fake.errno_value end,
    C = {
      flock = function(_, op)
        if op ~= 6 then return 0 end -- LOCK_UN
        fake.calls = fake.calls + 1
        if fake.calls <= fake.fail then return -1 end
        return 0
      end,
    },
  }
  package.loaded.ffi = nil
  package.preload.ffi = function() return fake_ffi end
  package.loaded[MODULE] = nil
  local flk = require(MODULE)

  local function reset(errno, fail)
    fake.errno_value, fake.calls, fake.fail = errno, 0, fail or math.huge
  end

  local function capture_notify(fn)
    local calls, original = {}, vim.notify
    vim.notify = function(msg, level) table.insert(calls, { msg = msg, level = level }) end
    local ok, err = pcall(fn)
    vim.notify = original
    if not ok then error(err, 0) end
    return calls
  end

  run_test('a flock refused (EOPNOTSUPP) falls back to the mkdir lock at once, warning once', function()
    assert.equals(flk.backend, 'flock', 'flock is the backend')
    local loc = loc_at(vim.fn.tempname())
    notify.forget('lock-flock:' .. loc.flock)
    reset(95)
    local runs, dir_during = 0, nil
    local ok, waited
    local calls = capture_notify(function()
      local start = uv.hrtime()
      ok = flk.with_lock(loc, function()
        runs = runs + 1
        dir_during = vim.fn.isdirectory(loc.lock)
      end)
      waited = (uv.hrtime() - start) / 1e6
    end)
    assert.truthy(ok, 'taken')
    assert.equals(runs, 1, 'fn ran once')
    assert.truthy(waited < 100, 'no wait, got ' .. waited .. 'ms')
    assert.equals(dir_during, 1, 'under the mkdir lock')
    assert.equals(vim.fn.isdirectory(loc.lock), 0, 'released')
    assert.length(calls, 1, 'one warning')
    assert.equals(calls[1].level, vim.log.levels.WARN, 'at WARN')
    assert.truthy(calls[1].msg:find('errno 95', 1, true), 'naming the errno: ' .. calls[1].msg)
    assert.truthy(calls[1].msg:find('mkdir', 1, true), 'and the fallback: ' .. calls[1].msg)
    local flock_calls = fake.calls
    local calls2 = capture_notify(function()
      assert.truthy(flk.with_lock(loc, function() runs = runs + 1 end), 'taken again')
    end)
    assert.equals(runs, 2, 'fn ran again')
    assert.length(calls2, 0, 'no second warning')
    assert.equals(fake.calls, flock_calls, 'flock not tried again')
    assert.falsy(flk.held(loc.flock), 'flock not held')
    assert.falsy(flk.held(loc.lock), 'mkdir lock not held')
    remove_lock_files(loc)
  end)

  run_test('after a flock fallback, a nested call runs under the outer mkdir lock', function()
    local loc = loc_at(vim.fn.tempname())
    reset(95)
    local inner, pid_after
    capture_notify(function()
      assert.truthy(flk.with_lock(loc, function()
        inner = flk.with_lock(loc, function() return true end)
        local fh = io.open(loc.lock .. '/pid', 'r')
        pid_after = fh and tonumber(fh:read('*l'))
        if fh then fh:close() end
      end), 'taken')
    end)
    assert.truthy(inner, 'the nested call ran')
    assert.equals(pid_after, uv.os_getpid(), 'the outer lock is still this process\'s')
    assert.length(vim.fn.glob(loc.lock .. '.stale-*', true, true), 0, 'not broken aside')
    assert.equals(vim.fn.isdirectory(loc.lock), 0, 'released')
    remove_lock_files(loc)
  end)

  run_test('with_both after a flock refusal runs fn once under the mkdir lock', function()
    local loc = loc_at(vim.fn.tempname())
    reset(38) -- ENOSYS
    local runs = 0
    local ok, a
    local start = uv.hrtime()
    capture_notify(function()
      ok, a = flk.with_both(loc, function()
        runs = runs + 1
        return vim.fn.isdirectory(loc.lock)
      end)
    end)
    local waited = (uv.hrtime() - start) / 1e6
    assert.truthy(ok, 'taken')
    assert.equals(a, 1, 'under the mkdir lock')
    assert.equals(runs, 1, 'fn ran once')
    assert.truthy(waited < 100, 'no wait, got ' .. waited .. 'ms')
    assert.equals(vim.fn.isdirectory(loc.lock), 0, 'released')
    remove_lock_files(loc)
  end)

  run_test('a process that fell back to the mkdir lock excludes a flock with_lock', function()
    local loc = loc_at(vim.fn.tempname())
    reset(0, 0) -- flock succeeds
    -- Process A's flock failed: it holds only the mkdir lock
    local holder = sleeper()
    seed_old_lock(loc.lock, holder.pid)
    local ran = false
    local start = uv.hrtime()
    local ok, err = flk.with_lock(loc, function() ran = true end)
    local waited = (uv.hrtime() - start) / 1e6
    assert.equals(fake.calls, 1, 'the flock was taken')
    assert.falsy(ok, 'not taken')
    assert.truthy(tostring(err):find('Timed out', 1, true), 'times out: ' .. tostring(err))
    assert.truthy(tostring(err):find(loc.lock, 1, true), 'on the mkdir lock: ' .. tostring(err))
    assert.truthy(waited >= 900, 'waited about a second, got ' .. waited .. 'ms')
    assert.falsy(ran, 'fn not run')
    assert.falsy(flk.held(loc.flock), 'the flock is released')
    assert.equals(pid_in(loc.lock), holder.pid, 'the live holder\'s lock is left in place')
    remove_lock_files(loc)
  end)

  run_test('ENOLCK falls back for that call only; the next call tries flock again', function()
    local loc = loc_at(vim.fn.tempname())
    notify.forget('lock-flock:' .. loc.flock)
    reset(37, 1) -- ENOLCK, once
    local first, nested_ran, pid_after
    local calls = capture_notify(function()
      assert.truthy(flk.with_lock(loc, function()
        first = { dir = vim.fn.isdirectory(loc.lock), flock = flk.held(loc.flock), calls = fake.calls }
        -- A nested call runs under the outer mkdir lock, without retrying
        -- flock nor breaking it
        nested_ran = flk.with_lock(loc, function() return true end)
        pid_after = pid_in(loc.lock)
      end), 'first call taken')
    end)
    assert.equals(first.dir, 1, 'first call: under the mkdir lock')
    assert.falsy(first.flock, 'first call: not under the flock')
    assert.equals(first.calls, 1, 'first call: flock tried once')
    assert.truthy(nested_ran, 'the nested call ran')
    assert.equals(fake.calls, 1, 'the nested call did not try flock')
    assert.equals(pid_after, uv.os_getpid(), 'the outer lock is still this process\'s')
    assert.length(vim.fn.glob(loc.lock .. '.stale-*', true, true), 0, 'not broken aside')
    assert.length(calls, 1, 'one warning')
    assert.truthy(calls[1].msg:find('errno 37', 1, true), 'naming the errno: ' .. calls[1].msg)
    local second
    assert.truthy(flk.with_lock(loc, function() second = flk.held(loc.flock) end), 'second call taken')
    assert.equals(fake.calls, 2, 'flock tried again')
    assert.truthy(second, 'second call: under the flock')
    assert.equals(vim.fn.isdirectory(loc.lock), 0, 'released')
    remove_lock_files(loc)
  end)

  run_test('a contended flock (EWOULDBLOCK) is still retried, then times out', function()
    local loc = loc_at(vim.fn.tempname())
    notify.forget('lock-flock:' .. loc.flock)
    reset(11)
    local ran, ok, err = false, nil, nil
    local start = uv.hrtime()
    local calls = capture_notify(function()
      ok, err = flk.with_lock(loc, function() ran = true end)
    end)
    local waited = (uv.hrtime() - start) / 1e6
    assert.falsy(ok, 'not taken')
    assert.truthy(tostring(err):find('Timed out', 1, true), 'times out: ' .. tostring(err))
    assert.truthy(waited >= 900, 'waited about a second, got ' .. waited .. 'ms')
    assert.truthy(fake.calls > 1, 'retried')
    assert.falsy(ran, 'fn not run')
    assert.equals(vim.fn.isdirectory(loc.lock), 0, 'no mkdir lock taken')
    assert.length(calls, 0, 'no warning')
    assert.falsy(flk.held(loc.flock), 'not counted as held')
    remove_lock_files(loc)
  end)

  run_test('a flock interrupted (EINTR) is retried', function()
    local loc = loc_at(vim.fn.tempname())
    reset(4, 1)
    local ran = false
    local calls = capture_notify(function()
      assert.truthy(flk.with_lock(loc, function() ran = true end), 'taken')
    end)
    assert.truthy(ran, 'fn ran')
    assert.equals(fake.calls, 2, 'retried once')
    assert.length(calls, 0, 'no warning')
    assert.equals(vim.fn.isdirectory(loc.lock), 0, 'no mkdir lock taken')
    remove_lock_files(loc)
  end)
end)
package.loaded.ffi, package.preload.ffi = saved_ffi_e, saved_preload_e
package.loaded[MODULE] = lock
kill_children()
if not errno_ok then error(errno_err, 0) end

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
