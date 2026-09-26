-- Test runner for quickfix-review
-- Usage: scripts/test.sh  (or: nvim --headless --clean -c 'lua dofile("test/run.lua")' -c 'qall')

print('Running quickfix-review tests...')
print('Working directory:', vim.fn.getcwd())
print('Plugin version check:', vim.fn.readfile('lua/quickfix-review/config.lua', '', 1)[1])
print(string.rep('=', 50))

-- Track totals across all test files
local total_passed = 0
local total_failed = 0

-- Run one test file. A file that errors outside assert.run_test (at load time
-- or top level) counts as a failure, so the suite still exits non-zero.
local function run_file(path)
  local ok, result = pcall(dofile, path)
  if not ok then
    print(string.format('ERROR: %s failed to run: %s', path, tostring(result)))
    total_failed = total_failed + 1
    return
  end
  total_passed = total_passed + result.passed
  total_failed = total_failed + result.failed
  result.reset()
end

-- Run utility tests first (no plugin dependency)
run_file('test/test_utils.lua')

-- Run context capture tests
run_file('test/test_context.lua')

-- Run configuration tests
run_file('test/test_config.lua')

-- Run comment tests
run_file('test/test_comments.lua')

-- Run sign tests
run_file('test/test_signs.lua')

-- Run event reducer and event log tests
run_file('test/test_reduce.lua')
run_file('test/test_log.lua')

-- Run persistence tests
run_file('test/test_persistence.lua')

-- Run multi-instance sync tests
run_file('test/test_sync.lua')

-- Run storage schema and upgrade tests
run_file('test/test_schema.lua')

-- Run per-project storage directory tests
run_file('test/test_storage_dir.lua')

-- Run snapshot store tests
run_file('test/test_snapshots.lua')

-- Run relocation tests (mapping, then tracking and the outdated state)
run_file('test/test_track.lua')
run_file('test/test_relocate.lua')

-- Run setup idempotency tests
run_file('test/test_setup.lua')

-- Run quickfix window hook tests
run_file('test/test_qf_window.lua')

-- Final summary
print('')
print(string.rep('=', 50))
print('FINAL RESULTS')
print(string.rep('=', 50))

if total_failed == 0 then
  print(string.format('All tests passed: %d/%d', total_passed, total_passed + total_failed))
else
  print(string.format('Tests: %d passed, %d FAILED', total_passed, total_failed))
end

-- Exit with appropriate code for CI
if total_failed > 0 then
  vim.cmd('cquit 1')
end
