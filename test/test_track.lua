-- Tests for track.lua's pure core: mapping a comment's range through a diff
local test_helper = dofile('test/init.lua')
local assert = dofile('test/assertions.lua')

print('\nRunning relocation mapping tests...')

test_helper.setup_test_environment()
local track = require('quickfix-review.track')

-- map_range over a comment on lines 4-6 of a 10-line file
local function check(name, hunks, lnum, end_lnum, state)
  assert.run_test(name, function()
    local l, e, s = track.map_range(hunks, 4, 6)
    assert.equals(l, lnum, 'lnum')
    assert.equals(e, end_lnum, 'end_lnum')
    assert.equals(s, state, 'state')
  end)
end

check('insert 2 lines above: shifted down', { { 1, 0, 2, 2 } }, 6, 8, 'shifted')
check('delete a line above: shifted up', { { 2, 1, 1, 0 } }, 3, 5, 'shifted')
check('change a line inside: outdated', { { 5, 1, 5, 1 } }, 4, 6, 'outdated')
check('pure insertion inside: outdated', { { 4, 0, 5, 1 } }, 4, 7, 'outdated')
check('insertion right after the end: current', { { 6, 0, 7, 1 } }, 4, 6, 'current')
check('insertion right before the start: shifted, not outdated', { { 3, 0, 4, 1 } }, 5, 7, 'shifted')
check('deletion of the line just before the start: shifted, not outdated', { { 3, 1, 2, 0 } }, 3, 5, 'shifted')
check('deletion of the line just after the end: current', { { 7, 1, 6, 0 } }, 4, 6, 'current')
check('whole range deleted: outdated, collapsed to one line', { { 4, 3, 3, 0 } }, 3, 3, 'outdated')
check('change after the range: current', { { 9, 1, 9, 1 } }, 4, 6, 'current')
check('change of the first line: outdated', { { 4, 1, 4, 1 } }, 4, 6, 'outdated')
check('no hunks: current', {}, 4, 6, 'current')
check('insertion above and change after: shifted', { { 1, 0, 2, 1 }, { 9, 1, 10, 1 } }, 5, 7, 'shifted')

assert.run_test('whole file deleted: collapsed to line 1', function()
  local l, e, s = track.map_range({ { 1, 10, 0, 0 } }, 4, 6)
  assert.equals(l, 1, 'lnum')
  assert.equals(e, 1, 'end_lnum')
  assert.equals(s, 'outdated', 'state')
end)

assert.run_test('a single line maps through insertions and deletions', function()
  assert.equals(track.map_line({ { 0, 0, 1, 3 } }, 1), 4, 'insert 3 at the top')
  assert.equals(track.map_line({ { 2, 2, 1, 0 } }, 5), 3, 'delete 2 above')
  local l, touched = track.map_line({ { 2, 2, 2, 1 } }, 3)
  assert.equals(l, 2, 'second of 2 changed lines, replaced by 1: its last line')
  assert.truthy(touched, 'touched')
end)

-- The diff wrapper gives the hunk shapes the mapping assumes
local function check_diff(label)
  assert.run_test('diff hunk shapes (' .. label .. ')', function()
    local function same(a, b, msg)
      assert.truthy(vim.deep_equal(a, b), msg .. ': got ' .. vim.inspect(a))
    end
    same(track.diff({ 'a', 'b', 'c' }, { 'a', 'x', 'b', 'c' }), { { 1, 0, 2, 1 } }, 'insert middle')
    same(track.diff({ 'a', 'b', 'c' }, { 'x', 'a', 'b', 'c' }), { { 0, 0, 1, 1 } }, 'insert at top')
    same(track.diff({ 'a', 'b', 'c' }, { 'a', 'c' }), { { 2, 1, 1, 0 } }, 'delete middle')
    same(track.diff({ 'a', 'b', 'c' }, { 'a', 'x', 'c' }), { { 2, 1, 2, 1 } }, 'change')
    same(track.diff({ 'a\r', 'b\r', 'c' }, { 'a', 'b', 'c' }), {}, 'CR line endings make no difference')
  end)
end

check_diff('vim.text.diff or vim.diff')
if vim.text and vim.text.diff then
  local text_diff = vim.text.diff
  vim.text.diff = nil
  local ok, err = pcall(check_diff, 'vim.diff fallback')
  vim.text.diff = text_diff
  if not ok then error(err, 0) end
end

test_helper.cleanup_test_environment()

return assert
