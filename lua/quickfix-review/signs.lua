-- Sign and extmark drawing for the review's comments, and the caches that
-- decide when a buffer needs redrawing. The drawing itself is
-- utils.refresh_buffer_signs, always looked up on utils at call time.
local M = {}

local utils = require('quickfix-review.utils')
local store = require('quickfix-review.store')
local track = require('quickfix-review.track')

-- b:changedtick of each buffer when its signs were last drawn, so BufEnter
-- only redraws a buffer that changed since
local drawn_at = {}

-- The pending TextChanged redraw of each buffer: a generation number, so
-- only the last of a burst of changes redraws (see schedule_redraw)
local redraw_gen = {}
local REDRAW_DELAY = 150

-- Draw the signs of `comments` in `bufnr`, which shows file `name`. The
-- positions of a real file's comments are read once for the whole file; a
-- diff buffer places each comment itself (see utils.range_in).
function M.draw(bufnr, name, comments)
  local positions = not utils.is_special_buffer(bufnr) and track.positions(name) or nil
  utils.refresh_buffer_signs(bufnr, name, comments, positions)
  drawn_at[bufnr] = vim.api.nvim_buf_get_changedtick(bufnr)
end

-- Redraw signs in every loaded buffer from the current comments, and drop
-- the tracking extmarks of comments that are gone
-- (`comments` is the live list, store.all())
function M.refresh_all(comments)
  track.prune(comments)
  -- Each buffer is given only the comments on its file (the store's path
  -- index, by path_key as files_match compares), so the pass is not
  -- comments x buffers
  track.batch(function()
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(bufnr) then
        local name = utils.get_real_filepath(bufnr)
        if name ~= '' then
          M.draw(bufnr, name, store.in_file(utils.path_key(name)))
        end
      end
    end
  end)
end

-- Draw the signs of the live comments on `name` in `bufnr`. Syncs first.
-- opts: as for store.all
function M.draw_file(bufnr, name, opts)
  store.all(opts)
  M.draw(bufnr, name, store.in_file(utils.path_key(name)))
end

-- Buffer `buf` (showing `file`) was entered: sync, then redraw its signs
-- only if it changed since they were last drawn (opts: as for store.all)
function M.on_buf_enter(buf, file, opts)
  store.all(opts)
  if drawn_at[buf] ~= vim.api.nvim_buf_get_changedtick(buf) then
    M.draw(buf, file, store.in_file(utils.path_key(file)))
  end
end

-- Buffer `buf` changed: redraw its signs once edits pause
function M.schedule_redraw(buf)
  local gen = (redraw_gen[buf] or 0) + 1
  redraw_gen[buf] = gen
  vim.defer_fn(function()
    if redraw_gen[buf] ~= gen or not vim.api.nvim_buf_is_loaded(buf) then return end
    redraw_gen[buf] = nil
    if drawn_at[buf] == vim.api.nvim_buf_get_changedtick(buf) then return end
    local file = utils.get_real_filepath(buf)
    if file ~= '' then M.draw_file(buf, file) end
  end, REDRAW_DELAY)
end

-- Buffer `buf` was wiped out: drop what is cached for it
function M.forget(buf)
  drawn_at[buf] = nil
  redraw_gen[buf] = nil
end

return M
