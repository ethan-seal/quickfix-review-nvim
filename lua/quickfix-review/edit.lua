-- Comment add, view, edit and delete flows, and the comment type cycle.
-- Reached through the thin re-exports in init.lua (require('quickfix-review')).
local M = {}

local config = require('quickfix-review.config')
local utils = require('quickfix-review.utils')
local store = require('quickfix-review.store')
local context = require('quickfix-review.context')
local jump = require('quickfix-review.jump')

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

-- Re-read the configured types after setup(): keep the current type when it
-- is still configured, otherwise fall back to the first one
local function sync_cycle_state()
  if not cycle_state.comment_types then return end
  local current = cycle_state.comment_types[cycle_state.current_index]
  reset_cycle_state()
  for i, name in ipairs(cycle_state.comment_types) do
    if name == current then
      cycle_state.current_index = i
      break
    end
  end
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

-- The reason given for a refused change that names none
local UNCHANGED = 'the review could not be changed'

-- Keep text the user typed for a change that failed: in the unnamed
-- register, and in the input history, so it can be pasted or recalled with
-- <Up>
local function keep_typed(text)
  vim.fn.setreg('"', text)
  vim.fn.histadd('input', text)
end

-- Text typed at an add prompt that was cancelled, or whose add was refused,
-- by file and line range: offered again by the next add prompt there. Not
-- logged, so it is gone after a restart.
local drafts = {}

local function draft_key(file, start_line, end_line)
  return utils.path_key(file) .. ':' .. start_line .. '-' .. end_line
end

