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

  if utils.is_unresolved(real_file) then
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
    local time = type(t.ts) == 'number' and os.date('%Y-%m-%d %H:%M', math.floor(t.ts / 1000)) or '?'
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

-- The unreadable lines of each log (by log_id, else path) already warned
-- about, so :ReviewHistory warns about each once rather than on every call
local history_seen = {}

-- The event history rows of comment `id`, or of the last 50 events. The
-- rotated logs are read too, newest first, back only as far as needed: for
-- the last 50, until there are 50 events; for a comment, until a log whose
-- checkpoint doesn't know it (it didn't exist before that log).
function M.history_rows(id)
  local log = require('quickfix-review.log')
  local history = require('quickfix-review.history')
  id = id ~= '' and id or nil
  local function read(path)
    local key = log.read_id(path) or path
    history_seen[key] = history_seen[key] or {}
    return log.read(path, 0, 0, history_seen[key])
  end
  local res, err = read(store.log_path())
  if not res then return nil, err end
  local events, count = res.events, 0
  local function counts(evs)
    for _, ev in ipairs(evs) do
      if ev.op ~= 'checkpoint' then count = count + 1 end
    end
  end
  counts(events)
  -- The logs read, by log_id: a rotation that crashed after linking the log
  -- to its rotated name leaves that log under two names (or more, once it is
  -- rotated again). The newest one read holds all of it, so the older copies
  -- are skipped.
  local ids = {}
  if res.log_id then ids[res.log_id] = true end
  local older = store.rotated_logs()
  for i = #older, 1, -1 do
    local first = events[1]
    if not (first and first.op == 'checkpoint') then break end
    if id == nil and count >= history.LIMIT then break end
    if id ~= nil and not history.checkpoint_knows(first, id) then break end
    local r = read(older[i])
    if not r then break end
    if not (r.log_id and ids[r.log_id]) then
      if r.log_id then ids[r.log_id] = true end
      counts(r.events)
      events = vim.list_extend(vim.list_extend({}, r.events), events)
    end
  end
  return history.rows(events, id)
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

-- The review list entry last seen by auto_show_check, whether or not a float
-- opened for it: { id =, idx = }. Only a change of entry (quickfix
-- navigation) may open the float, never plain cursor movement onto it, nor
-- a refill or (re)creation of the list moving its selection.
local last_seen

-- Show the review as the current quickfix list, its selected entry seen:
-- the list appearing is not navigation
local function show_seen()
  store.show()
  if store.is_current_view() then
    local info = vim.fn.getqflist({ id = 0, idx = 0 })
    last_seen = { id = info.id, idx = info.idx }
  end
end

-- A refill moved the list's selection (before_idx to after_idx). Seen, unless
-- a navigation to before_idx hasn't been checked yet: that one still counts.
local function refill_seen(id, before_idx, after_idx)
  if last_seen and last_seen.id == id and last_seen.idx == before_idx then
    last_seen.idx = after_idx
  end
end

-- Replay the review's log (ignoring the cache) and show it in the quickfix list
function M.load_review()
  local ok, message = store.reload()
  if ok then show_seen() end
  print(message)
end

-- Make the review the current quickfix list, without opening the window
function M.show_list()
  show_seen()
end

