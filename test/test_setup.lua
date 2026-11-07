-- Tests that setup() can be called more than once without duplicating autocmds
local test_helper = dofile((vim.env.QFR_TEST_ROOT or '.') .. '/test/init.lua')
local assert = dofile(test_helper.root .. '/test/assertions.lua')

print('\nRunning setup tests...')

-- Plugin autocmds that are not in any group
local function ungrouped(event)
  local found = {}
  for _, au in ipairs(vim.api.nvim_get_autocmds({ event = event })) do
    if au.group == nil then table.insert(found, au) end
  end
  return found
end

local qf = test_helper.setup_test_environment()
test_helper.create_test_file('line 1\nline 2\nline 3\n')

assert.run_test('setup() twice keeps the same QuickfixReview autocmds', function()
  local once = #vim.api.nvim_get_autocmds({ group = 'QuickfixReview' })
  assert.truthy(once > 0, 'setup registers autocmds in QuickfixReview')

  test_helper.setup_test_environment()
  local twice = #vim.api.nvim_get_autocmds({ group = 'QuickfixReview' })
  assert.equals(twice, once, 'autocmd count after second setup')
end)

assert.run_test('setup() leaves no ungrouped plugin autocmds', function()
  for _, event in ipairs({ 'BufEnter', 'CursorMoved', 'FileChangedShellPost', 'FileType', 'DirChanged', 'BufWritePost', 'ShellFilterPost', 'BufWipeout', 'TextChanged' }) do
    assert.length(ungrouped(event), 0, 'ungrouped ' .. event .. ' handlers')
  end
end)

assert.run_test('DirChanged follows :cd and autochdir, not :lcd or :tcd', function()
  local patterns = {}
  for _, au in ipairs(vim.api.nvim_get_autocmds({ group = 'QuickfixReview', event = 'DirChanged' })) do
    patterns[au.pattern] = true
  end
  assert.truthy(patterns.global, 'global pattern')
  assert.truthy(patterns.auto, 'auto pattern')
  assert.falsy(patterns.window, 'no window pattern')
  assert.falsy(patterns.tabpage, 'no tabpage pattern')
end)

assert.run_test('view_comment float close autocmd is grouped and removed on close', function()
  qf.clear_review()
  vim.fn.cursor(2, 1)
  qf.add_comment('NOTE')
  qf.view_comment()

  local float = #vim.api.nvim_get_autocmds({ group = 'QuickfixReviewFloat' })
  assert.equals(float, 2, 'CursorMoved and BufLeave close handlers')
  assert.length(ungrouped('CursorMoved'), 0, 'ungrouped CursorMoved handlers')

  vim.api.nvim_exec_autocmds('CursorMoved', {})
  assert.equals(#vim.api.nvim_get_autocmds({ group = 'QuickfixReviewFloat' }), 0,
    'float handlers removed after close')
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    assert.equals(vim.api.nvim_win_get_config(win).relative, '', 'no floating window left open')
  end
  qf.clear_review()
end)

-- The floating windows currently open
local function floats()
  local found = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(win).relative ~= '' then table.insert(found, win) end
  end
  return found
end

-- The lines of the one float open now (fails if there is not exactly one)
local function only_float_lines()
  local open = floats()
  assert.length(open, 1, 'floating windows open')
  return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(open[1]), 0, -1, false)
end

