-- Moving between comments and accepting where outdated ones are now:
-- jump_comment and reanchor.
local M = {}

local utils = require('quickfix-review.utils')
local store = require('quickfix-review.store')
local context = require('quickfix-review.context')
local track = require('quickfix-review.track')
local jump = require('quickfix-review.jump')
local edit = require('quickfix-review.edit')

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
    -- The plugin's own navigation is never a quickfix jump: relocate_buffer
    -- must not take this read for one heading for the selected entry
    jump.on_event('own_edit_begin')
    local ok, err = pcall(vim.cmd, 'edit ' .. vim.fn.fnameescape(target.filename))
    jump.on_event('own_edit_end')
    if not ok then error(err, 0) end
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
      edit.view_comment()
    end
  end)
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
  -- One location for the snapshot and the update events naming it
  local n = store.with_location(function()
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
      return nil
    end
    return store.update(changes)
  end)
  if not n then return end
  -- The tracking extmark still holds the outdated position (or is invalid,
  -- if the whole range was deleted): place it again from the new anchor
  for _, ch in ipairs(changes) do track.forget(ch.id) end
  track.relocate_buffer(bufnr, store.all())
  store.refresh()
  vim.notify(string.format('quickfix-review: re-anchored %d comment%s', n, n == 1 and '' or 's'),
    vim.log.levels.INFO)
end

return M
