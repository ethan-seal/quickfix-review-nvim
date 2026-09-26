-- Code Review System using Signs, with the quickfix list as a view
-- Supports regular files and diff buffers (diffview, fugitive, codediff)
local M = {}

local config = require('quickfix-review.config')
local utils = require('quickfix-review.utils')
local store = require('quickfix-review.store')
local export = require('quickfix-review.export')
local context = require('quickfix-review.context')
local track = require('quickfix-review.track')

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
  local type_config = utils.get_comment_type_config(comment_type)
  if not type_config then
    print('Error: Unknown comment type: ' .. comment_type)
    return
  end

  -- Only files (and the diff buffers that map to one) can carry a comment
  local file = utils.get_real_filepath()
  local buftype = vim.bo.buftype
  if file == '' or (buftype ~= '' and buftype ~= 'acwrite' and not utils.is_special_buffer()) then
    vim.notify('quickfix-review: cannot add a comment here: this buffer is not a file',
      vim.log.levels.WARN)
    return
  end

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
    local bufnr = vim.api.nvim_get_current_buf()
    local added = store.add({
      filename = file,
      kind = comment_type:lower(),
      body = text,
      lnum = start_line,
      end_lnum = end_line,
      anchor = context.anchor(start_line, end_line, bufnr),
      context = context.capture(file, start_line, end_line, bufnr),
      created_at = os.time(),
    })
    if not added then
      vim.notify('quickfix-review: ' .. comment_type:upper() .. ' comment was not added',
        vim.log.levels.WARN)
      return
    end

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

-- Clear all review comments. With opts.confirm, ask first (default No).
function M.clear_review(opts)
  if opts and opts.confirm
      and vim.fn.confirm('Clear all review comments?', '&Yes\n&No', 2) ~= 1 then
    return
  end
  if store.clear() then
    print('Review cleared')
  end
end

local TRASH_TITLE = 'Review trash'

local function first_line(s)
  return (tostring(s or ''):match('^[^\n]*'))
end

-- Show the deleted comments, newest first, in a quickfix list of their own
-- (titled "Review trash"; the review's list is left alone). Each row carries
-- the comment's id in user_data.
function M.show_trash()
  local list = store.trash_list()
  if #list == 0 then
    print('The review trash is empty')
    return
  end
  local items = {}
  for _, t in ipairs(list) do
    local c = t.comment
    -- Where it was: its anchor, not store.range(), which would place a
    -- tracking mark for a comment that is not live
    local lnum = tonumber(type(c.anchor) == 'table' and c.anchor.lnum or c.lnum) or 1
    local time = t.ts and os.date('%Y-%m-%d %H:%M', math.floor(t.ts / 1000)) or '?'
    table.insert(items, {
      filename = c.filename,
      lnum = lnum,
      col = 1,
      text = string.format('%s %s %s: %s [%s]', time, t.op, tostring(c.kind or 'note'):upper(),
        first_line(c.body), t.id),
      user_data = { id = t.id },
    })
  end
  vim.fn.setqflist({}, ' ', { title = TRASH_TITLE, items = items })
end

-- Restore deleted comments. With an id, that comment; without one, the most
-- recently deleted comment, or every comment of the last :ReviewClear if
-- that was the last removal (asking first when it is more than one).
function M.restore_comment(id)
  local ids
  if id and id ~= '' then
    ids = { id }
  else
    local last = store.last_removal()
    if not last then
      print('Nothing to restore: the review trash is empty')
      return
    end
    ids = last.ids
    if #ids > 1 and vim.fn.confirm(string.format('Restore %d comments from the last clear?', #ids),
        '&Yes\n&No', 2) ~= 1 then
      return
    end
  end
  local res = store.restore(ids)
  if not res then return end
  if res.restored > 0 then
    print(string.format('Restored %d comment(s)', res.restored))
  elseif res.live[1] then
    print('Comment ' .. res.live[1] .. ' is already live')
  elseif res.unknown[1] then
    print('No deleted comment ' .. res.unknown[1])
  end
