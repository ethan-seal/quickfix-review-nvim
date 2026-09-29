-- Code Review System using Signs, with the quickfix list as a view
-- Supports regular files and diff buffers (diffview, fugitive, codediff)
local M = {}

local config = require('quickfix-review.config')
local utils = require('quickfix-review.utils')
local store = require('quickfix-review.store')
local export = require('quickfix-review.export')
local track = require('quickfix-review.track')
local jump = require('quickfix-review.jump')
local signs = require('quickfix-review.signs')
local edit = require('quickfix-review.edit')
local history_view = require('quickfix-review.history_view')
local buffer_sync = require('quickfix-review.buffer_sync')
local navigate = require('quickfix-review.navigate')
local notify = require('quickfix-review.notify')

-- The comment flows (edit.lua), the history view (history_view.lua) and
-- navigation (navigate.lua).
-- Assigned at load, before setup(): the keymaps bind these by value.
M.cycle_next_comment_type = edit.cycle_next_comment_type
M.cycle_previous_comment_type = edit.cycle_previous_comment_type
M.add_comment_cycle = edit.add_comment_cycle
M.add_comment = edit.add_comment
M.add_comment_visual = edit.add_comment_visual
M.view_comment = edit.view_comment
M.delete_comment = edit.delete_comment
M.delete_comment_visual = edit.delete_comment_visual
M.delete_comment_from_qf = edit.delete_comment_from_qf
M.edit_comment = edit.edit_comment
M.history_rows = history_view.history_rows
M.history = history_view.history
M.jump_comment = navigate.jump_comment
M.reanchor = navigate.reanchor

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

-- All review comments, in creation order: copies, each with its current
-- `pos` (see track.pos), so no caller holds shared position state
function M.comments()
  local out = {}
  for i, c in ipairs(store.all()) do
    local copy = {}
    for k, v in pairs(c) do copy[k] = v end
    -- Its own anchor: the live one is what track.pos relocates from
    copy.anchor = c.anchor and vim.deepcopy(c.anchor)
    copy.pos = store.pos(c)
    out[i] = copy
  end
  return out
end

-- Save the review. Every change is already appended to the review's journal as
-- it is made; this only writes a checkpoint (a cache of the replayed journal).
function M.save_review()
  local ok, message = store.save()
  if ok then
    print(message)
  else
    vim.notify('quickfix-review: ' .. message, vim.log.levels.ERROR)
  end
end

-- Show the review as the current quickfix list, its selected entry seen:
-- the list appearing is not navigation
local function show_seen()
  store.show()
  if store.is_current_view() then
    jump.on_event('seen', vim.fn.getqflist({ id = 0, idx = 0 }))
  end
end

-- Replay the review's journal (ignoring checkpoints) and show it in the quickfix list
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

