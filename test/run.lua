-- Test runner for quickfix-review
-- Usage: scripts/test.sh [test/test_x.lua ...]
-- (tests refuse to run without the hermetic environment scripts/test.sh sets up)

-- The repo root; test/init.lua moves cwd to a throwaway work dir
local root = vim.env.QFR_TEST_ROOT or vim.fn.getcwd()

print('Running quickfix-review tests...')
print('Repo root:', root)
print('Plugin version check:', vim.fn.readfile(root .. '/lua/quickfix-review/config.lua', '', 1)[1])
print(string.rep('=', 50))

-- Track totals across all test files
local total_passed = 0
local total_failed = 0
local total_pending = 0

-- Run one test file (path relative to the repo root). A file that errors
-- outside assert.run_test (at load time or top level) counts as a failure, so
-- the suite still exits non-zero. Each file starts from the repo root as cwd:
-- the files that don't load test/init.lua (test_utils, test_context) assume it.
local function run_file(path)
  vim.cmd.cd(root)
  local ok, result = pcall(dofile, root .. '/' .. path)
  -- Drain callbacks this file scheduled (e.g. store refreshes), so they don't
  -- fire during a later file's vim.wait and redraw its buffers
  local drained = false
  vim.schedule(function() drained = true end)
  vim.wait(1000, function() return drained end)
  if not ok then
    print(string.format('ERROR: %s failed to run: %s', path, tostring(result)))
    total_failed = total_failed + 1
    return
  end
  total_passed = total_passed + result.passed
  total_failed = total_failed + result.failed
  total_pending = total_pending + (result.pending_count or 0)
  result.reset()
end

-- The full suite, in order
local default_files = {
  -- Utility tests first (no plugin dependency)
  'test/test_utils.lua',
  -- Context capture
  'test/test_context.lua',
  -- Configuration
  'test/test_config.lua',
  -- Comments
  'test/test_comments.lua',
  -- Signs
  'test/test_signs.lua',
  -- Event reducer, event log and lock
  'test/test_reduce.lua',
  'test/test_log.lua',
  'test/test_lock.lua',
  -- Persistence
  'test/test_persistence.lua',
  -- Multi-instance sync
  'test/test_sync.lua',
  -- Log rotation and legacy migration
  'test/test_sealing.lua',
  -- Storage schema and upgrades
  'test/test_schema.lua',
  -- Per-project storage directory
  'test/test_storage_dir.lua',
  -- Snapshot store
  'test/test_snapshots.lua',
  -- Relocation (mapping, then tracking and the outdated state)
  'test/test_track.lua',
  'test/test_relocate.lua',
  -- Setup idempotency
  'test/test_setup.lua',
  -- Quickfix window hooks
  'test/test_qf_window.lua',
  -- Headless entry point for external tools
  'test/test_cli.lua',
}

-- scripts/test.sh passes any file arguments through QFR_TEST_FILES
local files = vim.split(vim.env.QFR_TEST_FILES or '', '%s+', { trimempty = true })
if #files == 0 then files = default_files end
for _, path in ipairs(files) do
  run_file(path)
end

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
if total_pending > 0 then
  print(string.format('Pending (known failures, see [PENDING] above): %d', total_pending))
end

-- Exit with appropriate code for CI
if total_failed > 0 then
  vim.cmd('cquit 1')
end