-- vim.fn.input, but also says whether it was cancelled (<Esc>, <C-c>) and
-- what was typed when it was: input() returns '' for a cancel, as it does
-- for an empty <CR>
-- Returns: text, cancelled (boolean)
local function prompt_text(prompt, default)
  local left = { abort = false, text = '' }
  local id = vim.api.nvim_create_autocmd('CmdlineLeave', {
    pattern = '@',
    once = true,
    callback = function()
      left = { abort = vim.v.event.abort, text = vim.fn.getcmdline() }
    end,
  })
  local ok, text = pcall(vim.fn.input, { prompt = prompt, default = default or '' })
  pcall(vim.api.nvim_del_autocmd, id)
  if not ok or left.abort then return left.text, true end
  return text, false
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
  -- A diff-plugin buffer that shows no file (a panel, diffview://null, a
  -- fugitive summary or commit): its name did not map to a path
  if utils.is_unresolved(file) then
    vim.notify('quickfix-review: cannot add a comment here: this buffer does not show a file',
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
  local key = draft_key(file, start_line, end_line)
  local text, cancelled = prompt_text(prompt .. ': ', drafts[key])
  if cancelled then
    if text ~= '' then
      drafts[key] = text
      keep_typed(text)
      vim.notify('quickfix-review: ' .. comment_type:upper() .. ' comment not added (cancelled); '
        .. 'the text is kept for the next comment on this line, and in register "', vim.log.levels.WARN)
    end
    return
  end

  if text ~= '' then
    local bufnr = vim.api.nvim_get_current_buf()
    -- One location for the anchor's snapshot and the add event naming it.
    -- The git callback is scheduled, so it runs after the add has returned
    local stored = false
    local added, err = store.with_location(function()
      -- git runs in the background: its context is logged by an update
      -- once it is done, to this comment in this review only
      local id, key = store.new_id(), store.review_key()
      return store.add({
        id = id,
        filename = file,
        kind = comment_type:lower(),
        body = text,
        lnum = start_line,
        end_lnum = end_line,
        anchor = context.anchor(start_line, end_line, bufnr),
        context = context.capture_async(file, start_line, end_line, bufnr, function(ctx)
          if stored then store.set_context(key, id, ctx) end
        end),
        created_at = os.time(),
      })
    end)
    if not added then
      drafts[key] = text
      keep_typed(text)
      vim.notify('quickfix-review: ' .. comment_type:upper() .. ' comment was not added ('
        .. (err or UNCHANGED) .. '); the text is in register "', vim.log.levels.WARN)
      return
    end
    stored = true
    drafts[key] = nil

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


-- Split `line` into pieces at most `width` display cells wide, breaking at the
-- last whitespace that fits (kept on the piece) or else hard-cutting. Widths
-- are measured in cells and cuts fall on character boundaries, so multibyte
-- and double-width text wraps without splitting a character.
local function wrap_line(line, width)
  local out = {}
  while vim.fn.strdisplaywidth(line) > width do
    -- The longest character prefix that fits in width cells
    local nchars, n, cells = vim.fn.strchars(line), 0, 0
    while n < nchars do
      local w = vim.fn.strdisplaywidth(vim.fn.strcharpart(line, n, 1))
      if cells + w > width then break end
      cells, n = cells + w, n + 1
    end
    -- A single character wider than the float still makes progress
    if n == 0 then n = 1 end
    local head = vim.fn.strcharpart(line, 0, n)
    -- %s only matches ASCII bytes, so a cut after one is a character boundary
    local cut = head:match('.*()%s') or #head
    table.insert(out, line:sub(1, cut))
    line = line:sub(cut + 1):gsub('^%s+', '')
  end
  table.insert(out, line)
  return out
end

-- Every comment whose range (as shown in the current buffer) covers the
-- cursor line, sorted by start line
local function comments_on_line()
  local file = utils.get_real_filepath()
  local line = vim.fn.line('.')
  local comments = {}
  local start_of = {}
  local bufnr = vim.api.nvim_get_current_buf()
  store.all()
  if file == '' then return comments end
  for _, item in ipairs(store.in_file(utils.path_key(file))) do
    local lnum, end_lnum = utils.range_in(item, bufnr)
    if lnum and lnum <= line and end_lnum >= line then
      table.insert(comments, item)
      start_of[item] = lnum
    end
  end
  table.sort(comments, function(a, b) return start_of[a] < start_of[b] end)
  return comments
end

local DIFF_MISS = 'No comment on this line (diff buffer shows another revision)'

-- Whether diff buffer `bufnr` hides some comment on `file`: one with no
-- anchor snapshot, or anchored to another revision than the buffer holds
local function hidden_in_diff_buffer(bufnr, file)
  if not utils.is_special_buffer(bufnr) then return false end
  for _, item in ipairs(store.all()) do
    if utils.files_match(item.filename, file) and utils.range_in(item, bufnr) == nil then
      return true
    end
  end
  return false
end

-- The message for a line with no comment in the current buffer
local function no_comment_message()
  if hidden_in_diff_buffer(vim.api.nvim_get_current_buf(), utils.get_real_filepath()) then
    return DIFF_MISS
  end
  return 'No comment on this line'
end

-- Show every comment whose range covers the current line, in line order
function M.view_comment()
  local comments = comments_on_line()

  if #comments == 0 then
    print(no_comment_message())
    return
  end

  -- A diff buffer shows a comment only where it holds the anchor's own
  -- snapshot, so the comment is current there: its working-file state is
  -- left out, as it is from the sign
  local special = utils.is_special_buffer(vim.api.nvim_get_current_buf())

  -- Build lines for a floating window
  local lines = {}
  for i, c in ipairs(comments) do
    if i > 1 then table.insert(lines, '') end
    if not special and store.is_outdated(c) then
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
    -- Bodies and responses may contain newlines (Lua API, external tools,
    -- imports); buffer lines cannot, so split before wrapping
    for _, part in ipairs(vim.split(line, '\n', { plain = true })) do
      vim.list_extend(wrapped, wrap_line(part, width))
    end
  end

  -- One float at a time: replace any float still open
  jump.close_float()

  local height = math.min(#wrapped, 20)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, wrapped)
  vim.bo[buf].modifiable = false

  local win = vim.api.nvim_open_win(buf, false, {
    relative = 'cursor', row = 1, col = 0,
    width = width, height = height,
    style = 'minimal', border = 'rounded',
  })
  vim.wo[win].wrap = true

  -- Close on cursor move or leaving the buffer (the jump module's handler,
  -- in the QuickfixReviewFloat group, which removes itself on close)
  jump.on_event('float_opened', { win = win })
end

-- The quickfix cursor check (jump.lua) opens the float through this
jump.set_view_comment(function() return M.view_comment() end)

-- Remove the comment with this id, warning when the review could not be
-- changed and saying so when the comment is already gone (store.remove
-- re-resolves the id, so a stale id removes nothing).
-- Returns: true when the comment was removed
local function delete_one(id)
  local removed, failure = store.remove(id)
  if removed == nil and failure == 'partial' then
    vim.notify('quickfix-review: the change was only partly written; the comment may not have been deleted',
      vim.log.levels.WARN)
  elseif removed == nil then
    vim.notify('quickfix-review: the review could not be changed; the comment was not deleted',
      vim.log.levels.WARN)
  elseif removed == 0 then
    print('Comment no longer exists')
  else
    return true
  end
  return false
end

-- Delete the comment covering the cursor line; when several do, ask which.
-- Ids are taken before the picker, since vim.ui.select may return after the
-- review has changed.
local function delete_at_cursor()
  local file = utils.get_real_filepath()
  local line = vim.fn.line('.')
  local display_file = vim.fn.fnamemodify(file, ':.')
  local function delete(id)
    if delete_one(id) then
      print(string.format('Deleted 1 comment(s) from %s:%d', display_file, line))
    end
  end

  local matches = {}
  for _, c in ipairs(comments_on_line()) do
    table.insert(matches, { id = c.id, headline = store.headline(c) })
  end
  if #matches == 0 then
    if hidden_in_diff_buffer(vim.api.nvim_get_current_buf(), file) then
      print(DIFF_MISS)
    else
      print(string.format('No comments found in %s:%d', display_file, line))
    end
  elseif #matches == 1 then
    delete(matches[1].id)
  else
    vim.ui.select(matches, {
      prompt = 'Delete which comment?',
      -- First line only: a multi-line body would break the picker row
      format_item = function(m) return (m.headline:match('^[^\n]*')) end,
    }, function(m)
      if m then delete(m.id) end
    end)
  end
end

-- Delete the comment at the current line (a choice is offered when several
-- cover it), or every comment overlapping `range` ({start_line, end_line})
function M.delete_comment(range)
  if not range then
    delete_at_cursor()
    return
  end

  local file = utils.get_real_filepath()
  local start_line = range[1]
  local end_line = range[2]
  -- Ensure start_line is less than or equal to end_line
  if start_line > end_line then
    start_line, end_line = end_line, start_line
  end

  -- Remove comments overlapping the specified range
  local bufnr = vim.api.nvim_get_current_buf()
  local comments_deleted, failure = store.remove_if(function(item)
    local item_start, item_end = utils.range_in(item, bufnr)
    return item_start ~= nil and utils.files_match(item.filename, file) and
           item_start <= end_line and item_end >= start_line
  end)

  if comments_deleted == nil and failure == 'partial' then
    vim.notify('quickfix-review: the change was only partly written; some comments may not have been deleted',
      vim.log.levels.WARN)
  elseif comments_deleted == nil then
    vim.notify('quickfix-review: the review could not be changed; no comment was deleted',
      vim.log.levels.WARN)
  elseif comments_deleted > 0 then
    local display_file = vim.fn.fnamemodify(file, ':.')
    if start_line ~= end_line then
      print(string.format('Deleted %d comment(s) from %s:%d-%d', comments_deleted, display_file, start_line, end_line))
    else
      print(string.format('Deleted %d comment(s) from %s:%d', comments_deleted, display_file, start_line))
    end
  elseif hidden_in_diff_buffer(bufnr, file) then
    print(DIFF_MISS)
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

  delete_one(id)
end

-- The name of the editor buffer for the comment with this id
local EDITOR_PREFIX = 'quickfix-review://edit/'

-- The editor float's title: the type it will save
local function editor_title(kind)
  return ' ' .. tostring(kind or '?'):upper() .. ' '
end

-- The editor float's footer: its keys, the type keys only when mapped
local function editor_footer()
  local keymaps = config.options.keymaps or {}
  local cycle = {}
  if keymaps.cycle_next then table.insert(cycle, keymaps.cycle_next) end
  if keymaps.cycle_previous then table.insert(cycle, keymaps.cycle_previous) end
  local footer = ' <CR> save · q cancel '
  if #cycle > 0 then footer = footer .. '· ' .. table.concat(cycle, '/') .. ' type ' end
  return footer
end

-- Edit the comment with this id (`comment` as read before opening: its body
-- and kind) in an entered scratch float holding its body, one buffer line per
-- line. <CR> or :w saves the text and the type the float's title shows (one
-- update, nothing when neither changed); q or <Esc> closes it without
-- saving. The cycle keys step the type shown, without touching the cycle of
-- the type <leader>ca adds. A failed save keeps the float open.
local function open_editor(id, comment)
  -- One float at a time: the view float goes
  jump.close_float()

  local name = EDITOR_PREFIX .. id
  -- By exact name: bufnr() would also take a unique partial match
  local existing
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b) == name then existing = b break end
  end
  if existing then
    -- Already being edited (left with <C-w>p): go back to it
    local existing_win = vim.fn.bufwinid(existing)
    if existing_win ~= -1 then
      vim.api.nvim_set_current_win(existing_win)
      return
    end
    vim.api.nvim_buf_delete(existing, { force = true })
  end

  local lines = vim.split(comment.body or '', '\n', { plain = true })
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].buftype = 'acwrite'
  vim.api.nvim_buf_set_name(buf, name)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false

  local pending_kind = comment.kind
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'cursor', row = 1, col = 0,
    width = math.min(80, vim.o.columns - 4),
    height = math.max(3, math.min(15, #lines)),
    style = 'minimal', border = 'rounded',
    title = editor_title(pending_kind),
    footer = editor_footer(),
  })
  vim.wo[win].wrap = true

  local function close()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  end

  -- Save the float's text and pending type. Returns the message to give once
  -- the float is closed ('' for none), or nil when the float must stay open.
  local function save()
    local text_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    while #text_lines > 0 and text_lines[#text_lines]:match('^%s*$') do
      table.remove(text_lines)
    end
    if #text_lines == 0 then
      print('Comment text is empty (q to cancel)')
      return nil
    end
    local text = table.concat(text_lines, '\n')
    local result, err = store.edit(id, text, pending_kind)
    if result == nil then
      -- The float stays open: with the register, the only copy of the text
      keep_typed(text)
      vim.notify('quickfix-review: the comment was not edited (' .. (err or UNCHANGED)
        .. '); the text is in register "', vim.log.levels.WARN)
      return nil
    end
    vim.bo[buf].modified = false
    if result == 'missing' then return 'Comment no longer exists' end
    if result == 'edited' then return 'Comment edited' end
    return ''
  end

  -- <CR>: save and close now
  local function save_and_close()
    local msg = save()
    if msg == nil then return end
    close()
    if msg ~= '' then print(msg) end
  end

  -- :w (and :wq, :x): the write is still running, and :wq/:x quit the current
  -- window once it returns. Closing the float here would make that the code
  -- window, so the close waits until the write is done; after :wq/:x the
  -- float is already gone and it does nothing.
  local function save_on_write()
    local msg = save()
    if msg == nil then return end
    if msg ~= '' then print(msg) end
    vim.schedule(close)
  end

  -- Step the pending type through the configured ones. A kind no longer
  -- configured sits just before the first: next goes to the first type,
  -- previous to the last.
  local function step(dir)
    local types = utils.get_comment_types()
    if #types == 0 then return end
    local idx = 0
    for i, t in ipairs(types) do
      if t == pending_kind then idx = i break end
    end
    if dir > 0 then
      pending_kind = types[idx % #types + 1]
    else
      pending_kind = types[idx <= 1 and #types or idx - 1]
    end
    -- Title only: a full config round-trip would re-anchor the float to the
    -- cursor inside it
    vim.api.nvim_win_set_config(win, { title = editor_title(pending_kind) })
  end

  vim.api.nvim_create_autocmd('BufWriteCmd', { buffer = buf, callback = save_on_write })
  local function map(lhs, fn, desc)
    vim.keymap.set('n', lhs, fn, { buffer = buf, nowait = true, silent = true, desc = desc })
  end
  map('<CR>', save_and_close, 'Save the comment')
  map('q', close, 'Close without saving')
  map('<Esc>', close, 'Close without saving')
  local keymaps = config.options.keymaps or {}
  if keymaps.cycle_next then map(keymaps.cycle_next, function() step(1) end, 'Next comment type') end
  if keymaps.cycle_previous then map(keymaps.cycle_previous, function() step(-1) end, 'Previous comment type') end
end

-- Edit the text and type of a comment: the one on the row under the cursor
-- in the review's quickfix window, otherwise the one covering the cursor line
-- (a choice is offered when several do), in an editor float (see
-- open_editor). Ids, bodies and kinds are taken before any prompt, since
-- vim.ui prompts may return after the review has changed.
function M.edit_comment()
  if vim.fn.win_gettype() == 'quickfix' then
    if not store.is_current_view() then
      print('This quickfix list is not the review')
      return
    end
    -- Read the row before any store call: one may re-render the rows
    local row = vim.fn.getqflist()[vim.fn.line('.')]
    local id = row and type(row.user_data) == 'table' and row.user_data.id
    if not id then
      print('No comment selected in quickfix list')
      return
    end
    local c = store.get(id)
    if not c then
      print('Comment no longer exists')
      return
    end
    open_editor(id, c)
    return
  end

  local matches = {}
  for _, c in ipairs(comments_on_line()) do
    table.insert(matches, { id = c.id, body = c.body, kind = c.kind, headline = store.headline(c) })
  end
  if #matches == 0 then
    print(no_comment_message())
  elseif #matches == 1 then
    open_editor(matches[1].id, matches[1])
  else
    vim.ui.select(matches, {
      prompt = 'Edit which comment?',
      -- First line only: a multi-line body would break the picker row
      format_item = function(m) return (m.headline:match('^[^\n]*')) end,
    }, function(m)
      if m then open_editor(m.id, m) end
    end)
  end
end

-- Re-read the configured types after setup() (see sync_cycle_state)
M.sync_cycle_state = sync_cycle_state

-- The comment type the cycle is on
M.current_cycle_type = get_current_cycle_type

return M
