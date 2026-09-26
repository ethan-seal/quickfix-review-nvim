-- Code Review System using Signs, with the quickfix list as a view
-- Supports regular files and diff buffers (diffview, fugitive, codediff)
local M = {}

local config = require('quickfix-review.config')
local utils = require('quickfix-review.utils')
local store = require('quickfix-review.store')
local export = require('quickfix-review.export')
local context = require('quickfix-review.context')

-- State for comment type cycling
local cycle_state = {
  current_index = 1,
  comment_types = nil
}

-- Reset cycle state based on current configuration
local function reset_cycle_state()
  cycle_state.comment_types = utils.get_comment_types()
  cycle_state.current_index = 1
end

-- Get current comment type for cycling
local function get_current_cycle_type()
  if not cycle_state.comment_types then
    reset_cycle_state()
  end
  return cycle_state.comment_types[cycle_state.current_index]
end

-- Cycle to next comment type
function M.cycle_next_comment_type()
  if not cycle_state.comment_types then
    reset_cycle_state()
  end
  
  cycle_state.current_index = cycle_state.current_index + 1
  if cycle_state.current_index > #cycle_state.comment_types then
    cycle_state.current_index = 1
  end
  
  local current_type = get_current_cycle_type()
  print('Comment type: ' .. current_type:upper() .. ' (' .. (config.options.comment_types[current_type].description or '') .. ')')
  return current_type
end

-- Cycle to previous comment type
function M.cycle_previous_comment_type()
  if not cycle_state.comment_types then
    reset_cycle_state()
  end
  
  cycle_state.current_index = cycle_state.current_index - 1
  if cycle_state.current_index < 1 then
    cycle_state.current_index = #cycle_state.comment_types
  end
  
  local current_type = get_current_cycle_type()
  print('Comment type: ' .. current_type:upper() .. ' (' .. (config.options.comment_types[current_type].description or '') .. ')')
  return current_type
end

-- Add comment using current cycle type
function M.add_comment_cycle()
  local current_type = get_current_cycle_type()
  M.add_comment(current_type)
end

-- Add comment to quickfix and place sign
-- Optional range parameter: { start_line, end_line } for multiline comments
function M.add_comment(comment_type, range)
  -- Validate comment type (ensure config is loaded)
  if not config.options or not config.options.comment_types then
    print('Error: Plugin not properly initialized. Call require("quickfix-review").setup() first.')
    return
  end
  
  local type_config = utils.get_comment_type_config(comment_type)
  if not type_config then
    print('Error: Unknown comment type: ' .. comment_type)
    return
  end

  local file = utils.get_real_filepath()
  local start_line, end_line

  if range then
    start_line = range[1]
    end_line = range[2]
    -- Ensure start_line is less than or equal to end_line
    if start_line > end_line then
      start_line, end_line = end_line, start_line
    end
  else
    start_line = vim.fn.line('.')
    end_line = start_line
  end

  local prompt = comment_type .. ' comment'
  if start_line ~= end_line then
    prompt = prompt .. ' (L' .. start_line .. '-' .. end_line .. ')'
  end
  local text = vim.fn.input(prompt .. ': ')

  if text ~= '' then
    -- Format text with line range if multiline
    local comment_text
    if start_line ~= end_line then
      comment_text = string.format('[%s:L%d-%d] %s', comment_type:upper(), start_line, end_line, text)
    else
      comment_text = string.format('[%s] %s', comment_type:upper(), text)
    end

    store.add({
      filename = file,
      lnum = start_line,
      end_lnum = end_line,
      col = 1,
      text = comment_text,
      type = comment_type:sub(1, 1):upper(),
      user_data = context.capture(file, start_line, end_line),
    })

    local display_file = vim.fn.fnamemodify(file, ':.')
    if start_line ~= end_line then
      print(comment_type:upper() .. ' added to ' .. display_file .. ':' .. start_line .. '-' .. end_line)
    else
      print(comment_type:upper() .. ' added to ' .. display_file .. ':' .. start_line)
    end
  end
end

-- Add comment from visual selection
function M.add_comment_visual(comment_type)
  -- Exit visual mode first to set the '< and '> marks
  vim.cmd('normal! \27')  -- ESC to exit visual mode

  local start_line = vim.fn.line("'<")
  local end_line = vim.fn.line("'>")

  -- Ensure start_line is less than or equal to end_line
  if start_line > end_line then
    start_line, end_line = end_line, start_line
  end

  M.add_comment(comment_type, { start_line, end_line })
end

