# Quickfix Review Testing

This directory contains tests for the quickfix-review plugin.

## Running Tests

### Run All Tests

```bash
scripts/test.sh
```

The script sets up a hermetic environment, then runs this command from the repository root and exits with its status (non-zero if any test fails):

```bash
nvim --headless --clean -c 'lua dofile("test/run.lua")' -c 'qall'
```

Check the exit code to determine pass/fail:
```bash
scripts/test.sh && echo "PASSED" || echo "FAILED"
```

**Always go through `scripts/test.sh`.** It creates a throwaway directory and exports:

- `XDG_DATA_HOME` pointing into it, so `stdpath('data')` (the default storage dir and the legacy global file) never touches your real reviews;
- `QFR_TEST_WORKDIR`, a throwaway working directory that `test/init.lua` changes into, so files the tests write by relative path (`test_file.txt`) never land in the repository;
- `QFR_TEST_ROOT`, the repository root, which `test/init.lua` prepends to the runtime path so this checkout (not an installed copy) is loaded;
- `QFR_TEST_HERMETIC=1`. `test/init.lua` refuses to run without it, so running a test file directly with `nvim` fails immediately instead of touching real data.

The script also passes `--clean`, so Neovim does not load your `init.lua` and installed plugins (possibly including an installed copy of this plugin), which would change options, signs and highlights and make results depend on your personal setup.

### Verifying Plugin Version

The test output includes a "Plugin version check" line that shows the first line of the config file. This confirms that the checkout's plugin is being tested, not an installed version.

### Run Individual Test Files

Pass test files (relative to the repository root) to run only those:

```bash
# Utility function tests
scripts/test.sh test/test_utils.lua

# Configuration tests
scripts/test.sh test/test_config.lua

# Comment add/delete tests
scripts/test.sh test/test_comments.lua

# Sign placement tests
scripts/test.sh test/test_signs.lua

# Save/load persistence tests
scripts/test.sh test/test_persistence.lua

# Several files, in the given order
scripts/test.sh test/test_migrate.lua test/test_utils.lua
```

### Interactive Debugging

For debugging failing tests in a visible Neovim, recreate the environment `scripts/test.sh` sets up (never point `XDG_DATA_HOME` at your real data directory):

```bash
tmp=$(mktemp -d); mkdir "$tmp/data" "$tmp/work"
XDG_DATA_HOME="$tmp/data" QFR_TEST_WORKDIR="$tmp/work" QFR_TEST_ROOT="$PWD" QFR_TEST_HERMETIC=1 \
  nvim --clean -c 'lua dofile("test/test_comments.lua")'
```

## Test Files

| File | Description |
|------|-------------|
| `assertions.lua` | Minimal assertion library with pass/fail tracking |
| `init.lua` | Test initialization and helper functions |
| `run.lua` | Test runner that executes all test files |
| `test_utils.lua` | Tests for utility functions (files_match, etc.) |
| `test_config.lua` | Tests for configuration (comment_types validation, export legend, type order) |
| `test_comments.lua` | Tests for adding, deleting, and managing comments |
| `test_signs.lua` | Tests for sign placement on single and multiline comments |
| `test_persistence.lua` | Tests for save/load functionality |
| `test_track.lua` | Tests for mapping a comment's range through a diff (pure relocation core) |
| `test_relocate.lua` | Tests for comments following file changes and the outdated state |
| `test_cli.lua` | Tests for the headless entry point (`scripts/qfr.lua`): export, respond and clear run as separate `nvim --clean -l` processes |

## Writing New Tests

### Basic Structure

```lua
local test_helper = dofile((vim.env.QFR_TEST_ROOT or '.') .. '/test/init.lua')
local assert = dofile(test_helper.root .. '/test/assertions.lua')

print('\nRunning my tests...')

local qf = test_helper.setup_test_environment()
local test_file = test_helper.create_test_file([[
line 1
line 2
line 3
]])

assert.run_test('my test name', function()
  -- Test code here
  assert.equals(actual, expected, 'description')
end)

test_helper.cleanup_test_environment()
return assert
```

### Available Assertions

```lua
assert.equals(actual, expected, msg)      -- Equality check
assert.not_equals(actual, expected, msg)  -- Inequality check
assert.contains(tbl, value, msg)          -- Table contains value
assert.matches(str, pattern, msg)         -- String pattern match
assert.truthy(value, msg)                 -- Value is truthy
assert.falsy(value, msg)                  -- Value is falsy
assert.length(tbl, expected, msg)         -- Table length check
```

### Adding to Test Runner

Add your test file to the `default_files` list in `run.lua`:

```lua
local default_files = {
  -- ...
  'test/test_myfeature.lua',
}
```

## Test Environment

The test environment:
- Mocks `vim.fn.input()` to return "Test comment"
- Disables all keymaps to avoid conflicts
- Uses simple ASCII signs (!, ?, N, +) instead of emoji
- Clears quickfix list and signs between test files
- Runs in a throwaway working directory and data home (see above), so test files never land in the repository

## CI Integration

The test runner exits with code 1 if any tests fail, and `scripts/test.sh` propagates that code, so CI only needs:

```bash
scripts/test.sh
```
