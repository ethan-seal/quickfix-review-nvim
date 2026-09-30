-- Tests for track.lua's pure core: mapping a comment's range through a diff
local test_helper = dofile((vim.env.QFR_TEST_ROOT or '.') .. '/test/init.lua')
local assert = dofile(test_helper.root .. '/test/assertions.lua')

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

-- search: finding an anchor's lines when its snapshot is missing
local function check_search(name, lines, anchor, lnum, end_lnum, state)
  assert.run_test('search: ' .. name, function()
    local l, e, s = track.search(lines, anchor)
    assert.equals(l, lnum, 'lnum')
    assert.equals(e, end_lnum, 'end_lnum')
    assert.equals(s, state, 'state')
  end)
end

local function numbered(n, prefix)
  local out = {}
  for i = 1, n do out[i] = (prefix or 'line ') .. i end
  return out
end

-- A comment on lines 4-5 of numbered(10)
local A45 = {
  lnum = 4, end_lnum = 5, lines = { 'line 4', 'line 5' },
  before = { 'line 2', 'line 3' }, after = { 'line 6', 'line 7' },
}

check_search('unchanged: current', numbered(10), A45, 4, 5, 'current')
do
  local moved = numbered(10)
  for _ = 1, 3 do table.insert(moved, 1, 'new') end
  check_search('moved by +3: shifted', moved, A45, 7, 8, 'shifted')
end
do
  local up = numbered(10)
  table.remove(up, 1)
  check_search('moved by -1: shifted', up, A45, 3, 4, 'shifted')
end
do
  local removed = numbered(10)
  table.remove(removed, 5)
  check_search('a commented line removed: outdated at the old lines', removed, A45, 4, 5, 'outdated')
end
do
  local changed = numbered(10)
  changed[4] = 'line four'
  check_search('a commented line changed: outdated', changed, A45, 4, 5, 'outdated')
end
do
  local inside = numbered(10)
  table.insert(inside, 5, 'inserted')
  check_search('a line inserted inside: outdated', inside, A45, 4, 5, 'outdated')
end
check_search('file shorter than the anchor: outdated, clamped', { 'a', 'b', 'c' }, A45, 3, 3, 'outdated')
check_search('empty file: outdated at line 1', {}, A45, 1, 1, 'outdated')
check_search('no lines in the anchor: outdated', numbered(10),
  { lnum = 4, end_lnum = 5 }, 4, 5, 'outdated')
do
  local far = numbered(300, 'x ')
  far[250], far[251] = 'line 4', 'line 5'
  check_search('beyond 200 lines away: not found', far, A45, 4, 5, 'outdated')
end
do
  local crlf = { 'new', 'line 1\r', 'line 2\r', 'line 3\r', 'line 4\r', 'line 5\r', 'line 6\r' }
  check_search('CR line endings match', crlf, A45, 5, 6, 'shifted')
end
do
  -- As read from a file with CR CR line endings (snapshots.canonical strips
  -- every trailing CR)
  local crcr = { 'new', 'line 1\r\r', 'line 2\r\r', 'line 3\r\r', 'line 4\r\r', 'line 5\r\r', 'line 6\r\r' }
  check_search('CR CR line endings match', crcr, A45, 5, 6, 'shifted')
  local anchor = { lnum = 4, end_lnum = 5, lines = { 'line 4\r\r', 'line 5\r\r' },
    before = { 'line 2\r\r', 'line 3\r\r' }, after = { 'line 6\r\r', 'line 7\r\r' } }
  check_search('an anchor with CR CR lines matches plain lines', numbered(10), anchor, 4, 5, 'current')
end
do
  -- NVIM 0.12 gives a NUL in a buffer line as "\0", readfile() as "\n"
  local anchor = { lnum = 2, end_lnum = 2, lines = { 'x\0y' }, before = { 'a' }, after = { 'c' } }
  check_search('an anchor NUL as "\\0" matches a file line with "\\n"', { 'a', 'x\ny', 'c' }, anchor, 2, 2, 'current')
  local anchor_nl = { lnum = 2, end_lnum = 2, lines = { 'x\ny' }, before = { 'a' }, after = { 'c' } }
  check_search('an anchor NUL as "\\n" matches a buffer line with "\\0"', { 'a', 'x\0y', 'c' }, anchor_nl, 2, 2, 'current')
end

-- Blocks of `end`: which one is meant comes from the context
local ENDS = {
  'function a()', '  if x then', '    one()', '  end', 'end',
  '', 'function b()', '  if y then', '    two()', '  end', 'end',
}
local B_END = {
  lnum = 10, end_lnum = 11, lines = { '  end', 'end' },
  before = { '  if y then', '    two()' }, after = { '' },
}
do
  local shifted = vim.deepcopy(ENDS)
  table.insert(shifted, 1, '-- header')
  table.insert(shifted, 1, '-- header')
  check_search('block of end lines with distinct context: the right one', shifted, B_END, 12, 13, 'shifted')
end
do
  -- b() moved above a(): the nearest `end end` is a()'s, but b()'s context wins
  local swapped = {
    'function b()', '  if y then', '    two()', '  end', 'end',
    '', 'function a()', '  if x then', '    one()', '  end', 'end',
  }
  check_search('context beats nearness', swapped, B_END, 4, 5, 'shifted')
end
do
  -- Both bodies changed: no context tells the `end end` blocks apart
  local changed = vim.deepcopy(ENDS)
  changed[1], changed[2], changed[3] = 'p', 'q', 'r'
  changed[7], changed[8], changed[9] = 's', 't', 'u'
  table.insert(changed, 1, 'new')
  check_search('trivial lines with no context: ambiguous, outdated', changed,
    { lnum = 10, end_lnum = 11, lines = { '  end', 'end' }, before = { 'zz', 'yy' }, after = {} },
    10, 11, 'outdated')
end
do
  -- A distinctive line repeated with equal context: the nearest one
  local rep = { 'call(x)', 'a', 'call(x)', 'b', 'c', 'call(x)' }
  check_search('non-trivial repeated line: nearest wins', rep,
    { lnum = 5, end_lnum = 5, lines = { 'call(x)' }, before = {}, after = {} }, 6, 6, 'shifted')
  check_search('non-trivial repeated line equidistant: outdated', rep,
    { lnum = 2, end_lnum = 2, lines = { 'call(x)' }, before = {}, after = {} }, 2, 2, 'outdated')
end

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
    local snapshots = require('quickfix-review.snapshots')
    same(track.diff(snapshots.get(snapshots.put({ 'x\r\r' })), { 'x\r\r' }), {}, 'a stored CR CR line diffs clean')
    assert.equals(#track.diff({ 'a\r\r' }, { 'a\r1' }), 1, 'CR CR vs "\\r1" differ')
    assert.equals(#track.diff({ 'a\0' }, { 'a\r1' }), 1, 'an escaped line vs a plain one differ')
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