-- Show the review in the quickfix list and open the quickfix window
function M.open_list()
  show_seen()
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

  -- In a diff buffer, comments on the file it shows sit where signs and view
  -- put them (their anchor's lines in this revision); those this revision
  -- does not show are skipped. Other files keep store.range, since the jump
  -- opens the real file.
  if utils.is_special_buffer(0) then
    local shown = {}
    for _, c in ipairs(sorted) do
      if c.filename == file then line_of[c.id] = (utils.range_in(c, 0)) end
      if line_of[c.id] then table.insert(shown, c) end
    end
    sorted = shown
    if #sorted == 0 then
      print('No review comments')
      return
    end
  end

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
  -- Open the float once the jump has settled: the main loop dispatches the
  -- jump's CursorMoved after this returns, which would close a float opened
  -- now. Skip it if the cursor has gone elsewhere by then.
  local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  vim.schedule(function()
    if vim.api.nvim_get_current_win() == win and vim.api.nvim_get_current_buf() == buf
      and vim.fn.line('.') == lnum then
      M.view_comment()
    end
  end)
end

-- The open comment float, if any: { win = id, autocmd = id }
local float_state

-- Close the comment float (if still open) and remove its close handler
local function close_float()
  if not float_state then return end
  pcall(vim.api.nvim_win_close, float_state.win, true)
  pcall(vim.api.nvim_del_autocmd, float_state.autocmd)
  float_state = nil
end

-- Show the float if the cursor has just landed on a new entry of the review
-- quickfix list (:cnext, :cprev, :cc, :cfirst, :clast). Runs scheduled, after
-- the navigation's events, so everything is re-checked here.
-- Waits while a jump's relocation refill is deferred (finish_jump checks).
local jump_finishing = false
local function auto_show_check()
  if jump_finishing then return end
  if not store.is_current_view() then return end
  if vim.fn.win_gettype() ~= '' or vim.bo.buftype == 'quickfix' then return end
  local info = vim.fn.getqflist({ id = 0, idx = 0 })
  local changed = not last_seen or last_seen.id ~= info.id or last_seen.idx ~= info.idx
  -- Track the selection even with auto_show off, so a later reload of the
  -- selected file isn't taken for a pending jump (see pending_jump)
  last_seen = { id = info.id, idx = info.idx }
  if not config.options.auto_show then return end
  if not changed then return end
  local item = (vim.fn.getqflist({ id = 0, items = 0 }).items or {})[info.idx]
  if not item or item.bufnr ~= vim.api.nvim_get_current_buf()
    or item.lnum ~= vim.fn.line('.') then
    return
  end
  M.view_comment()
end

-- Accept where the outdated comments covering the current line are now:
-- re-anchor each to the buffer's content as it is (unsaved edits included,
-- as when adding a comment), making it current. One update event per
-- comment; nothing is logged when no outdated comment covers the line.
function M.reanchor()
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.bo[bufnr].buftype ~= '' or utils.is_special_buffer(bufnr)
      or vim.api.nvim_buf_get_name(bufnr) == '' then
    vim.notify('quickfix-review: re-anchor from the file itself, not a diff or special buffer',
      vim.log.levels.WARN)
    return
  end
  local file = vim.api.nvim_buf_get_name(bufnr)
  local line = vim.fn.line('.')
  local changes, found = {}, 0
  -- The buffer's content, read and snapshotted once for every comment
  -- re-anchored; false once the snapshot failed (warned about once)
  local pre
  for _, c in ipairs(store.all()) do
    local lnum, end_lnum = store.range(c)
    if lnum <= line and end_lnum >= line and utils.files_match(c.filename, file) then
      found = found + 1
      if store.is_outdated(c) and pre ~= false then
        if pre == nil then
          local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
          local sha, err = require('quickfix-review.snapshots').put(lines)
          if sha then
            pre = { lines = lines, sha = sha }
          else
            vim.notify('quickfix-review: snapshot not saved, comments not re-anchored: '
              .. tostring(err), vim.log.levels.WARN)
            pre = false
          end
        end
        if pre then
          local a = context.anchor(lnum, end_lnum, bufnr, pre)
          table.insert(changes, { id = c.id, anchor = a })
        end
      end
    end
  end

  if #changes == 0 then
    vim.notify(found == 0 and 'quickfix-review: no comment on this line'
      or 'quickfix-review: no outdated comment on this line', vim.log.levels.INFO)
    return
  end
  local n = store.update(changes)
  if not n then return end
  -- The tracking extmark still holds the outdated position (or is invalid,
  -- if the whole range was deleted): place it again from the new anchor
  for _, ch in ipairs(changes) do track.forget(ch.id) end
  track.relocate_buffer(bufnr, store.all())
  store.refresh()
  vim.notify(string.format('quickfix-review: re-anchored %d comment%s', n, n == 1 and '' or 's'),
    vim.log.levels.INFO)
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
  for _, item in ipairs(store.all()) do
    local lnum, end_lnum = utils.range_in(item, bufnr)
    if lnum and lnum <= line and end_lnum >= line and utils.files_match(item.filename, file) then
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
  close_float()

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

  -- Close on cursor move or leaving the buffer. The handler lives in the
  -- QuickfixReviewFloat group and removes itself (both events) on close.
  -- Closing the window wipes its buffer (bufhidden=wipe).
  local float_group = vim.api.nvim_create_augroup('QuickfixReviewFloat', { clear = false })
  float_state = { win = win }
  float_state.autocmd = vim.api.nvim_create_autocmd({ 'CursorMoved', 'BufLeave' }, {
    group = float_group,
    callback = close_float,
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
  if keymaps.edit then
    vim.keymap.set('n', keymaps.edit, M.edit_comment,
      { desc = 'Edit review comment' })
  end

  if keymaps.reanchor then
    vim.keymap.set('n', keymaps.reanchor, M.reanchor,
      { desc = 'Re-anchor the outdated comment on current line' })
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

-- Ask for a new body for the comment with this id, prefilled with its current
-- one, and save it. A cancelled or empty input changes nothing.
local function prompt_edit(id, old)
  vim.ui.input({ prompt = 'Edit comment: ', default = old or '' }, function(input)
    if input == nil or input == '' then return end
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
      format_item = function(m) return m.headline end,
    }, function(m)
      if m then prompt_edit(m.id, m.body) end
    end)
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

-- Buffers read from disk since they were created: a BufReadPost for a buffer
-- not in here is its first read (a jump into an unloaded file), not a reload
-- (:e!, :checktime). Cleared on wipeout only: a reload unloads the buffer
-- first, so clearing on BufUnload would make every reload a first read.
-- setup() seeds it with the buffers already loaded when it runs, whose read
-- the autocmd never saw.
local read_once = {}

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

-- Whether `bufnr` holds a real file (not a diff buffer or a special one)
local function is_file_buffer(bufnr)
  return vim.bo[bufnr].buftype == '' and not utils.is_special_buffer(bufnr)
    and vim.api.nvim_buf_get_name(bufnr) ~= ''
end

-- The review list entry a quickfix jump into `bufnr` is heading for, if one
-- is under way (:cnext/:cc reading the file): the selection is in `bufnr`,
-- and either auto_show_check hasn't seen it yet, or the file is being read
-- for the first time (`fresh`: a jump to the entry already selected).
-- A jump to the selected entry into a buffer that was :bunload-ed but not
-- wiped is not a first read, so it isn't detected: its cursor stays on the
-- entry's old line. A buffer entered with `noautocmd edit` and reloaded before
-- any write is taken for a first read. A first plain `:edit +N` of the file
-- (goto_real_file's included) that lands on the selected entry's old line
-- counts as a jump to it, and moves to its relocated line.
local function pending_jump(bufnr, fresh)
  if not last_seen or not store.is_current_view() then return nil end
  local info = vim.fn.getqflist({ id = 0, idx = 0, items = 0 })
  local item = info.items[info.idx]
  if info.id ~= last_seen.id or (info.idx == last_seen.idx and not fresh)
      or not item or item.bufnr ~= bufnr then
    return nil
  end
  return item
end

-- Finish a quickfix jump whose file relocated its comments on read, once the
-- jump is done: refill the list (refilling during the jump would abort it
-- with E925), move the cursor from the entry's old line to its new one, and
-- show its float, as the jump alone would have
local function finish_jump(bufnr, item, seen)
  jump_finishing = false
  store.refresh()
  if vim.api.nvim_get_current_buf() ~= bufnr or not store.is_current_view() then return end
  local info = vim.fn.getqflist({ id = 0, idx = 0, items = 0 })
  local now = info.items[info.idx]
  if now and now.bufnr == bufnr and vim.fn.line('.') == item.lnum then
    pcall(vim.api.nvim_win_set_cursor, 0, { now.lnum, math.max(now.col - 1, 0) })
  end
  -- The navigation still counts, whichever of this and the jump's own
  -- scheduled check runs first
  last_seen = seen
  pcall(auto_show_check)
end

-- The file in `bufnr` was read or reloaded from disk (`event`): relocate its
-- comments from its content (never from a diff buffer, which holds an old
-- revision). Positions are kept in memory only; nothing is logged here
-- (anchors are written back only when the file is saved, see write_back).
local function relocate_buffer(bufnr, event)
  if vim.bo[bufnr].buftype ~= '' or utils.is_special_buffer(bufnr) then return end
  local fresh = event == 'BufReadPost' and not read_once[bufnr]
  if event == 'BufReadPost' then read_once[bufnr] = true end
  -- A change another Neovim logged refills the list after the read (see
  -- below), not during it
  local comments = store.all({ defer_view = true })
  local moved_here = track.relocate_buffer(bufnr, comments)
  local relocated = moved_here
  -- Relocation moves only this buffer's comments: redraw its signs now
  local name = utils.get_real_filepath(bufnr)
  if name ~= '' then draw_signs(bufnr, name, comments) end
  local item = pending_jump(bufnr, fresh)
  if item and not relocated and type(item.user_data) == 'table' then
    -- A change another Neovim logged, synced above, redraws the signs and so
    -- places this buffer's marks before relocation runs, which then reports
    -- no move: the jump still lands on a stale line if the selected entry's
    -- comment is elsewhere now
    for _, c in ipairs(comments) do
      if c.id == item.user_data.id then
        local p = store.pos(c)
        if p and p.lnum ~= item.lnum then relocated = true end
        break
      end
    end
  end
  if not relocated then return end
  if item then
    local seen = { id = last_seen.id, idx = last_seen.idx }
    jump_finishing = true
    vim.schedule(function() finish_jump(bufnr, item, seen) end)
  elseif moved_here then
    -- Never refill the list during a read: a quickfix jump may be reading
    -- the file, and refilling would abort it with E925 (the sync above
    -- defers its own refill likewise)
    vim.schedule(function() store.refresh() end)
  end
end

-- Whether a comment's pos names other lines, or another version of its
-- file, than its anchor
local function moved(c)
  local a, p = c.anchor or {}, c.pos
  return p.sha ~= a.sha or p.lnum ~= a.lnum or p.end_lnum ~= a.end_lnum
end

-- The file in `bufnr` was saved (as `file`, the written file): re-anchor its
-- current and shifted comments to the saved content, one update event per
-- comment whose anchor changed, so they reopen where they are now. Positions
-- are first recomputed by diffing each anchor's snapshot against the saved
-- content (an edit inside a range makes it outdated, which the tracking
-- extmark alone would not); outdated comments keep their anchor. A write of
-- part of the buffer, or to another file, is ignored: the anchors would name
-- content the file doesn't have.
local function write_back(bufnr, file)
  if not is_file_buffer(bufnr) or vim.bo[bufnr].modified then return end
  local name = vim.api.nvim_buf_get_name(bufnr)
  if vim.fn.fnamemodify(file, ':p') ~= vim.fn.fnamemodify(name, ':p') then return end
  -- A range write (':1,5w!') fires FileWritePost, not BufWritePost, so
  -- write_back never sees one

  -- A comment with a snapshot is relocated by diffing it against the saved
  -- content; one with none (from before anchors) can't be diffed, and its
  -- tracking extmark says where it is now
  -- Every refill of the list here waits until after the write: with
  -- 'autowrite', a quickfix jump (:cnext) writes the buffer mid-jump, and
  -- refilling then would abort the jump with E925
  local defer = { defer_view = true }
  local mine, snapshotted = {}, {}
  for _, c in ipairs(store.all(defer)) do
    if utils.files_match(c.filename, name) then
      table.insert(mine, c)
      if c.anchor and c.anchor.sha then table.insert(snapshotted, c) end
    end
  end
  local relocated = track.relocate_buffer(bufnr, snapshotted)

  local changes = {}
  -- The saved content, read and snapshotted once for every comment anchored
  local pre
  for _, c in ipairs(mine) do
    local p = store.pos(c)
    if p and p.state ~= 'outdated' and moved(c) then
      if not pre then
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        local sha, err = require('quickfix-review.snapshots').put(lines)
        if not sha then
          vim.notify('quickfix-review: snapshot not saved, comment anchors not updated: '
            .. tostring(err), vim.log.levels.WARN)
          break
        end
        pre = { lines = lines, sha = sha }
      end
      local a = context.anchor(p.lnum, p.end_lnum, bufnr, pre)
      if a.sha then table.insert(changes, { id = c.id, anchor = a }) end
    end
  end

  if #changes > 0 and (store.update(changes, defer) or 0) > 0 then
    -- Place the marks from the new anchors (a changed record has a new view,
    -- whose pos starts at its anchor), then redraw
    track.relocate_buffer(bufnr, store.all(defer))
    store.refresh(defer)
  elseif relocated then
    store.refresh(defer)
  end
end

-- prompt_on_file_change is deprecated: warn once per session
local prompt_deprecation_shown = false

-- Setup the plugin
function M.setup(opts)
  -- Clearing the group makes setup() safe to call more than once
  local augroup = vim.api.nvim_create_augroup('QuickfixReview', { clear = true })

  config.setup(opts)
  sync_cycle_state()
  utils.init_signs(config.options)
  setup_keymaps()
  require('quickfix-review.commands').create()

  -- Load the saved review now, so it's in place before any change is made
  store.set_on_change(refresh_all_signs)
  store.set_on_refill(refill_seen)
  refresh_all_signs(store.all())
  -- Unreferenced old snapshots are collected once a session, in the background
  store.schedule_startup_gc()

  -- The project follows the global cwd: after :cd, re-read the review from the
  -- new project's storage dir (the list view and signs refresh on change).
  -- 'autochdir' changes it too ('auto'); :lcd and :tcd leave the project alone.
  -- 'autochdir' fires inside a quickfix jump (:cnext into another dir), where
  -- refilling the list would abort the jump with E925: its refill waits
  -- until after the jump. After :cd it is immediate.
  vim.api.nvim_create_autocmd('DirChanged', {
    group = augroup,
    pattern = { 'global', 'auto' },
    callback = function(args) store.all({ defer_view = args.match == 'auto' }) end,
  })

  -- Cache the replayed log on exit, so the next start reads only its tail
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = augroup,
    callback = function() store.flush() end,
  })

  -- Auto-show the comment float when navigating the review's quickfix list.
  -- QuickFixCmdPost only fires for list-building commands (:make, :grep), not
  -- :cnext/:cc, so watch where the cursor lands instead: CursorMoved for a
  -- jump within the buffer, BufEnter for one into another buffer. The check
  -- is scheduled so it runs after the jump's own CursorMoved, which would
  -- otherwise close the float straight away.
  vim.api.nvim_create_autocmd({ 'CursorMoved', 'BufEnter' }, {
    group = augroup,
    callback = function()
      vim.schedule(function() pcall(auto_show_check) end)
    end,
  })

  -- Pick up changes another Neovim logged when coming back to this one or
  -- idling. Reading the review is a stat and a header read when nothing was
  -- logged; a change refreshes the list view and every buffer's signs
  -- (on_change).
  vim.api.nvim_create_autocmd({ 'FocusGained', 'CursorHold' }, {
    group = augroup,
    callback = function() store.all() end,
  })

  -- Read the review on entering any buffer, and draw signs for a file.
  -- Reading may pick up changes another Neovim logged (which redraws every
  -- buffer); otherwise only a buffer that changed since its signs were drawn
  -- is redrawn. A quickfix jump may be entering the buffer: the list is
  -- refilled after it (refilling during it would abort it with E925).
  vim.api.nvim_create_autocmd('BufEnter', {
    group = augroup,
    callback = function(args)
      local comments = store.all({ defer_view = true })
      local file = utils.get_real_filepath(args.buf)
      if file == '' then return end
      if drawn_at[args.buf] ~= vim.api.nvim_buf_get_changedtick(args.buf) then
        draw_signs(args.buf, file, comments)
      end
    end
  })

  -- Relocate a file's comments when it is read, and when it is reloaded
  -- after changing on disk
  vim.api.nvim_create_autocmd({ 'BufReadPost', 'FileChangedShellPost' }, {
    group = augroup,
    callback = function(args) relocate_buffer(args.buf, args.event) end,
  })
  -- Redraw signs after a filter (':%!cmd'), which fires no TextChanged here.
  -- The filtered buffer is the current one (<abuf> isn't documented to be it).
  vim.api.nvim_create_autocmd('ShellFilterPost', {
    group = augroup,
    callback = function()
      local buf = vim.api.nvim_get_current_buf()
      local file = utils.get_real_filepath(buf)
      if file ~= '' then draw_signs(buf, file, store.all()) end
    end,
  })
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) then read_once[b] = true end
  end
  -- A new file is not read, but its buffer is there: a later :e! is a reload
  vim.api.nvim_create_autocmd('BufNewFile', {
    group = augroup,
    callback = function(args) read_once[args.buf] = true end,
  })
  -- Write the anchors of a saved file's comments back to the log. Only on
  -- a write: unsaved edits never change a stored anchor.
  vim.api.nvim_create_autocmd('BufWritePost', {
    group = augroup,
    callback = function(args)
      -- The buffer matches the file now (:enew then :saveas, or a new
      -- file): a later :e! is a reload, not a first read
      read_once[args.buf] = true
      write_back(args.buf, args.file)
    end,
  })
  -- A colorscheme clears every highlight group: define the plugin's again
  vim.api.nvim_create_autocmd('ColorScheme', {
    group = augroup,
    callback = function() utils.init_highlights() end,
  })
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = augroup,
    callback = function(args)
      drawn_at[args.buf] = nil
      read_once[args.buf] = nil
      utils.forget_buffer(args.buf)
    end,
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
