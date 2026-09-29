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
  local text = vim.fn.input(prompt .. ': ')

  if text ~= '' then
    local bufnr = vim.api.nvim_get_current_buf()
    -- One location for the anchor's snapshot and the add event naming it
    local added = store.with_location(function()
      return store.add({
        filename = file,
        kind = comment_type:lower(),
        body = text,
        lnum = start_line,
        end_lnum = end_line,
        anchor = context.anchor(start_line, end_line, bufnr),
        context = context.capture(file, start_line, end_line, bufnr),
        created_at = os.time(),
      })
    end)
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

  local removed, failure = store.remove(id)
  if removed == nil and failure == 'partial' then
    vim.notify('quickfix-review: the change was only partly written; the comment may not have been deleted',
      vim.log.levels.WARN)
  elseif removed == nil then
    vim.notify('quickfix-review: the review could not be changed; the comment was not deleted',
      vim.log.levels.WARN)
  elseif removed == 0 then
    print('Comment no longer exists')
  end
end

-- A multi-line body (one from an import or an external tool) is edited in a
-- single-line prompt as escaped text: a line break is `\n` and a backslash
-- `\\`. Single-line bodies are edited as they are, backslashes and all.
local function escape_body(body)
  return (body:gsub('\\', '\\\\'):gsub('\n', '\\n'))
end

-- Inverse of escape_body: `\n` is a line break, `\\` a backslash; any other
-- backslash is kept as typed
local function unescape_body(text)
  return (text:gsub('\\(.)', function(ch)
    if ch == 'n' then return '\n' end
    if ch == '\\' then return '\\' end
    return '\\' .. ch
  end))
end

-- Ask for a new body for the comment with this id, prefilled with its current
-- one, and save it. A cancelled or empty input changes nothing. A multi-line
-- body is prefilled escaped (see escape_body) and the answer unescaped, so
-- accepting the prefill unchanged keeps its line breaks and logs nothing.
local function prompt_edit(id, old)
  old = old or ''
  local multiline = old:find('\n', 1, true) ~= nil
  local opts = { prompt = 'Edit comment: ', default = old }
  if multiline then
    opts = { prompt = 'Edit comment (\\n = line break): ', default = escape_body(old) }
  end
  vim.ui.input(opts, function(input)
    if input == nil or input == '' then return end
    if multiline then
      input = unescape_body(input)
    end
    local result = store.edit(id, input)
    if result == nil then
      vim.notify('quickfix-review: the review could not be changed; the comment was not edited',
        vim.log.levels.WARN)
    elseif result == 'missing' then
      print('Comment no longer exists')
    elseif result == 'edited' then
      print('Comment edited')
    end
  end)
end

-- Edit the text of a comment: the one on the row under the cursor in the
-- review's quickfix window, otherwise the one covering the cursor line (a
-- choice is offered when several do). Ids and bodies are taken before any
-- prompt, since vim.ui prompts may return after the review has changed.
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
    prompt_edit(id, c.body)
    return
  end

  local matches = {}
  for _, c in ipairs(comments_on_line()) do
    table.insert(matches, { id = c.id, body = c.body, headline = store.headline(c) })
  end
  if #matches == 0 then
    print(no_comment_message())
  elseif #matches == 1 then
    prompt_edit(matches[1].id, matches[1].body)
  else
    vim.ui.select(matches, {
      prompt = 'Edit which comment?',
      -- First line only: a multi-line body would break the picker row
      format_item = function(m) return (m.headline:match('^[^\n]*')) end,
    }, function(m)
      if m then prompt_edit(m.id, m.body) end
    end)
  end
end

-- Re-read the configured types after setup() (see sync_cycle_state)
M.sync_cycle_state = sync_cycle_state

-- The comment type the cycle is on
M.current_cycle_type = get_current_cycle_type

return M