assert.run_test('jump_comment leaves the float open', function()
  qf.clear_review()
  vim.fn.cursor(2, 1)
  qf.add_comment('NOTE')
  vim.fn.cursor(1, 1)
  qf.jump_comment(1)
  -- Stands in for the CursorMoved the main loop dispatches after the jump
  vim.api.nvim_exec_autocmds('CursorMoved', {})
  vim.wait(100, function() return #floats() > 0 end)
  assert.equals(vim.fn.line('.'), 2, 'jumped to the comment')
  local lines = only_float_lines()
  assert.equals(lines[1], '[NOTE] Test comment', 'float shows the comment')
  vim.api.nvim_exec_autocmds('CursorMoved', {})
  assert.length(floats(), 0, 'float closed by the next move')
  qf.clear_review()
end)

assert.run_test('three consecutive views leave no buffers, floats or handlers behind', function()
  qf.clear_review()
  vim.fn.cursor(2, 1)
  qf.add_comment('NOTE')
  local bufs = #vim.api.nvim_list_bufs()

  for _ = 1, 3 do qf.view_comment() end
  assert.length(floats(), 1, 'one float open after three views')
  assert.equals(#vim.api.nvim_get_autocmds({ group = 'QuickfixReviewFloat' }), 2,
    'one float close handler (two events)')

  vim.api.nvim_exec_autocmds('CursorMoved', {})
  assert.length(floats(), 0, 'no float left after closing')
  assert.equals(#vim.api.nvim_list_bufs(), bufs, 'buffer count back to baseline')
  assert.equals(#vim.api.nvim_get_autocmds({ group = 'QuickfixReviewFloat' }), 0,
    'float handlers removed after close')
  qf.clear_review()
end)

assert.run_test('view_comment on the middle line of a range comment opens its float', function()
  qf.clear_review()
  qf.add_comment('ISSUE', { 1, 3 })
  vim.fn.cursor(2, 1)
  qf.view_comment()
  local lines = only_float_lines()
  assert.equals(lines[1], '[ISSUE:L1-3] Test comment', 'float shows the range comment')
  vim.api.nvim_exec_autocmds('CursorMoved', {})
  qf.clear_review()
end)

assert.run_test('overlapping comments are shown together in one float, in line order', function()
  qf.clear_review()
  qf.add_comment('NOTE', { 2, 3 })
  qf.add_comment('ISSUE', { 1, 2 })
  vim.fn.cursor(2, 1)
  qf.view_comment()
  local lines = only_float_lines()
  assert.equals(table.concat(lines, '\n'),
    '[ISSUE:L1-2] Test comment\n\n[NOTE:L2-3] Test comment', 'both comments, lnum order')
  vim.api.nvim_exec_autocmds('CursorMoved', {})
  qf.clear_review()
end)

assert.run_test('view_comment wraps long bodies at the float width', function()
  local store = require('quickfix-review.store')
  local file = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ':p')
  local width = math.min(80, vim.o.columns - 4)
  local function view_lines(text)
    qf.clear_review()
    store.add({ filename = file, lnum = 2, text = text })
    vim.fn.cursor(2, 1)
    qf.view_comment()
    local lines = only_float_lines()
    local win = floats()[1]
    local height = vim.api.nvim_win_get_height(win)
    vim.api.nvim_exec_autocmds('CursorMoved', {})
    return lines, store.headline(store.all()[1]), height
  end

  local ok, err = pcall(function()
    -- Breaks at spaces: no line over width, nothing lost
    local words = {}
    for i = 1, 30 do words[i] = 'word' .. i end
    local lines, headline = view_lines('[NOTE] ' .. table.concat(words, ' '))
    assert.truthy(#lines > 1, 'long body wraps onto several lines')
    for i, l in ipairs(lines) do
      assert.truthy(#l <= width, 'line ' .. i .. ' fits width ' .. width .. ': ' .. #l)
    end
    local collapse = function(s) return (s:gsub('%s+', ' '):gsub('^ ', ''):gsub(' $', '')) end
    assert.equals(collapse(table.concat(lines, ' ')), collapse(headline), 'wrapped text is the headline')

    -- A token with no spaces is hard-cut at exactly width (after the label
    -- breaks off at its space)
    local token = string.rep('x', 2 * width + 5)
    lines = view_lines('[NOTE] ' .. token)
    assert.equals(table.concat(lines, '\n'),
      table.concat({ '[NOTE] ', token:sub(1, width), token:sub(width + 1, 2 * width), 'xxxxx' }, '\n'),
      'label, two width-long cuts, remainder')

    -- The float is at most 20 rows high
    local many = {}
    for i = 1, 400 do many[i] = 'w' .. i end
    local tall, _, height = view_lines('[NOTE] ' .. table.concat(many, ' '))
    assert.truthy(#tall > 20, 'body needs more than 20 lines')
    assert.equals(height, 20, 'float height capped at 20')
  end)
  vim.api.nvim_exec_autocmds('CursorMoved', {})
  qf.clear_review()
  if not ok then error(err, 0) end
end)

assert.run_test('view_comment shows a body and response containing newlines', function()
  local store = require('quickfix-review.store')
  local file = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ':p')
  local ok, err = pcall(function()
    qf.clear_review()
    store.add({ filename = file, lnum = 2, kind = 'note', body = 'first\nsecond', response = 'r1\nr2' })
    vim.fn.cursor(2, 1)
    local viewed, view_err = pcall(qf.view_comment)
    assert.truthy(viewed, 'view_comment does not throw: ' .. tostring(view_err))
    local lines = only_float_lines()
    assert.truthy(lines[1]:match('first$'), 'headline ends with the first body line: ' .. lines[1])
    local set = {}
    for _, l in ipairs(lines) do set[l] = true end
    assert.truthy(set['second'], 'second body line on its own line')
    assert.truthy(set['Response: r1'], 'first response line')
    assert.truthy(set['r2'], 'second response line on its own line')
    -- The quickfix row shows only the body's first line
    qf.show_list()
    local text = vim.fn.getqflist()[1].text
    assert.truthy(vim.startswith(text, '[NOTE] first | Response: '), 'qf text: ' .. text)
    assert.falsy(text:find('second', 1, true), 'second body line not in qf text: ' .. text)
    assert.falsy(text:find('\n', 1, true), 'no newline in qf text: ' .. text)
    assert.falsy(text:find('r2', 1, true), 'second response line not in qf text: ' .. text)
  end)
  vim.api.nvim_exec_autocmds('CursorMoved', {})
  qf.clear_review()
  if not ok then error(err, 0) end
end)

assert.run_test('view_comment wraps multibyte bodies by display width', function()
  local store = require('quickfix-review.store')
  local file = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ':p')
  local width = math.min(80, vim.o.columns - 4)
  local function view_lines(text)
    qf.clear_review()
    store.add({ filename = file, lnum = 2, text = text })
    vim.fn.cursor(2, 1)
    qf.view_comment()
    local lines = only_float_lines()
    vim.api.nvim_exec_autocmds('CursorMoved', {})
    return lines
  end
  -- token is `char` repeated: after the label, every line must be whole
  -- copies of char (no split bytes) and fit the float in display cells
  local function check(lines, char, token, label)
    assert.equals(lines[1], '[NOTE] ', label .. ' label breaks off at its space')
    assert.truthy(#lines > 2, label .. ' body wraps onto several lines')
    for i, l in ipairs(lines) do
      local cells = vim.fn.strdisplaywidth(l)
      assert.truthy(cells <= width, label .. ' line ' .. i .. ' fits ' .. width .. ' cells: ' .. cells)
      if i > 1 then
        assert.equals(l:gsub(char, ''), '', label .. ' line ' .. i .. ' holds only whole characters')
      end
    end
    assert.equals(table.concat(lines, ''), '[NOTE] ' .. token, label .. ' nothing lost')
  end

  local ok, err = pcall(function()
    -- 2-byte, 1-cell characters: pieces are width cells, not width bytes
    local accents = string.rep('é', 2 * width + 5)
    local lines = view_lines('[NOTE] ' .. accents)
    check(lines, 'é', accents, 'é')
    assert.equals(vim.fn.strchars(lines[2]), width, 'é piece fills the float width')

    -- 3-byte, 2-cell characters: pieces hold width/2 characters
    local cjk = string.rep('漢', width + 3)
    lines = view_lines('[NOTE] ' .. cjk)
    check(lines, '漢', cjk, 'CJK')
    assert.equals(vim.fn.strdisplaywidth(lines[2]), width - width % 2, 'CJK piece fills the float width')
  end)
  vim.api.nvim_exec_autocmds('CursorMoved', {})
  qf.clear_review()
  if not ok then error(err, 0) end
end)

assert.run_test('FileChangedShellPost relocates the changed buffer and never offers to clear', function()
  local changed_buf = vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(changed_buf)
  local other = vim.fn.tempname() .. '-other.txt'
  vim.fn.writefile({ 'other' }, other)
  local original_confirm = vim.fn.confirm
  local original_notify = vim.notify
  local ok, err = pcall(function()
    local notes = {}
    vim.notify = function(msg, level) table.insert(notes, { msg = msg, level = level }) end
    qf.setup({ storage_file = test_helper.storage_file, prompt_on_file_change = true })
    qf.setup({ storage_file = test_helper.storage_file, prompt_on_file_change = true })
    vim.notify = original_notify
    local deprecations = 0
    for _, n in ipairs(notes) do
      if n.msg:find('prompt_on_file_change is deprecated', 1, true) then deprecations = deprecations + 1 end
    end
    assert.equals(deprecations, 1, 'deprecation notice shown once across two setup() calls')

    qf.clear_review()
    vim.fn.cursor(2, 1)
    qf.add_comment('NOTE')
    assert.length(qf.comments(), 1, 'comment in the changed file')

    -- Two lines added above it on disk, reloaded
    vim.fn.writefile({ 'new a', 'new b', 'line 1', 'line 2', 'line 3' }, path)
    vim.api.nvim_buf_call(changed_buf, function() vim.cmd('silent edit!') end)

    vim.cmd('edit ' .. vim.fn.fnameescape(other))
    local asked = 0
    vim.fn.confirm = function() asked = asked + 1 return 1 end
    vim.api.nvim_exec_autocmds('FileChangedShellPost', { buffer = changed_buf })
    assert.equals(asked, 0, 'never asked to clear comments')
    local list = qf.comments()
    assert.length(list, 1, 'the comment is kept')
    local lnum = require('quickfix-review.store').range(list[1])
    assert.equals(lnum, 4, 'the comment followed its line')
  end)
  vim.notify = original_notify
  vim.fn.confirm = original_confirm
  vim.api.nvim_set_current_buf(changed_buf)
  pcall(vim.cmd, 'bwipeout! ' .. vim.fn.fnameescape(other))
  os.remove(other)
  vim.fn.writefile({ 'line 1', 'line 2', 'line 3' }, path)
  vim.cmd('silent edit!')
  test_helper.setup_test_environment()
  if not ok then error(err, 0) end
end)

assert.run_test('commands work before setup()', function()
  local saved_modules = {}
  for name, mod in pairs(package.loaded) do
    if name:match('^quickfix%-review') then
      saved_modules[name] = mod
      package.loaded[name] = nil
    end
  end
  local storage_file = vim.fn.tempname() .. '-before-setup.json'
  local original_setreg = vim.fn.setreg
  local clipboard
  local ok, err = pcall(function()
    -- Never touch the real review in stdpath('data')
    require('quickfix-review.config').options.storage_file = storage_file
    require('quickfix-review.store').add({
      filename = vim.fn.fnamemodify('test_file.txt', ':p'), lnum = 1, kind = 'question', body = 'before setup',
    })
    vim.fn.setreg = function(_, value) clipboard = value end
    vim.g.loaded_quickfix_review = nil
    vim.cmd('runtime plugin/quickfix-review.lua')

    local sok, serr = pcall(vim.cmd, 'ReviewSummary')
    assert.truthy(sok, ':ReviewSummary does not error: ' .. tostring(serr))
    local eok, eerr = pcall(vim.cmd, 'ReviewExport')
    assert.truthy(eok, ':ReviewExport does not error: ' .. tostring(eerr))
    assert.truthy(clipboard and clipboard:find('Comment types: ISSUE', 1, true), 'export has the default legend')
    assert.truthy(clipboard:find('**[QUESTION]**', 1, true), 'export has the comment')
    local original_input = vim.ui.input
    vim.ui.input = function(_, on_confirm) on_confirm(nil) end
    for _, cmd in ipairs({ 'ReviewTrash', 'ReviewHistory', 'ReviewReanchor', 'ReviewEdit',
      'ReviewAddIssue', 'ReviewAddSuggestion', 'ReviewAddNote', 'ReviewAddPraise',
      'ReviewAddQuestion', 'ReviewAddInsight', 'ReviewAdd note' }) do
      local cok, cerr = pcall(vim.cmd, cmd)
      -- :ReviewEdit may open its editor float, entered: close it, so the
      -- commands after it run in the file
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
        if name:match('^quickfix%-review://edit/') then pcall(vim.api.nvim_win_close, win, true) end
      end
      assert.truthy(cok, ':' .. cmd .. ' does not error: ' .. tostring(cerr))
    end
    vim.ui.input = original_input
    assert.equals(vim.fn.exists(':ReviewAdopt'), 2, ':ReviewAdopt exists before setup')
    local aok = pcall(vim.cmd, 'ReviewAdopt')
    assert.falsy(aok, ':ReviewAdopt needs a directory argument')
  end)
  vim.fn.setreg = original_setreg
  os.remove(storage_file)
  for name, _ in pairs(package.loaded) do
    if name:match('^quickfix%-review') then package.loaded[name] = nil end
  end
  for name, mod in pairs(saved_modules) do package.loaded[name] = mod end
  if not ok then error(err, 0) end
end)

-- The names of the :ReviewAdd<Type> commands, sorted
local function add_commands()
  local names = {}
  for name in pairs(vim.api.nvim_get_commands({})) do
    if name:match('^ReviewAdd%u') then table.insert(names, name) end
  end
  table.sort(names)
  return names
end

local nit = { sign = 'n', highlight = 'DiagnosticHint', description = 'Nitpicks' }

assert.run_test('setup() makes a ranged :ReviewAdd<Type> for a custom type', function()
  local ok, err = pcall(function()
    qf.setup({ storage_file = test_helper.storage_file,
      additional_comment_types = { nit = nit, needs_work = nit } })
    local cmds = vim.api.nvim_get_commands({})
    assert.truthy(cmds.ReviewAddNit, ':ReviewAddNit exists')
    assert.truthy(cmds.ReviewAddNit.range ~= '', ':ReviewAddNit takes a range')
    assert.truthy(cmds.ReviewAddNeedsWork, 'snake_case type is CamelCased')
    assert.truthy(cmds.ReviewAddIssue and cmds.ReviewAddIssue.range ~= '', 'defaults kept, with a range')
    assert.truthy(cmds.ReviewAdd and cmds.ReviewAdd.range ~= '', ':ReviewAdd takes a range')
    assert.truthy(cmds.ReviewDelete.range ~= '', ':ReviewDelete takes a range')
  end)
  test_helper.setup_test_environment()
  if not ok then error(err, 0) end
end)

assert.run_test('setup() twice keeps the same :ReviewAdd commands', function()
  local ok, err = pcall(function()
    local opts = { storage_file = test_helper.storage_file, additional_comment_types = { nit = nit } }
    qf.setup(opts)
    local once = add_commands()
    qf.setup(opts)
    assert.truthy(vim.deep_equal(add_commands(), once), 'same commands: ' .. vim.inspect(add_commands()))
  end)
  test_helper.setup_test_environment()
  if not ok then error(err, 0) end
end)

assert.run_test('setup() without a type deletes its :ReviewAdd command', function()
  local ok, err = pcall(function()
    qf.setup({ storage_file = test_helper.storage_file, additional_comment_types = { nit = nit } })
    assert.truthy(vim.api.nvim_get_commands({}).ReviewAddNit, 'made')
    qf.setup({ storage_file = test_helper.storage_file })
    local cmds = vim.api.nvim_get_commands({})
    assert.falsy(cmds.ReviewAddNit, 'gone after the type is dropped')
    assert.truthy(cmds.ReviewAddIssue, 'default kept')
  end)
  test_helper.setup_test_environment()
  if not ok then error(err, 0) end
end)

assert.run_test('setup() leaves a user\'s own :ReviewAdd<X> command alone', function()
  local ok, err = pcall(function()
    vim.api.nvim_create_user_command('ReviewAddMine', function() end, { desc = 'mine' })
    qf.setup({ storage_file = test_helper.storage_file })
    assert.truthy(vim.api.nvim_get_commands({}).ReviewAddMine, 'still there')
  end)
  pcall(vim.api.nvim_del_user_command, 'ReviewAddMine')
  test_helper.setup_test_environment()
  if not ok then error(err, 0) end
end)

assert.run_test('a type that cannot name a command warns and gets none', function()
  local calls = {}
  local original_notify = vim.notify
  vim.notify = function(msg, level) table.insert(calls, { msg = msg, level = level }) end
  local ok, err = pcall(function()
    qf.setup({ storage_file = test_helper.storage_file, additional_comment_types = { ['needs-work'] = nit } })
  end)
  vim.notify = original_notify
  local ok2, err2 = pcall(function()
    assert.truthy(ok, 'setup does not throw: ' .. tostring(err))
    local warned = false
    for _, c in ipairs(calls) do
      if c.level == vim.log.levels.WARN and c.msg:find('needs-work', 1, true) then warned = true end
    end
    assert.truthy(warned, 'warned about needs-work')
    for _, name in ipairs(add_commands()) do
      assert.falsy(name:match('^ReviewAddNeeds'), 'no command for needs-work: ' .. name)
    end
    assert.truthy(vim.tbl_contains(vim.fn.getcompletion('ReviewAdd ', 'cmdline'), 'needs-work'),
      ':ReviewAdd still completes it')
  end)
  test_helper.setup_test_environment()
  if not ok2 then error(err2, 0) end
end)

-- Global maps (in mode) that setup() made: their desc ends in the marker
local function plugin_maps(mode)
  local marker = require('quickfix-review.commands').MARKER
  local found = {}
  for _, map in ipairs(vim.api.nvim_get_keymap(mode)) do
    if type(map.desc) == 'string' and vim.endswith(map.desc, marker) then table.insert(found, map.lhs) end
  end
  return found
end

-- Run fn with vim.notify recorded; returns the WARN messages and fn's result
local function capture_warnings(fn)
  local warns = {}
  local original = vim.notify
  vim.notify = function(msg, level)
    if level == vim.log.levels.WARN then table.insert(warns, msg) end
  end
  local ok, err = pcall(fn)
  vim.notify = original
  return ok, err, warns
end

assert.run_test('setup() twice with a map disabled the second time removes it', function()
  local ok, err = pcall(function()
    qf.setup({ storage_file = test_helper.storage_file, keymaps = { export = '<leader>ce' } })
    assert.truthy(vim.fn.maparg('<leader>ce', 'n') ~= '', 'export map made')
    qf.setup({ storage_file = test_helper.storage_file, keymaps = { export = false } })
    assert.equals(vim.fn.maparg('<leader>ce', 'n'), '', 'export map gone after it is disabled')
  end)
  test_helper.setup_test_environment()
  if not ok then error(err, 0) end
end)

assert.run_test('setup() without a type removes its add map', function()
  local ok, err = pcall(function()
    qf.setup({ storage_file = test_helper.storage_file, additional_comment_types = { nit = nit },
      keymaps = { add_nit = '<leader>cN' } })
    assert.truthy(vim.fn.maparg('<leader>cN', 'n') ~= '', 'normal map made')
    assert.truthy(vim.fn.maparg('<leader>cN', 'v') ~= '', 'visual map made')
    qf.setup({ storage_file = test_helper.storage_file })
    assert.equals(vim.fn.maparg('<leader>cN', 'n'), '', 'normal map gone')
    assert.equals(vim.fn.maparg('<leader>cN', 'v'), '', 'visual map gone')
  end)
  test_helper.setup_test_environment()
  if not ok then error(err, 0) end
end)

assert.run_test("setup() leaves a user's own map on a disabled key alone", function()
  local ok, err = pcall(function()
    qf.setup({ storage_file = test_helper.storage_file, keymaps = { export = false } })
    vim.keymap.set('n', '<leader>ce', function() end, { desc = 'mine' })
    qf.setup({ storage_file = test_helper.storage_file, keymaps = { export = false } })
    assert.equals(vim.fn.maparg('<leader>ce', 'n', false, true).desc, 'mine', 'user map kept')
  end)
  pcall(vim.keymap.del, 'n', '<leader>ce')
  test_helper.setup_test_environment()
  if not ok then error(err, 0) end
end)

assert.run_test('keymaps = false: setup completes with no plugin maps', function()
  local ok, err = pcall(function()
    local done, setup_err = pcall(qf.setup, { storage_file = test_helper.storage_file,
      additional_comment_types = { nit = nit }, keymaps = false })
    assert.truthy(done, 'setup does not throw: ' .. tostring(setup_err))
    assert.truthy(vim.api.nvim_get_commands({}).ReviewAddIssue, 'commands made')
    assert.truthy(#vim.api.nvim_get_autocmds({ group = 'QuickfixReview' }) > 0, 'autocmds made')
    assert.length(plugin_maps('n'), 0, 'no normal plugin maps')
    assert.length(plugin_maps('v'), 0, 'no visual plugin maps')
  end)
  test_helper.setup_test_environment()
  if not ok then error(err, 0) end
end)

assert.run_test('export = false warns and keeps the default export format', function()
  local config = require('quickfix-review.config')
  local ok, err, warns = capture_warnings(function()
    qf.setup({ storage_file = test_helper.storage_file, export = false })
  end)
  local ok2, err2 = pcall(function()
    assert.truthy(ok, 'setup does not throw: ' .. tostring(err))
    assert.truthy(#warns > 0, 'warned')
    assert.equals(config.options.export.item_format, config.defaults.export.item_format, 'default item_format')
    assert.truthy(config.options.export.type_legend:find('ISSUE', 1, true), 'legend generated')
  end)
  test_helper.setup_test_environment()
  if not ok2 then error(err2, 0) end
end)

assert.run_test('an uppercase type key is stored lowercase and usable', function()
  local config = require('quickfix-review.config')
  local ok, err, warns = capture_warnings(function()
    qf.setup({ storage_file = test_helper.storage_file, additional_comment_types = { Bug = nit } })
  end)
  local ok2, err2 = pcall(function()
    assert.truthy(ok, 'setup does not throw: ' .. tostring(err))
    assert.truthy(config.options.comment_types.bug, 'stored as bug')
    assert.falsy(config.options.comment_types.Bug, 'no Bug key')
    local warned = false
    for _, msg in ipairs(warns) do
      if msg:find("'Bug'", 1, true) then warned = true end
    end
    assert.truthy(warned, 'warned about Bug')
    assert.truthy(vim.api.nvim_get_commands({}).ReviewAddBug, ':ReviewAddBug made')
    qf.clear_review()
    vim.fn.cursor(1, 1)
    qf.add_comment('BUG')
    assert.length(qf.comments(), 1, 'BUG comment added')
    qf.clear_review()
  end)
  test_helper.setup_test_environment()
  if not ok2 then error(err2, 0) end
end)

assert.run_test('an uppercase type key colliding with a lowercase one warns', function()
  local config = require('quickfix-review.config')
  local other = { sign = 'b', highlight = 'DiagnosticHint', description = 'Other' }
  local ok, err, warns = capture_warnings(function()
    qf.setup({ storage_file = test_helper.storage_file, additional_comment_types = { Bug = other, bug = nit } })
  end)
  local ok2, err2 = pcall(function()
    assert.truthy(ok, 'setup does not throw: ' .. tostring(err))
    assert.equals(config.options.comment_types.bug.description, 'Nitpicks', 'lowercase key wins')
    assert.falsy(config.options.comment_types.Bug, 'no Bug key')
    assert.truthy(#warns > 0, 'warned')
  end)
  test_helper.setup_test_environment()
  if not ok2 then error(err2, 0) end
end)

assert.run_test('setup() with defaults does not warn', function()
  local ok, err, warns = capture_warnings(function()
    qf.setup({ storage_file = test_helper.storage_file })
  end)
  test_helper.setup_test_environment()
  assert.truthy(ok, 'setup does not throw: ' .. tostring(err))
  assert.length(warns, 0, 'no warnings: ' .. vim.inspect(warns))
end)

assert.run_test('the cycle add map desc does not mention Tab', function()
  local ok, err = pcall(function()
    qf.setup({ storage_file = test_helper.storage_file })
    local desc = vim.fn.maparg('<leader>ca', 'n', false, true).desc
    assert.truthy(desc and not desc:find('Tab', 1, true), 'desc: ' .. tostring(desc))
  end)
  test_helper.setup_test_environment()
  if not ok then error(err, 0) end
end)

assert.run_test('bad keymap values warn, are skipped, and leave the plugin working', function()
  local ok, err, warns = capture_warnings(function()
    qf.setup({ storage_file = test_helper.storage_file,
      keymaps = { reanchor = true, view = '', delete_comment = true, export = 42 } })
  end)
  local ok2, err2 = pcall(function()
    assert.truthy(ok, 'setup does not throw: ' .. tostring(err))
    assert.length(warns, 4, 'one warning per bad keymap: ' .. vim.inspect(warns))
    for _, key in ipairs({ 'reanchor', 'view', 'delete_comment', 'export' }) do
      local named = false
      for _, w in ipairs(warns) do named = named or w:find('keymaps.' .. key, 1, true) ~= nil end
      assert.truthy(named, 'warning names keymaps.' .. key)
    end
    assert.truthy(#vim.api.nvim_get_autocmds({ group = 'QuickfixReview' }) > 0, 'autocmds made')
    assert.truthy(vim.api.nvim_get_commands({}).ReviewAddIssue, 'commands made')
    assert.truthy(vim.fn.maparg('<leader>ci', 'n') ~= '', 'good keymaps still mapped')
    assert.equals(vim.fn.maparg('<leader>cd', 'n'), '', 'bad delete_comment left unmapped')
  end)
  test_helper.setup_test_environment()
  if not ok2 then error(err2, 0) end
end)

assert.run_test('a bad keymap on re-run does not tear down the earlier setup', function()
  local ok, err = pcall(function()
    local before = #vim.api.nvim_get_autocmds({ group = 'QuickfixReview' })
    capture_warnings(function()
      qf.setup({ storage_file = test_helper.storage_file, keymaps = { reanchor = true } })
    end)
    assert.equals(#vim.api.nvim_get_autocmds({ group = 'QuickfixReview' }), before, 'autocmds kept')
  end)
  test_helper.setup_test_environment()
  if not ok then error(err, 0) end
end)

assert.run_test('list-form comment_types makes working types', function()
  local config = require('quickfix-review.config')
  local ok, err, warns = capture_warnings(function()
    qf.setup({ storage_file = test_helper.storage_file, comment_types = { 'bug', 'issue' } })
  end)
  local ok2, err2 = pcall(function()
    assert.truthy(ok, 'setup does not throw: ' .. tostring(err))
    assert.length(warns, 0, 'no warnings: ' .. vim.inspect(warns))
    assert.equals(vim.tbl_count(config.options.comment_types), 2, 'two types')
    assert.equals(config.options.comment_types.issue.sign, config.default_comment_types.issue.sign,
      'a default name keeps its default config')
    assert.truthy(type(config.options.comment_types.bug.sign) == 'string', 'custom name gets a sign')
    assert.truthy(vim.api.nvim_get_commands({}).ReviewAddBug, ':ReviewAddBug made')
    local seen = {}
    for _ = 1, 2 do seen[qf.cycle_next_comment_type()] = true end
    assert.truthy(seen.bug and seen.issue, 'cycling reaches both types')
  end)
  test_helper.setup_test_environment()
  if not ok2 then error(err2, 0) end
end)

assert.run_test('additional_comment_types entry = false removes the type without throwing', function()
  local config = require('quickfix-review.config')
  local ok, err, warns = capture_warnings(function()
    qf.setup({ storage_file = test_helper.storage_file,
      additional_comment_types = { praise = false, Insight = false, nit = nit } })
  end)
  local ok2, err2 = pcall(function()
    assert.truthy(ok, 'setup does not throw: ' .. tostring(err))
    assert.length(warns, 0, 'no warnings: ' .. vim.inspect(warns))
    assert.equals(config.options.comment_types.praise, nil, 'praise removed')
    assert.equals(config.options.comment_types.insight, nil, 'insight removed')
    assert.truthy(config.options.comment_types.nit, 'nit added')
    assert.truthy(config.options.comment_types.issue, 'other defaults kept')
    assert.equals(vim.api.nvim_get_commands({}).ReviewAddPraise, nil, 'no :ReviewAddPraise')
    assert.equals(vim.fn.maparg('<leader>cp', 'n'), '', 'no praise keymap')
  end)
  test_helper.setup_test_environment()
  if not ok2 then error(err2, 0) end
end)

assert.run_test('a non-table comment type entry warns and is skipped', function()
  local config = require('quickfix-review.config')
  local ok, err, warns = capture_warnings(function()
    qf.setup({ storage_file = test_helper.storage_file, additional_comment_types = { nit = 'x' } })
  end)
  local ok2, err2 = pcall(function()
    assert.truthy(ok, 'setup does not throw: ' .. tostring(err))
    assert.length(warns, 1, 'one warning: ' .. vim.inspect(warns))
    assert.equals(config.options.comment_types.nit, nil, 'nit skipped')
  end)
  test_helper.setup_test_environment()
  if not ok2 then error(err2, 0) end
end)

-- test/init.lua refuses a non-hermetic run before loading the plugin. The
-- child gets a fake HOME and data home, so a broken guard still can't reach
-- real data.
local function guarded_run(env)
  local home = vim.fn.tempname()
  vim.fn.mkdir(home, 'p')
  local full_env = { HOME = home, PATH = vim.env.PATH, XDG_DATA_HOME = home .. '/data' }
  for k, v in pairs(env(home)) do full_env[k] = v end
  local result = vim.system({
    vim.v.progpath, '--headless', '--clean',
    '-c', string.format('lua dofile(%q)', test_helper.root .. '/test/init.lua'),
    '-c', 'qall!',
  }, { env = full_env, clear_env = true, cwd = test_helper.root }):wait(30000)
  -- The plugin checkout is a git repo: its review would be in it
  local created = vim.fn.isdirectory(full_env.XDG_DATA_HOME .. '/nvim/quickfix-review') == 1
    or vim.uv.fs_stat(test_helper.root .. '/.quickfix-review') ~= nil
  vim.fn.delete(home, 'rf')
  return result, created
end

assert.run_test('test/init.lua refuses to run without QFR_TEST_HERMETIC', function()
  local result, created = guarded_run(function(home)
    return { QFR_TEST_ROOT = test_helper.root, QFR_TEST_WORKDIR = home }
  end)
  assert.matches(result.stderr, 'scripts/test%.sh', 'error points at scripts/test.sh: ' .. result.stderr)
  assert.falsy(created, 'no review created in the data home')
end)

assert.run_test('test/init.lua refuses the real data home even with the marker', function()
  local result, created = guarded_run(function(home)
    return {
      QFR_TEST_HERMETIC = '1', QFR_TEST_ROOT = test_helper.root, QFR_TEST_WORKDIR = home,
      XDG_DATA_HOME = home .. '/.local/share',
    }
  end)
  assert.matches(result.stderr, 'real data home', 'refused: ' .. result.stderr)
  assert.falsy(created, 'no review created in the data home')
end)

test_helper.cleanup_test_environment()

return assert
