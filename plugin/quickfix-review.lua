-- Auto-load file for quickfix-review.nvim
-- Defines user commands

if vim.g.loaded_quickfix_review then
  return
end
vim.g.loaded_quickfix_review = 1

-- Create user commands
vim.api.nvim_create_user_command('ReviewAddIssue', function()
  require('quickfix-review').add_comment('ISSUE')
end, { desc = 'Add an ISSUE comment at current line' })

vim.api.nvim_create_user_command('ReviewAddSuggestion', function()
  require('quickfix-review').add_comment('SUGGESTION')
end, { desc = 'Add a SUGGESTION comment at current line' })

vim.api.nvim_create_user_command('ReviewAddNote', function()
  require('quickfix-review').add_comment('NOTE')
end, { desc = 'Add a NOTE comment at current line' })

vim.api.nvim_create_user_command('ReviewAddPraise', function()
  require('quickfix-review').add_comment('PRAISE')
end, { desc = 'Add a PRAISE comment at current line' })

vim.api.nvim_create_user_command('ReviewExport', function()
  require('quickfix-review').export_review()
end, { desc = 'Export review to markdown and clipboard' })

vim.api.nvim_create_user_command('ReviewClear', function(o)
  require('quickfix-review').clear_review({ confirm = not o.bang })
end, { bang = true, desc = 'Clear all review comments (asks first; ! skips the question)' })

vim.api.nvim_create_user_command('ReviewTrash', function()
  require('quickfix-review').show_trash()
end, { desc = 'List deleted review comments (newest first) in a quickfix list' })

vim.api.nvim_create_user_command('ReviewRestore', function(o)
  require('quickfix-review').restore_comment(o.args)
end, {
  nargs = '?',
  complete = function(lead) return require('quickfix-review').complete_trash_ids(lead) end,
  desc = 'Restore a deleted comment (default: the last deletion or clear)',
})

vim.api.nvim_create_user_command('ReviewHistory', function(o)
  require('quickfix-review').history(o.args)
end, {
  nargs = '?',
  complete = function(lead) return require('quickfix-review').complete_ids(lead) end,
  desc = 'Show the event history of a comment, or the last 50 events',
})

vim.api.nvim_create_user_command('ReviewReanchor', function()
  require('quickfix-review').reanchor()
end, { desc = 'Re-anchor the outdated comment on current line to its current lines' })

vim.api.nvim_create_user_command('ReviewSave', function()
  require('quickfix-review').save_review()
end, { desc = 'Save review to disk' })

vim.api.nvim_create_user_command('ReviewLoad', function()
  require('quickfix-review').load_review()
end, { desc = 'Load review from disk' })

vim.api.nvim_create_user_command('ReviewSummary', function()
  require('quickfix-review').summary()
end, { desc = 'Show review summary' })

vim.api.nvim_create_user_command('ReviewGoto', function()
  require('quickfix-review').goto_real_file()
end, { desc = 'Go to real file from diff buffer' })

vim.api.nvim_create_user_command('ReviewView', function()
  require('quickfix-review').view_comment()
end, { desc = 'View comment on current line' })

vim.api.nvim_create_user_command('ReviewEdit', function()
  require('quickfix-review').edit_comment()
end, { desc = 'Edit comment at current line' })

vim.api.nvim_create_user_command('ReviewDelete', function()
  require('quickfix-review').delete_comment()
end, { desc = 'Delete comment at current line' })
