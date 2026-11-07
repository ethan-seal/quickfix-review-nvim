-- Test initialization for quickfix-review
-- This file sets up the testing environment

-- Refuse non-hermetic runs: scripts/test.sh redirects XDG_DATA_HOME and the
-- working directory to throwaway dirs, so tests never touch real user data or
-- leave files in the repo. A test file run directly with nvim would not.
local function refuse(why)
  error('quickfix-review tests must run hermetically (' .. why
    .. '): use scripts/test.sh [test/test_x.lua ...]', 0)
end
if vim.env.QFR_TEST_HERMETIC ~= '1' then refuse('QFR_TEST_HERMETIC is not set') end
for _, var in ipairs({ 'QFR_TEST_ROOT', 'QFR_TEST_WORKDIR', 'XDG_DATA_HOME' }) do
  if (vim.env[var] or '') == '' then refuse(var .. ' is not set') end
end
if vim.env.HOME and vim.fs.normalize(vim.env.XDG_DATA_HOME)
    == vim.fs.normalize(vim.env.HOME .. '/.local/share') then
  refuse('XDG_DATA_HOME is the real data home')
end

-- Load this checkout, then work in the throwaway dir so relative writes
-- (test_file.txt) land there. The dir is fixed, so re-running this is harmless.
vim.opt.runtimepath:prepend(vim.env.QFR_TEST_ROOT)
vim.cmd.cd(vim.env.QFR_TEST_WORKDIR)