-- Jump to real file from diff buffer
function M.goto_real_file()
  if not utils.is_special_buffer() then
    print('Already in a regular file')
    return
  end

  local real_file = utils.get_real_filepath()
  local line = vim.fn.line('.')

  if real_file:match('^diffview://') or real_file:match('^fugitive://') or real_file:match('^codediff://') then
    print('Error: Cannot determine real file from buffer')
    return
  end

  vim.cmd('edit +' .. line .. ' ' .. vim.fn.fnameescape(real_file))
  print('Jumped to ' .. vim.fn.fnamemodify(real_file, ':.') .. ':' .. line)
end

-- Export to markdown
function M.export_review()
  local comments = store.all()

  if #comments == 0 then
    print('No comments to export')
    return
  end

  local content, err = export.to_markdown(comments, config.options)
  if not content then
    print(err or 'Export failed')
    return
  end

  local success, message = export.to_clipboard_and_file(content, config.options.export_file)
  if success then
    print(message .. ' (' .. #comments .. ' comments)')
  else
    print(message)
  end
end

-- Clear all review comments
function M.clear_review()
  store.clear()
  print('Review cleared')
end

-- All review comments, in creation order. Treat as read-only.
function M.comments()
  return store.all()
end

-- Save review to file. Every change is already saved as it is made; this
-- only forces a write.
function M.save_review()
  local _, message = store.save()
  print(message)
end

-- Re-read the review from file and show it in the quickfix list
function M.load_review()
  local ok, message = store.reload()
  if ok then store.show() end
  print(message)
end

-- Make the review the current quickfix list, without opening the window
function M.show_list()
  store.show()
end

-- Show the review in the quickfix list and open the quickfix window
function M.open_list()
  store.show()
  vim.cmd('copen')
end

-- Jump to the next (direction 1) or previous (direction -1) comment across
-- all files, ordered by file then line, wrapping around at the ends
function M.jump_comment(direction)
  local sorted = vim.deepcopy(store.all())
  if #sorted == 0 then
    print('No review comments')
    return
  end
  table.sort(sorted, function(a, b)
    if a.filename ~= b.filename then return a.filename < b.filename end
    return a.lnum < b.lnum
  end)

  local file = vim.fn.fnamemodify(utils.get_real_filepath(), ':p')
  local line = vim.fn.line('.')
  local function is_after(c)
    if c.filename ~= file then return c.filename > file end
    return c.lnum > line
  end
  local function is_before(c)
    if c.filename ~= file then return c.filename < file end
    return c.lnum < line
  end

  local target
  if direction > 0 then
    for _, c in ipairs(sorted) do
      if is_after(c) then target = c break end
    end
    target = target or sorted[1]
  else
    for i = #sorted, 1, -1 do
      if is_before(sorted[i]) then target = sorted[i] break end
    end
    target = target or sorted[#sorted]
  end

  if target.filename ~= file then
    vim.cmd('edit ' .. vim.fn.fnameescape(target.filename))
  end
  vim.api.nvim_win_set_cursor(0, { target.lnum, 0 })
  M.view_comment()
end

-- Show comment(s) at current line
function M.view_comment()
  local file = utils.get_real_filepath()
  local line = vim.fn.line('.')
  local comments = {}
  for _, item in ipairs(store.all()) do
    if item.lnum == line and utils.files_match(item.filename, file) then
      table.insert(comments, item.text)
    end
  end

  if #comments == 0 then
    print('No comment on this line')
    return
  end

  -- Build lines for a floating window
  local lines = {}
  for i, text in ipairs(comments) do
    if i > 1 then table.insert(lines, '') end
    local comment, response = text:match('^(.-)%s*|%s*Response:%s*(.+)$')
    if comment and response then
      table.insert(lines, comment)
      table.insert(lines, '')
      table.insert(lines, 'Response: ' .. response)
    else
      table.insert(lines, text)
    end
  end

  local width = math.min(80, vim.o.columns - 4)
  -- Word-wrap lines to fit width
  local wrapped = {}
  for _, line in ipairs(lines) do
    if line == '' then
      table.insert(wrapped, '')
    else
      while #line > width do
        local cut = line:sub(1, width):match('.*()%s') or width
        table.insert(wrapped, line:sub(1, cut))
        line = line:sub(cut + 1):gsub('^%s+', '')
      end
      table.insert(wrapped, line)
    end
  end

  local height = math.min(#wrapped, 20)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, wrapped)
  vim.bo[buf].modifiable = false

  local win = vim.api.nvim_open_win(buf, false, {
    relative = 'cursor', row = 1, col = 0,
    width = width, height = height,
    style = 'minimal', border = 'rounded',
  })
  vim.wo[win].wrap = true

  -- Close on cursor move or leaving the buffer. The handler lives in the
  -- QuickfixReviewFloat group and removes itself (both events) on close.
  local float_group = vim.api.nvim_create_augroup('QuickfixReviewFloat', { clear = false })
  local close_id
  close_id = vim.api.nvim_create_autocmd({ 'CursorMoved', 'BufLeave' }, {
    group = float_group,
    callback = function()
      pcall(vim.api.nvim_win_close, win, true)
      pcall(vim.api.nvim_del_autocmd, close_id)
    end,
  })
end

-- Show summary of current review
function M.summary()
  local comments = store.all()

  if #comments == 0 then
    print('No review comments')
    return
  end

  local counts = { ISSUE = 0, SUGGESTION = 0, NOTE = 0, PRAISE = 0 }
  for _, item in ipairs(comments) do
    local comment_type = utils.parse_comment_type(item.text)
    if counts[comment_type] then
      counts[comment_type] = counts[comment_type] + 1
    end
  end

  print(string.format('Review: %d total (%d issues, %d suggestions, %d notes, %d praise)',
    #comments, counts.ISSUE, counts.SUGGESTION, counts.NOTE, counts.PRAISE))
end

-- Delete comment(s) at current line or selected range
function M.delete_comment(range)
  local file = utils.get_real_filepath()
  local start_line, end_line
  
  if range then
    start_line = range[1]
    end_line = range[2]
    -- Ensure start_line is less than or equal to end_line
    if start_line > end_line then
      start_line, end_line = end_line, start_line
    end
  else
    start_line = vim.fn.line('.')
    end_line = start_line
  end
  
  -- Remove comments overlapping the specified range
  local comments_deleted = store.remove(function(item)
    local item_end = item.end_lnum or item.lnum
    return utils.files_match(item.filename, file) and
           item.lnum <= end_line and item_end >= start_line
  end)

  if comments_deleted > 0 then
    local display_file = vim.fn.fnamemodify(file, ':.')
    if start_line ~= end_line then
      print(string.format('Deleted %d comment(s) from %s:%d-%d', comments_deleted, display_file, start_line, end_line))
    else
      print(string.format('Deleted %d comment(s) from %s:%d', comments_deleted, display_file, start_line))
    end
  else
    local display_file = vim.fn.fnamemodify(file, ':.')
    if start_line ~= end_line then
      print(string.format('No comments found in %s:%d-%d', display_file, start_line, end_line))
    else
      print(string.format('No comments found in %s:%d', display_file, start_line))
    end
  end
end

-- Delete comment from visual selection
function M.delete_comment_visual()
  -- Exit visual mode first to set the '< and '> marks
  vim.cmd('normal! \27')  -- ESC to exit visual mode

  local start_line = vim.fn.line("'<")
  local end_line = vim.fn.line("'>")

  -- Ensure start_line is less than or equal to end_line
  if start_line > end_line then
    start_line, end_line = end_line, start_line
  end

  M.delete_comment({ start_line, end_line })
end

-- Setup keymaps based on configuration
local function setup_keymaps()
  local keymaps = config.options.keymaps

  -- Dynamically set up keymaps for each comment type
  for type_name, _ in pairs(config.options.comment_types) do
    local keymap_key = 'add_' .. type_name
    local keymap = keymaps[keymap_key]
    if keymap then
      local type_upper = type_name:upper()
      vim.keymap.set('n', keymap, function() M.add_comment(type_upper) end,
        { desc = 'Add ' .. type_upper .. ' comment' })
      vim.keymap.set('v', keymap, function() M.add_comment_visual(type_upper) end,
        { desc = 'Add ' .. type_upper .. ' comment for selection' })
    end
  end

  -- Add keymaps for comment type cycling
  if keymaps.add_comment_cycle then
    vim.keymap.set('n', keymaps.add_comment_cycle, M.add_comment_cycle,
      { desc = 'Add comment (cycle types with Tab)' })
    vim.keymap.set('v', keymaps.add_comment_cycle, function() M.add_comment_visual(get_current_cycle_type()) end,
      { desc = 'Add comment for selection (cycle types with Tab)' })
  end
  
  if keymaps.cycle_next then
    vim.keymap.set('n', keymaps.cycle_next, M.cycle_next_comment_type,
      { desc = 'Cycle to next comment type' })
  end
  
  if keymaps.cycle_previous then
    vim.keymap.set('n', keymaps.cycle_previous, M.cycle_previous_comment_type,
      { desc = 'Cycle to previous comment type' })
  end
  
  -- Add keymaps for comment deletion
  if keymaps.delete_comment then
    vim.keymap.set('n', keymaps.delete_comment, function() M.delete_comment() end,
      { desc = 'Delete comment at current line' })
    vim.keymap.set('v', keymaps.delete_comment, M.delete_comment_visual,
      { desc = 'Delete comments in selection' })
  end

  if keymaps.export then
    vim.keymap.set('n', keymaps.export, M.export_review,
      { desc = 'Export review to markdown' })
  end
  if keymaps.clear then
    vim.keymap.set('n', keymaps.clear, M.clear_review,
      { desc = 'Clear all review comments' })
  end
  if keymaps.summary then
    vim.keymap.set('n', keymaps.summary, M.summary,
      { desc = 'Show review summary' })
  end

  if keymaps.save then
    vim.keymap.set('n', keymaps.save, M.save_review,
      { desc = 'Save review to disk' })
  end
  if keymaps.load then
    vim.keymap.set('n', keymaps.load, M.load_review,
      { desc = 'Load review from disk' })
  end

  if keymaps.open_list then
    vim.keymap.set('n', keymaps.open_list, M.open_list,
      { desc = 'Open review comments list' })
  end
  if keymaps.next_comment then
    vim.keymap.set('n', keymaps.next_comment, function() M.jump_comment(1) end,
      { desc = 'Next review comment' })
  end
  if keymaps.prev_comment then
    vim.keymap.set('n', keymaps.prev_comment, function() M.jump_comment(-1) end,
      { desc = 'Previous review comment' })
  end

  if keymaps.goto_real_file then
    vim.keymap.set('n', keymaps.goto_real_file, M.goto_real_file,
      { desc = 'Go to real file from diff' })
  end

  if keymaps.view then
    vim.keymap.set('n', keymaps.view, M.view_comment,
      { desc = 'View comment on current line' })
  end
end

-- Delete the comment under the cursor in the quickfix window. The review
-- view lists the comments in store order, so the row is the comment's index.
function M.delete_comment_from_qf()
  if not store.is_current_view() then
    print('This quickfix list is not the review')
    return
  end

  local target = store.all()[vim.fn.line('.')]
  if not target then
    print('No comment selected in quickfix list')
    return
  end

  store.remove(function(c) return c == target end)
end

-- Redraw signs in every loaded buffer from the current comments
local function refresh_all_signs(comments)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name ~= '' then
        utils.refresh_buffer_signs(bufnr, name, comments)
      end
    end
  end
end

-- Setup the plugin
function M.setup(opts)
  -- Clearing the group makes setup() safe to call more than once
  local augroup = vim.api.nvim_create_augroup('QuickfixReview', { clear = true })

  config.setup(opts)
  utils.init_signs(config.options)
  setup_keymaps()

  -- Load the saved review now, so it's in place before any change is made
  store.set_on_change(refresh_all_signs)
  refresh_all_signs(store.all())

  -- Auto-show floating comment after navigating the review's quickfix list
  vim.api.nvim_create_autocmd('QuickFixCmdPost', {
    group = augroup,
    pattern = { 'cnext', 'cprev', 'cc', 'cfirst', 'clast' },
    callback = function()
      if store.is_current_view() then M.view_comment() end
    end,
  })

  -- Place signs when entering a buffer (also picks up changes made on disk)
  vim.api.nvim_create_autocmd('BufEnter', {
    group = augroup,
    callback = function()
      local file = vim.fn.expand('%:p')
      if file == '' then return end
      utils.refresh_buffer_signs(vim.fn.bufnr(), file, store.all())
    end
  })

  -- Prompt to clear comments when file is reloaded from disk
  if config.options.prompt_on_file_change then
    vim.api.nvim_create_autocmd('FileChangedShellPost', {
      group = augroup,
      callback = function()
        local file = utils.get_real_filepath()
        local function in_file(item) return utils.files_match(item.filename, file) end
        local has_comments = false
        for _, item in ipairs(store.all()) do
          if in_file(item) then
            has_comments = true
            break
          end
        end
        if has_comments then
          local choice = vim.fn.confirm('File changed on disk. Clear review comments for this file?', '&Yes\n&No', 2)
          if choice == 1 then
            store.remove(in_file)
          end
        end
      end
    })
  end

  -- Set up quickfix window configuration and keymaps
  vim.api.nvim_create_autocmd('FileType', {
    group = augroup,
    pattern = 'qf',
    callback = function()
      -- Configure quickfix window for better display of multiline comments
      vim.opt_local.wrap = false
      vim.opt_local.number = true
      vim.opt_local.relativenumber = false

      -- Add keymaps for comment deletion
      vim.keymap.set('n', 'dd', M.delete_comment_from_qf, {
        buffer = true,
        desc = 'Delete comment from quickfix list'
      })
      vim.keymap.set('n', '<leader>cd', M.delete_comment_from_qf, {
        buffer = true,
        desc = 'Delete comment from quickfix list'
      })
      
      -- Add keymap to refresh quickfix display
      vim.keymap.set('n', '<leader>cr', function()
        vim.cmd('copen')
        print('Quickfix list refreshed')
      end, {
        buffer = true,
        desc = 'Refresh quickfix list'
      })
    end
  })
end

-- Export config for external access
M.config = config

return M
