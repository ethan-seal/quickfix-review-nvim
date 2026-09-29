-- Keeping comments in step with a file's buffer: relocating them when the
-- file is read or reloaded, and writing their anchors back when it is saved.
-- The only owner of read_once.
local M = {}

local utils = require('quickfix-review.utils')
local store = require('quickfix-review.store')
local snapshots = require('quickfix-review.snapshots')
local context = require('quickfix-review.context')
local track = require('quickfix-review.track')
local jump = require('quickfix-review.jump')
local signs = require('quickfix-review.signs')

-- Buffers read from disk since they were created: a BufReadPost for a buffer
-- not in here is its first read (a jump into an unloaded file), not a reload
-- (:e!, :checktime). Cleared on wipeout only: a reload unloads the buffer
-- first, so clearing on BufUnload would make every reload a first read.
-- setup() seeds it with the buffers already loaded when it runs, whose read
-- the autocmd never saw.
local read_once = {}

-- Whether `bufnr` holds a real file (not a diff buffer or a special one)
local function is_file_buffer(bufnr)
  return vim.bo[bufnr].buftype == '' and not utils.is_special_buffer(bufnr)
    and vim.api.nvim_buf_get_name(bufnr) ~= ''
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
  if name ~= '' then signs.draw(bufnr, name, store.in_file(utils.path_key(name))) end
  -- The selected entry a quickfix jump reading this file is heading for
  -- (never jump_comment's own :edit)
  local item = jump.pending(bufnr, fresh)
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
    -- Refill and move to the relocated line once the jump is done
    jump.on_event('relocated', { bufnr = bufnr, item = item })
  elseif moved_here then
    -- Never refill the list during a read: a quickfix jump may be reading
    -- the file, and refilling would abort it with E925 (the sync above
    -- defers its own refill likewise)
    vim.schedule(function() store.refresh() end)
  end
end

-- Whether `p`, comment `c`'s pos, names other lines, or another version
-- of its file, than its anchor
local function moved(c, p)
  local a = c.anchor or {}
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
  local relocated
  -- One location for the snapshot and the update events naming it
  local updated = store.with_location(function()
    local mine, snapshotted = {}, {}
    for _, c in ipairs(store.all(defer)) do
      if utils.files_match(c.filename, name) then
        table.insert(mine, c)
        if c.anchor and c.anchor.sha then table.insert(snapshotted, c) end
      end
    end
    relocated = track.relocate_buffer(bufnr, snapshotted)

    local changes = {}
    -- The saved content, read and snapshotted once for every comment anchored
    local pre
    for _, c in ipairs(mine) do
      local p = store.pos(c)
      if p and p.state ~= 'outdated' and moved(c, p) then
        if not pre then
          local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
          local sha, err = snapshots.put(lines)
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

    return #changes > 0 and (store.update(changes, defer) or 0) > 0
  end)

  if updated then
    -- Place the marks from the new anchors (a changed anchor is relocated
    -- afresh, see track.relocate_buffer), then redraw
    track.relocate_buffer(bufnr, store.all(defer))
    store.refresh(defer)
  elseif relocated then
    store.refresh(defer)
  end
end

-- `bufnr` matches its file on disk: a later :e! is a reload, not a first read
function M.mark_read(bufnr)
  read_once[bufnr] = true
end

-- Every loaded buffer was read before setup() ran, unseen by the autocmd
function M.mark_loaded()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) then read_once[b] = true end
  end
end

-- `bufnr` was wiped out
function M.forget(bufnr)
  read_once[bufnr] = nil
end

M.relocate_buffer = relocate_buffer
M.write_back = write_back

return M