-- Clear every cached module of the plugin (store/* included), so each test
-- file starts from fresh module state
for name in pairs(package.loaded) do
  if name:match('^quickfix%-review') then package.loaded[name] = nil end
end

-- The 5s startup snapshot GC must never fire mid-suite (tests backdate
-- snapshots); store.gc_snapshots is called directly instead
vim.g._quickfix_review_no_startup_gc = true

-- Source plugin/ as Neovim's startup would have, had this checkout been on
-- the runtimepath then (--clean, and the rtp is only prepended above), so the
-- user commands (:ReviewReanchor, :ReviewHistory...) exist in every test file
-- run alone. The plugin's own guard makes it a no-op once sourced.
vim.cmd.runtime('plugin/quickfix-review.lua')

-- Load the plugin
local quickfix_review = require('quickfix-review')

-- Mock input function for testing
local original_input = vim.fn.input
vim.fn.input = function(prompt)
  return 'Test comment'
end

-- Test helper functions
local M = {}

-- The real vim.fn.input, for a test that drives the prompt with feedkeys
M.real_input = original_input

-- The repo root (cwd is the throwaway work dir)
M.root = vim.env.QFR_TEST_ROOT

-- Never touch the real review in stdpath('data')
M.storage_file = vim.fn.tempname() .. '-quickfix-review.json'

-- The journal (events), its checkpoints and the lock of a review kept in
-- the explicit storage file `file` (see store/location.lua)
function M.events_path(file) return (file or M.storage_file) .. '.events' end
function M.checkpoints_path(file) return (file or M.storage_file) .. '.checkpoints' end
-- Segment `n` (default 1) of the journal of `file`
function M.segment_path(n, file) return string.format('%s/%06d.jsonl', M.events_path(file), n or 1) end
-- The checkpoint files of the journal of `file`, newest first
function M.checkpoint_files(file)
  local out = vim.fn.glob(M.checkpoints_path(file) .. '/*.json', true, true)
  table.sort(out, function(a, b) return a > b end)
  return out
end
-- The newest checkpoint file of the journal of `file`, or nil
function M.checkpoint_path(file) return M.checkpoint_files(file)[1] end
function M.lock_path(file) return (file or M.storage_file) .. '.lock' end
-- The flock'ed lock file (the lock path above is the mkdir fallback's)
function M.flock_path(file) return (file or M.storage_file) .. '.journal.lock' end

-- Every file a review in `file` (default: the test storage file) may leave:
-- comments.json and its backup, the journal, the lock
function M.remove_storage(file)
  file = file or M.storage_file
  for _, suffix in ipairs({ '', '.pre-log.bak' }) do
    os.remove(file .. suffix)
  end
  -- Stale locks broken by renaming them aside
  for _, p in ipairs(vim.fn.glob(M.lock_path(file) .. '.stale-*', true, true)) do vim.fn.delete(p, 'rf') end
  vim.fn.delete(M.lock_path(file), 'rf')
  os.remove(M.flock_path(file))
  vim.fn.delete(file .. '.snapshots', 'rf')
  vim.fn.delete(M.events_path(file), 'rf')
  vim.fn.delete(M.checkpoints_path(file), 'rf')
  for _, p in ipairs(vim.fn.glob(M.events_path(file) .. '.tmp.*', true, true)) do os.remove(p) end
end

-- The segment paths of the journal `events` (an events dir), in order, as
-- { n, path }...; empty when there is none
function M.segments_of(events)
  local out = {}
  if vim.fn.isdirectory(events) == 0 then return out end
  for _, name in ipairs(vim.fn.readdir(events) or {}) do
    local n = name:match('^(%d+)%.jsonl$')
    if n then table.insert(out, { n = tonumber(n), path = events .. '/' .. name }) end
  end
  table.sort(out, function(a, b) return a.n < b.n end)
  return out
end

local function decode_lines(path, seg, out)
  for _, line in ipairs(vim.fn.readfile(path)) do
    local r = vim.json.decode(line, { luanil = { object = true, array = true } })
    table.insert(out, seg and { seg = seg, record = r } or r)
  end
end

-- The records of the journal `events` (an events dir, or one segment
-- file), in order, each segment's header included
function M.log_records(events)
  local records = {}
  local segs = M.segments_of(events)
  if #segs == 0 then segs = { { path = events } } end
  for _, s in ipairs(segs) do decode_lines(s.path, nil, records) end
  return records
end

-- The records of the journal `events` whose op is `op`
function M.log_ops(events, op)
  local found = {}
  for _, r in ipairs(M.log_records(events)) do
    if r.op == op then table.insert(found, r) end
  end
  return found
end

-- The live comments on disk: the journal `events` (default: the test
-- storage file's) replayed, as logged records
function M.saved(events)
  local reduce = require('quickfix-review.reduce')
  local state = reduce.new()
  for _, r in ipairs(M.log_records(events or M.events_path())) do reduce.apply(state, r) end
  return state.comments
end

function M.setup_test_environment()
  -- Clear any existing quickfix list
  vim.fn.setqflist({})

  -- Setup the plugin with test configuration
  quickfix_review.setup({
    storage_file = M.storage_file,
    comment_types = {
      issue = { sign = '!', highlight = 'DiagnosticError', description = 'Problems' },
      suggestion = { sign = 'S', highlight = 'DiagnosticWarn', description = 'Improvements' },
      note = { sign = 'N', highlight = 'DiagnosticInfo', description = 'Observations' },
      praise = { sign = '+', highlight = 'DiagnosticHint', description = 'Positive' },
      question = { sign = 'Q', highlight = 'DiagnosticInfo', description = 'Questions' },
      insight = { sign = 'I', highlight = 'DiagnosticHint', description = 'Insights' }
    },
    keymaps = {
      add_issue = false,
      add_suggestion = false,
      add_note = false,
      add_praise = false,
      delete_comment = false,
      export = false,
      clear = false,
      summary = false,
      save = false,
      load = false,
      open_list = false,
      next_comment = false,
      prev_comment = false,
      goto_real_file = false,
      view = false,
      edit = false,
    }
  })

  return quickfix_review
end

function M.cleanup_test_environment()
  -- Restore original input function
  vim.fn.input = original_input

  -- Clear quickfix list and the review
  vim.fn.setqflist({})
  quickfix_review.clear_review()
  M.remove_storage()

  -- Remove extmarks (signs and tracking marks) from all buffers
  local utils = require('quickfix-review.utils')
  local track = require('quickfix-review.track')
  track._reset()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_clear_namespace(bufnr, utils.get_ns_id(), 0, -1)
      vim.api.nvim_buf_clear_namespace(bufnr, track.ns(), 0, -1)
    end
  end

  -- Clean up test files
  os.remove('test_file.txt')
end

function M.create_test_file(content)
  local test_file = 'test_file.txt'
  local file = io.open(test_file, 'w')
  if file then
    file:write(content)
    file:close()
    vim.cmd('edit ' .. test_file)
    return test_file
  end
  return nil
end

function M.print_comments()
  local list = quickfix_review.comments()
  print('Review (' .. #list .. ' comments):')
  for i, item in ipairs(list) do
    print(string.format('  %d. %s:%d-%d - %s',
      i, vim.fn.fnamemodify(item.filename, ':.'), item.lnum, item.end_lnum or item.lnum, require('quickfix-review.store').headline(item)))
  end
end

return M
