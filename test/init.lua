-- Test initialization for quickfix-review
-- This file sets up the testing environment

-- Add current directory to runtime path
vim.opt.runtimepath:prepend(vim.fn.getcwd())

-- Clear any cached modules
package.loaded['quickfix-review'] = nil
package.loaded['quickfix-review.config'] = nil
package.loaded['quickfix-review.utils'] = nil
package.loaded['quickfix-review.storage'] = nil
package.loaded['quickfix-review.store'] = nil
package.loaded['quickfix-review.log'] = nil
package.loaded['quickfix-review.reduce'] = nil
package.loaded['quickfix-review.export'] = nil
package.loaded['quickfix-review.snapshots'] = nil
package.loaded['quickfix-review.context'] = nil
package.loaded['quickfix-review.track'] = nil
package.loaded['quickfix-review.history'] = nil

-- Load the plugin
local quickfix_review = require('quickfix-review')

-- Mock input function for testing
local original_input = vim.fn.input
vim.fn.input = function(prompt)
  return 'Test comment'
end

-- Test helper functions
local M = {}

-- Never touch the real review in stdpath('data')
M.storage_file = vim.fn.tempname() .. '-quickfix-review.json'

-- The event log, cache and lock of a review kept in the explicit storage
-- file `file` (see store.lua)
function M.log_path(file) return (file or M.storage_file) .. '.log.jsonl' end
function M.state_path(file) return (file or M.storage_file) .. '.state.json' end
function M.lock_path(file) return (file or M.storage_file) .. '.lock' end

-- Every file a review in `file` (default: the test storage file) may leave:
-- comments.json and its backups, the log, the cache, the lock
function M.remove_storage(file)
  file = file or M.storage_file
  for _, suffix in ipairs({ '', '.pre-log.bak', '.pre-v2.bak', '.pre-repair.bak', '.log.jsonl', '.state.json' }) do
    os.remove(file .. suffix)
  end
  vim.fn.delete(M.lock_path(file), 'rf')
  vim.fn.delete(file .. '.snapshots', 'rf')
end

-- The records of the log at `log_path` (header first)
function M.log_records(log_path)
  local records = {}
  for _, line in ipairs(vim.fn.readfile(log_path)) do
    table.insert(records, vim.json.decode(line, { luanil = { object = true, array = true } }))
  end
  return records
end

-- The records of `log_path` whose op is `op`
function M.log_ops(log_path, op)
  local found = {}
  for _, r in ipairs(M.log_records(log_path)) do
    if r.op == op then table.insert(found, r) end
  end
  return found
end

-- The live comments on disk: the log at `log_path` (default: the test
-- storage file's) replayed, as logged records
function M.saved(log_path)
  local reduce = require('quickfix-review.reduce')
  local state = reduce.new()
  for _, r in ipairs(M.log_records(log_path or M.log_path())) do
    reduce.apply(state, r)
  end
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