-- Setup keymaps based on configuration. Every map's desc ends in the
-- commands.lua marker, so a re-run can first delete the maps an earlier run
-- made (a key now disabled, a type now dropped) without touching the user's
-- own maps. Read back from Neovim, not tracked here: the module may be
-- reloaded between setup() calls.
local function setup_keymaps()
  local keymaps = config.options.keymaps
  local marker = require('quickfix-review.commands').MARKER

  for _, mode in ipairs({ 'n', 'v' }) do
    for _, map in ipairs(vim.api.nvim_get_keymap(mode)) do
      if type(map.desc) == 'string' and vim.endswith(map.desc, marker) then
        pcall(vim.keymap.del, mode, map.lhs)
      end
    end
  end

  local function map(mode, lhs, rhs, desc)
    vim.keymap.set(mode, lhs, rhs, { desc = desc .. marker })
  end

  -- Dynamically set up keymaps for each comment type
  for type_name, _ in pairs(config.options.comment_types) do
    local keymap_key = 'add_' .. type_name
    local keymap = keymaps[keymap_key]
    if keymap then
      local type_upper = type_name:upper()
      map('n', keymap, function() M.add_comment(type_upper) end, 'Add ' .. type_upper .. ' comment')
      map('v', keymap, function() M.add_comment_visual(type_upper) end,
        'Add ' .. type_upper .. ' comment for selection')
    end
  end

  -- Add keymaps for comment type cycling
  if keymaps.add_comment_cycle then
    map('n', keymaps.add_comment_cycle, M.add_comment_cycle, 'Add comment of the current cycle type')
    map('v', keymaps.add_comment_cycle, function() M.add_comment_visual(edit.current_cycle_type()) end,
      'Add comment of the current cycle type for selection')
  end

  if keymaps.cycle_next then
    map('n', keymaps.cycle_next, M.cycle_next_comment_type, 'Cycle to next comment type')
  end

  if keymaps.cycle_previous then
    map('n', keymaps.cycle_previous, M.cycle_previous_comment_type, 'Cycle to previous comment type')
  end

  -- Add keymaps for comment deletion
  if keymaps.delete_comment then
    map('n', keymaps.delete_comment, function() M.delete_comment() end, 'Delete comment at current line')
    map('v', keymaps.delete_comment, M.delete_comment_visual, 'Delete comments in selection')
  end

  if keymaps.export then
    map('n', keymaps.export, M.export_review, 'Export review to markdown')
  end
  if keymaps.clear then
    map('n', keymaps.clear, function() M.clear_review({ confirm = true }) end, 'Clear all review comments')
  end
  if keymaps.summary then
    map('n', keymaps.summary, M.summary, 'Show review summary')
  end

  if keymaps.save then
    map('n', keymaps.save, M.save_review, 'Save review to disk')
  end
  if keymaps.load then
    map('n', keymaps.load, M.load_review, 'Load review from disk')
  end

  if keymaps.open_list then
    map('n', keymaps.open_list, M.open_list, 'Open review comments list')
  end
  if keymaps.next_comment then
    map('n', keymaps.next_comment, function() M.jump_comment(1) end, 'Next review comment')
  end
  if keymaps.prev_comment then
    map('n', keymaps.prev_comment, function() M.jump_comment(-1) end, 'Previous review comment')
  end

  if keymaps.goto_real_file then
    map('n', keymaps.goto_real_file, M.goto_real_file, 'Go to real file from diff')
  end

  if keymaps.view then
    map('n', keymaps.view, M.view_comment, 'View comment on current line')
  end
  if keymaps.edit then
    map('n', keymaps.edit, M.edit_comment, 'Edit review comment')
  end

  if keymaps.reanchor then
    map('n', keymaps.reanchor, M.reanchor, 'Re-anchor the outdated comment on current line')
  end
end

-- Marks the maps this plugin made, so only those are removed again
local QF_DELETE_DESC = 'Delete comment from quickfix list'

-- Whether buf is the quickfix (not location list) buffer showing the review
local function shows_review(buf)
  return vim.fn.getqflist({ qfbufnr = 0 }).qfbufnr == buf and store.is_current_view()
end

-- Map the delete keys and set display options when the quickfix buffer shows
-- the review; otherwise leave the maps removed and the window options alone.
local function configure_qf_buffer(buf)
  -- Remove the previous maps first, so a delete_comment key changed by a
  -- later setup() does not linger. Only the plugin's own maps: another
  -- plugin's qf maps stay. Delete by the reported lhs, which has <leader>
  -- already expanded.
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
    if map.desc == QF_DELETE_DESC then
      pcall(vim.keymap.del, 'n', map.lhs, { buffer = buf })
    end
  end
  if not shows_review(buf) then return end

  -- Better display of multiline comments
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    vim.wo[win][0].wrap = false
    vim.wo[win][0].number = true
    vim.wo[win][0].relativenumber = false
  end

  -- dd always; keymaps.delete_comment too (false leaves only dd)
  local keys = { 'dd' }
  local configured = config.options.keymaps.delete_comment
  if configured and configured ~= 'dd' then table.insert(keys, configured) end
  for _, lhs in ipairs(keys) do
    vim.keymap.set('n', lhs, M.delete_comment_from_qf, {
      buffer = buf,
      desc = QF_DELETE_DESC,
    })
  end
end