end

-- The event history rows of comment `id`, or of the last 50 events
function M.history_rows(id)
  local res, err = require('quickfix-review.log').read(store.log_path(), 0, 0)
  if not res then return nil, err end
  return require('quickfix-review.history').rows(res.events, id ~= '' and id or nil)
end

-- Print the event history of comment `id`, or the last 50 events
function M.history(id)
  local rows, err = M.history_rows(id)
  if not rows then
    print((vim.uv or vim.loop).fs_stat(store.log_path()) and tostring(err) or 'No review history yet')
    return
  end
  if #rows == 0 then
    print(id and id ~= '' and ('No history for ' .. id) or 'No review history yet')
    return
  end
  local chunks = {}
  for i, row in ipairs(rows) do
    chunks[i] = { row.text .. (i < #rows and '\n' or '') }
  end
  vim.api.nvim_echo(chunks, true, {})
end

-- Completion for :ReviewRestore: the ids in the trash, matching `lead`
function M.complete_trash_ids(lead)
  local out = {}
  for id in pairs(store.trash()) do
    if id:sub(1, #lead) == lead then table.insert(out, id) end
  end
  table.sort(out)
  return out
end

-- Completion for :ReviewHistory: live and deleted ids, matching `lead`
function M.complete_ids(lead)
  local out = M.complete_trash_ids(lead)
  for _, c in ipairs(store.all()) do
    if c.id:sub(1, #lead) == lead then table.insert(out, c.id) end
  end
  table.sort(out)
  return out
end

-- All review comments, in creation order. Treat as read-only.
function M.comments()
  return store.all()
end

-- Save the review. Every change is already appended to the review's log as
-- it is made; this only writes the cache of the replayed log (state.json).
function M.save_review()
  local ok, message = store.save()
  if ok then
    print(message)
  else
    vim.notify('quickfix-review: ' .. message, vim.log.levels.ERROR)
  end
end

-- Replay the review's log (ignoring the cache) and show it in the quickfix list
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
  local all = store.all()
  if #all == 0 then
    print('No review comments')
    return
  end
  -- Where each comment is now, read from the originals (the copies below
  -- are renamed, so they are never passed to the store)
  local line_of = {}
  for _, c in ipairs(all) do line_of[c.id] = (store.range(c)) end
  local sorted = vim.deepcopy(all)

  -- Name every comment on this file (however its path is spelled, e.g.
  -- through a symlink) by the first comment's spelling of it, so they order
  -- and compare as one file. `sorted` is a copy, so renaming is safe.
  local file = vim.fn.fnamemodify(utils.get_real_filepath(), ':p')
  local canonical
  for _, c in ipairs(sorted) do
    if utils.files_match(c.filename, file) then
      canonical = canonical or c.filename
      c.filename = canonical
    end
  end
  file = canonical or file

  table.sort(sorted, function(a, b)
    if a.filename ~= b.filename then return a.filename < b.filename end
    return line_of[a.id] < line_of[b.id]
  end)
  local line = vim.fn.line('.')
  local function is_after(c)
    if c.filename ~= file then return c.filename > file end
    return line_of[c.id] > line
  end
  local function is_before(c)
    if c.filename ~= file then return c.filename < file end
    return line_of[c.id] < line
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
  -- The file may have shrunk since the comment was made
  local lnum = math.max(1, math.min(line_of[target.id], vim.api.nvim_buf_line_count(0)))
  vim.api.nvim_win_set_cursor(0, { lnum, 0 })
  M.view_comment()
end

-- Show comment(s) at current line
function M.view_comment()
  local file = utils.get_real_filepath()
  local line = vim.fn.line('.')
  local comments = {}
  for _, item in ipairs(store.all()) do
    if (store.range(item)) == line and utils.files_match(item.filename, file) then
      table.insert(comments, item)
    end
  end

  if #comments == 0 then
    print('No comment on this line')
    return
  end

  -- Build lines for a floating window
  local lines = {}
  for i, c in ipairs(comments) do
    if i > 1 then table.insert(lines, '') end
    if store.is_outdated(c) then
      table.insert(lines, 'outdated — code changed since comment')
    end
    table.insert(lines, store.headline(c))
    if c.response then
      table.insert(lines, '')
      table.insert(lines, 'Response: ' .. c.response)
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

-- Comment counts for the review: { total = n, by_type = { { name, count }, ... } }
-- by_type lists every configured type (lowercase name), in utils.get_comment_types() order
function M.summary_data()
  local comments = store.all()
  local counts = {}
  for _, item in ipairs(comments) do
    counts[item.kind] = (counts[item.kind] or 0) + 1
  end

  local by_type = {}
  for _, name in ipairs(utils.get_comment_types()) do
    table.insert(by_type, { name, counts[name] or 0 })
  end
  return { total = #comments, by_type = by_type }
end

-- Show summary of current review
function M.summary()
  local data = M.summary_data()

  if data.total == 0 then
    print('No review comments')
    return
  end

  local parts = {}
  for _, entry in ipairs(data.by_type) do
    table.insert(parts, string.format('%d %s', entry[2], entry[1]))
  end
  print(string.format('Review: %d total (%s)', data.total, table.concat(parts, ', ')))
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
  local comments_deleted = store.remove_if(function(item)
    local item_start, item_end = store.range(item)
    return utils.files_match(item.filename, file) and
           item_start <= end_line and item_end >= start_line
  end)

  if comments_deleted == nil then
    vim.notify('quickfix-review: the storage file is unreadable; no comment was deleted',
      vim.log.levels.WARN)
  elseif comments_deleted > 0 then
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
    vim.keymap.set('n', keymaps.clear, function() M.clear_review({ confirm = true }) end,
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

-- Delete the comment under the cursor in the quickfix window. Each review
-- row carries its comment's id in user_data. Read it before any store call:
-- a store call may re-read the file and re-render the rows in a new order.
function M.delete_comment_from_qf()
  if vim.fn.win_gettype() ~= 'quickfix' or not store.is_current_view() then
    print('This quickfix list is not the review')
    return
  end

  local row = vim.fn.getqflist()[vim.fn.line('.')]
  local id = row and type(row.user_data) == 'table' and row.user_data.id
  if not id then
    print('No comment selected in quickfix list')
    return
  end

  local removed = store.remove(id)
  if removed == nil then
    vim.notify('quickfix-review: the storage file is unreadable; the comment was not deleted',
      vim.log.levels.WARN)
  elseif removed == 0 then
    print('Comment no longer exists')
  end
end

-- Buffer-local keys in the quickfix window that delete a review comment
local QF_DELETE_KEYS = { 'dd', '<leader>cd' }
-- Marks the maps this plugin made, so only those are removed again
local QF_DELETE_DESC = 'Delete comment from quickfix list'

-- Whether buf is the quickfix (not location list) buffer showing the review
local function shows_review(buf)
  return vim.fn.getqflist({ qfbufnr = 0 }).qfbufnr == buf and store.is_current_view()
end

-- Map the delete keys and set display options when the quickfix buffer shows
-- the review; otherwise remove the maps and leave the window options alone.
local function configure_qf_buffer(buf)
  if not shows_review(buf) then
    -- Only the plugin's own maps: another plugin's qf maps stay. Delete by
    -- the reported lhs, which has <leader> already expanded.
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
      if map.desc == QF_DELETE_DESC then
        pcall(vim.keymap.del, 'n', map.lhs, { buffer = buf })
      end
    end
    return
  end

  -- Better display of multiline comments
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    vim.wo[win][0].wrap = false
    vim.wo[win][0].number = true
    vim.wo[win][0].relativenumber = false
  end

  for _, lhs in ipairs(QF_DELETE_KEYS) do
    vim.keymap.set('n', lhs, M.delete_comment_from_qf, {
      buffer = buf,
      desc = QF_DELETE_DESC,
    })
  end
end

-- b:changedtick of each buffer when its signs were last drawn, so BufEnter
-- only redraws a buffer that changed since
local drawn_at = {}

local function draw_signs(bufnr, name, comments)
  utils.refresh_buffer_signs(bufnr, name, comments)
  drawn_at[bufnr] = vim.api.nvim_buf_get_changedtick(bufnr)
end

-- Redraw signs in every loaded buffer from the current comments, and drop
-- the tracking extmarks of comments that are gone
local function refresh_all_signs(comments)
  track.prune(comments)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local name = utils.get_real_filepath(bufnr)
      if name ~= '' then
        draw_signs(bufnr, name, comments)
      end
    end
  end
end

-- The file in `bufnr` was read or reloaded from disk: relocate its comments
-- from its content (never from a diff buffer, which holds an old revision).
-- Positions are kept in memory only; nothing is logged.
local function relocate_buffer(bufnr)
  if vim.bo[bufnr].buftype ~= '' or utils.is_special_buffer(bufnr) then return end
  local comments = store.all()
  if track.relocate_buffer(bufnr, comments) then
    store.refresh()
  else
    local name = utils.get_real_filepath(bufnr)
    if name ~= '' then draw_signs(bufnr, name, comments) end
  end
end

-- prompt_on_file_change is deprecated: warn once per session
local prompt_deprecation_shown = false

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

  -- The project follows the global cwd: after :cd, re-read the review from the
  -- new project's storage dir (the list view and signs refresh on change).
  -- :lcd and :tcd leave the project alone.
  vim.api.nvim_create_autocmd('DirChanged', {
    group = augroup,
    pattern = 'global',
    callback = function() store.all() end,
  })

  -- Cache the replayed log on exit, so the next start reads only its tail
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = augroup,
    callback = function() store.flush() end,
  })

  -- Auto-show floating comment after navigating the review's quickfix list
  vim.api.nvim_create_autocmd('QuickFixCmdPost', {
    group = augroup,
    pattern = { 'cnext', 'cprev', 'cc', 'cfirst', 'clast' },
    callback = function()
      if store.is_current_view() then M.view_comment() end
    end,
  })

  -- Draw signs when entering a buffer. Reading the review may pick up
  -- changes another Neovim logged (which redraws every buffer); otherwise
  -- only a buffer that changed since its signs were drawn is redrawn.
  vim.api.nvim_create_autocmd('BufEnter', {
    group = augroup,
    callback = function(args)
      local file = utils.get_real_filepath(args.buf)
      if file == '' then return end
      local comments = store.all()
      if drawn_at[args.buf] ~= vim.api.nvim_buf_get_changedtick(args.buf) then
        draw_signs(args.buf, file, comments)
      end
    end
  })

  -- Relocate a file's comments when it is read, and when it is reloaded
  -- after changing on disk
  vim.api.nvim_create_autocmd({ 'BufReadPost', 'FileChangedShellPost' }, {
    group = augroup,
    callback = function(args) relocate_buffer(args.buf) end,
  })
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = augroup,
    callback = function(args) drawn_at[args.buf] = nil end,
  })

  if config.options.prompt_on_file_change and not prompt_deprecation_shown then
    prompt_deprecation_shown = true
    vim.notify('quickfix-review: prompt_on_file_change is deprecated and does nothing:'
      .. ' comments now follow the file when it changes on disk', vim.log.levels.WARN)
  end

  -- Configure the quickfix window and add the delete keymaps, but only while
  -- it shows the review. FileType qf fires again on every refill (setqflist,
  -- :colder), so the maps are removed when another list replaces the review.
  vim.api.nvim_create_autocmd('FileType', {
    group = augroup,
    pattern = 'qf',
    callback = function(args)
      configure_qf_buffer(args.buf)
    end
  })
end

-- Export config for external access
M.config = config

return M