-- Setup the plugin
function M.setup(opts)
  -- Options first: they are validated there, so a bad option cannot throw
  -- after the old autocmds are gone and leave the plugin half set up
  config.setup(opts)

  -- Clearing the group makes setup() safe to call more than once
  local augroup = vim.api.nvim_create_augroup('QuickfixReview', { clear = true })
  edit.sync_cycle_state()
  utils.init_signs(config.options)
  setup_keymaps()
  require('quickfix-review.commands').create()

  -- Load the saved review now, so it's in place before any change is made
  store.set_on_change(signs.refresh_all)
  store.set_on_refill(jump.on_refill)
  signs.refresh_all(store.all())
  -- Unreferenced old snapshots are collected once a session, in the background
  store.schedule_startup_gc()

  -- The project follows the global cwd: after :cd, re-read the review from the
  -- new project's storage dir (the list view and signs refresh on change).
  -- 'autochdir' changes it too ('auto'); :lcd and :tcd leave the project alone.
  -- 'autochdir' fires inside a quickfix jump (:cnext into another dir), where
  -- refilling the list would abort the jump with E925: its refill waits
  -- until after the jump. So does the refill after a :cd a plugin runs from
  -- the jump's BufEnter or BufReadPost (vim-rooter and the like), which
  -- fires 'global'. After any other :cd it is immediate.
  vim.api.nvim_create_autocmd('DirChanged', {
    group = augroup,
    pattern = { 'global', 'auto' },
    callback = function(args)
      local in_jump = jump.in_jump(vim.api.nvim_get_current_buf())
      store.all({ defer_view = args.match == 'auto' or in_jump })
    end,
  })

  -- Checkpoint the journal on exit when events were read past the newest
  -- checkpoint, so the next start reads only the tail past it
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
      vim.schedule(function() pcall(jump.on_event, 'cursor') end)
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
      local file = utils.get_real_filepath(args.buf)
      if file == '' then
        -- Still sync: another Neovim's change is picked up on any BufEnter
        store.all({ defer_view = true })
        return
      end
      signs.on_buf_enter(args.buf, file, { defer_view = true })
    end
  })

  -- Redraw a changed buffer's signs once edits pause. Deleting a commented
  -- line (dd) slides its sign onto the next line, while the comment is now
  -- outdated at the line before the gap: until redrawn, the sign and the
  -- view disagree, and the sign's line says there is no comment on it.
  vim.api.nvim_create_autocmd('TextChanged', {
    group = augroup,
    callback = function(args) signs.schedule_redraw(args.buf) end,
  })

  -- Relocate a file's comments when it is read, and when it is reloaded
  -- after changing on disk
  vim.api.nvim_create_autocmd({ 'BufReadPost', 'FileChangedShellPost' }, {
    group = augroup,
    callback = function(args) buffer_sync.relocate_buffer(args.buf, args.event) end,
  })
  -- Redraw signs after a filter (':%!cmd'), which fires no TextChanged here.
  -- The filtered buffer is the current one (<abuf> isn't documented to be it).
  vim.api.nvim_create_autocmd('ShellFilterPost', {
    group = augroup,
    callback = function()
      local buf = vim.api.nvim_get_current_buf()
      local file = utils.get_real_filepath(buf)
      if file ~= '' then signs.draw_file(buf, file) end
    end,
  })
  buffer_sync.mark_loaded()
  -- A new file is not read, but its buffer is there: a later :e! is a reload
  vim.api.nvim_create_autocmd('BufNewFile', {
    group = augroup,
    callback = function(args) buffer_sync.mark_read(args.buf) end,
  })
  -- Write the anchors of a saved file's comments back to the log. Only on
  -- a write: unsaved edits never change a stored anchor.
  vim.api.nvim_create_autocmd('BufWritePost', {
    group = augroup,
    callback = function(args)
      -- The buffer matches the file now (:enew then :saveas, or a new
      -- file): a later :e! is a reload, not a first read
      buffer_sync.mark_read(args.buf)
      buffer_sync.write_back(args.buf, args.file)
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
      signs.forget(args.buf)
      buffer_sync.forget(args.buf)
      utils.forget_buffer(args.buf)
      track.forget_buffer(args.buf)
    end,
  })

  if config.options.prompt_on_file_change then
    notify.once('prompt_on_file_change', 'prompt_on_file_change is deprecated and does nothing:'
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
