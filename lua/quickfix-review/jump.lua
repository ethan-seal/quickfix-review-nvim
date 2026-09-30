-- Quickfix jump detection and the comment float's lifetime, as one state
-- machine. init.lua's autocmds and commands report what happened through
-- M.on_event(name, args); they never read or write the state themselves.
--
-- States (M.state()):
--   idle       no jump of ours under way
--   own_jump   jump_comment (]r/[r) is running its own :edit, which is
--              never a quickfix jump. Entered from any state and left back
--              to that state (`resume`), not to idle: a finish still
--              scheduled when ]r runs must survive it.
--   finishing  a quickfix jump read a file whose comments relocated; its
--              finish (refill, cursor move, float) is scheduled but hasn't
--              run. Refilling during the jump would abort it with E925, so
--              everything that would refill waits for it.
--   holding    finish is running its float check right after moving the
--              cursor itself: a float opened now holds (see float data).
--
-- Data (not states):
--   last_seen  the review list entry last seen by the cursor check:
--              { id =, idx = }. Only a change of entry opens the float.
--   float      the open comment float: { win, autocmd, hold = { win, pos }? }.
--              `hold` outlives the holding state: it is where the float
--              opened after finish moved the cursor, and the one CursorMoved
--              that move causes, arriving there, doesn't close the float.
--   seen       finish's snapshot of last_seen, taken at `relocated` and
--              carried by the scheduled finish itself (a second relocation
--              schedules a second finish with its own snapshot).
--   finish_gen the latest relocation's number, carried by the finish it
--              scheduled: only that finish runs, so a second relocation
--              while finishing keeps the state finishing until its own
--              finish, not the first one, is done.
--
-- Transitions (event: from -> to; test covering it, in test_qf_window.lua
-- unless named):
--   own_edit_begin  S -> own_jump, resume = S.
--                   'jump_comment into a shifted file holding the selected
--                   entry' (the ]r regression); 'own_jump bracket restores
--                   the prior state'
--   own_edit_end    own_jump -> resume. Always runs, even if :edit fails.
--                   'own_jump bracket restores the prior state (finishing)'
--   pending query   any -> same; the entry a jump into the buffer is heading
--                   for, if any, in own_jump too (relocate_buffer skips it in
--                   own_jump itself: ]r is never a quickfix jump, but a
--                   DirChanged during its :edit still defers, see in_jump).
--                   'in_jump while pending'; 'in_jump while pending, inside
--                   the own_jump bracket'
--   relocated       idle|finishing -> finishing. Schedules finish (the
--                   E925 deferral: the jump must return to the main loop
--                   first), as finish_gen's latest. A second relocation while
--                   finishing supersedes the first finish: the state stays
--                   finishing until the second one runs.
--                   'cnext into a file whose comment relocates on read shows
--                   it'; 'cursor check while finishing is ignored'; 'second
--                   relocation while finishing stays finishing'
--   cursor          (the CursorMoved/BufEnter check, scheduled by init.lua so
--                   it runs after the jump's own CursorMoved)
--                   finishing (or own_jump resuming finishing) -> same,
--                   ignored: 'cursor check while finishing is ignored'
--                   idle|holding|own_jump -> same; records last_seen, and
--                   opens the float when the entry changed and the cursor is
--                   on it: 'cc 1 then cnext shows exactly one float ...',
--                   'moving the cursor onto the current entry opens no float'
--   finish          superseded (not finish_gen's latest): no-op, any -> same.
--                   'second relocation while finishing stays finishing'
--                   latest: finishing -> idle, refills the list and moves the
--                   cursor to the entry's relocated line; restores last_seen =
--                   seen; then -> holding if the cursor moved, runs the cursor
--                   check, -> idle. It must leave finishing before the check,
--                   or the check is ignored. 'cnext into a file whose
--                   comment relocates on read shows it' (y4k3)
--   seen            any -> same; last_seen = the list's selection (the list
--                   appearing is not navigation). 'moving onto the current
--                   entry right after showing the list opens no float'
--   refill          any -> same; last_seen.idx follows the selection only if
--                   it was at the refill's old idx (an unchecked navigation
--                   still counts). 'adding or deleting another comment keeps
--                   the same comment selected'
--   float_opened    any -> same; records the float, with a hold if holding,
--                   and one close handler (augroup QuickfixReviewFloat, over
--                   CursorMoved and BufLeave; test_setup.lua counts them).
--                   'cc 1 then cnext shows exactly one float with comment 2';
--                   'cnext into a file whose comment relocates on read shows
--                   it'; test_setup.lua's 'view_comment float close autocmd
--                   is grouped and removed on close'
--   float CursorMoved at hold  clears the hold, float stays: 'cnext into a
--                   file whose comment relocates on read shows it' (y4k3)
--   float CursorMoved elsewhere, or BufLeave  closes the float:
--                   'held float closes on a CursorMoved elsewhere',
--                   'held float closes on BufLeave'
--   in_jump query   finishing (or resuming it), or a pending jump into the
--                   current buffer: DirChanged defers its refill.
--                   'in_jump while finishing', 'in_jump while pending', the
--                   E925 DirChanged tests, and (inside ]r's :edit) 'jump_comment
--                   with a :cd from BufEnter and a stale selection defers the
--                   refill'
local M = {}

local config = require('quickfix-review.config')
local store = require('quickfix-review.store')

local state = 'idle'
-- The state own_jump returns to
local resume = 'idle'
local last_seen
local float
-- The latest relocation's number: only the finish it scheduled runs
local finish_gen = 0
-- Shows the comment float for the cursor line (edit.view_comment, which
-- registers itself when it loads: edit requires this module)
local view_comment_fn = nil

-- Set the function the cursor check opens the float with (called by
-- edit.lua when it loads)
function M.set_view_comment(fn)
  view_comment_fn = fn
end

function M.state()
  return state
end

-- Finishing, whether or not ]r's :edit is running meanwhile
local function is_finishing()
  return state == 'finishing' or (state == 'own_jump' and resume == 'finishing')
end

-- Close the comment float (if still open) and remove its close handler
function M.close_float()
  if not float then return end
  pcall(vim.api.nvim_win_close, float.win, true)
  pcall(vim.api.nvim_del_autocmd, float.autocmd)
  float = nil
end

-- The review list entry a quickfix jump into `bufnr` is heading for, if one
-- is under way (:cnext/:cc reading the file): the selection is in `bufnr`,
-- and either the cursor check hasn't seen it yet, or the file is being read
-- for the first time (`fresh`: a jump to the entry already selected).
-- Not guarded against own_jump: relocate_buffer, the caller that must not
-- take jump_comment's own :edit for a jump, checks the state itself.
-- A jump to the selected entry into a buffer that was :bunload-ed but not
-- wiped is not a first read, so it isn't detected: its cursor stays on the
-- entry's old line. A buffer entered with `noautocmd edit` and reloaded before
-- any write is taken for a first read. A first plain `:edit +N` of the file
-- (goto_real_file's included) that lands on the selected entry's old line
-- counts as a jump to it, and moves to its relocated line.
function M.pending(bufnr, fresh)
  if not last_seen or not store.is_current_view() then return nil end
  local info = vim.fn.getqflist({ id = 0, idx = 0, items = 0 })
  local item = info.items[info.idx]
  if info.id ~= last_seen.id or (info.idx == last_seen.idx and not fresh)
      or not item or item.bufnr ~= bufnr then
    return nil
  end
  return item
end

-- Whether a quickfix jump into `bufnr` is under way or finishing: a refill
-- now would abort it with E925
function M.in_jump(bufnr)
  return is_finishing() or M.pending(bufnr, false) ~= nil
end

-- Show the float if the cursor has just landed on a new entry of the review
-- quickfix list (:cnext, :cprev, :cc, :cfirst, :clast). Runs scheduled, after
-- the navigation's events, so everything is re-checked here.
local function cursor_check()
  if is_finishing() then return end
  if not store.is_current_view() then return end
  if vim.fn.win_gettype() ~= '' or vim.bo.buftype == 'quickfix' then return end
  local info = vim.fn.getqflist({ id = 0, idx = 0 })
  local changed = not last_seen or last_seen.id ~= info.id or last_seen.idx ~= info.idx
  -- Track the selection even with auto_show off, so a later reload of the
  -- selected file isn't taken for a pending jump (see M.pending)
  last_seen = { id = info.id, idx = info.idx }
  if not config.options.auto_show then return end
  if not changed then return end
  local item = (vim.fn.getqflist({ id = 0, items = 0 }).items or {})[info.idx]
  if not item or item.bufnr ~= vim.api.nvim_get_current_buf()
    or item.lnum ~= vim.fn.line('.') then
    return
  end
  if view_comment_fn then view_comment_fn() end
end

-- Finish a quickfix jump whose file relocated its comments on read, once the
-- jump is done: refill the list (refilling during the jump would abort it
-- with E925), move the cursor from the entry's old line to its new one, and
-- show its float, as the jump alone would have. `gen` is the relocation
-- that scheduled it: a later relocation supersedes it, and it does nothing.
local function finish(bufnr, item, seen, gen)
  if gen ~= finish_gen then return end
  if state == 'own_jump' then resume = 'idle' else state = 'idle' end
  store.refresh()
  if vim.api.nvim_get_current_buf() ~= bufnr or not store.is_current_view() then return end
  local info = vim.fn.getqflist({ id = 0, idx = 0, items = 0 })
  local now = info.items[info.idx]
  local moved_cursor = false
  if now and now.bufnr == bufnr and vim.fn.line('.') == item.lnum then
    local before = vim.api.nvim_win_get_cursor(0)
    pcall(vim.api.nvim_win_set_cursor, 0, { now.lnum, math.max(now.col - 1, 0) })
    local after = vim.api.nvim_win_get_cursor(0)
    moved_cursor = before[1] ~= after[1] or before[2] ~= after[2]
  end
  -- The navigation still counts, whichever of this and the jump's own
  -- scheduled check runs first
  last_seen = seen
  -- The float opened here must survive the CursorMoved the move above causes
  local outer = state
  if moved_cursor then state = 'holding' end
  pcall(cursor_check)
  state = outer
end

-- The float's close handler: see `float` and the float transitions above
local function on_float_event(args)
  local hold = float and float.hold
  if hold and args.event == 'CursorMoved' then
    float.hold = nil
    local pos = vim.api.nvim_win_get_cursor(0)
    if vim.api.nvim_get_current_win() == hold.win
        and pos[1] == hold.pos[1] and pos[2] == hold.pos[2] then
      return
    end
  end
  M.close_float()
end

local handlers = {}

-- args: the list's { id =, idx = }
function handlers.seen(args)
  last_seen = { id = args.id, idx = args.idx }
end

-- args: { id =, before =, after = }
function handlers.refill(args)
  if last_seen and last_seen.id == args.id and last_seen.idx == args.before then
    last_seen.idx = args.after
  end
end

function handlers.cursor()
  cursor_check()
end

function handlers.own_edit_begin()
  resume = state
  state = 'own_jump'
end

function handlers.own_edit_end()
  state = resume
  resume = 'idle'
end

-- args: { bufnr =, item = } (item from M.pending)
function handlers.relocated(args)
  local seen = { id = last_seen.id, idx = last_seen.idx }
  state = 'finishing'
  finish_gen = finish_gen + 1
  local gen = finish_gen
  vim.schedule(function() finish(args.bufnr, args.item, seen, gen) end)
end

-- args: { win = } (the float view_comment just opened; it closed any old
-- one first). Closing the window wipes its buffer (bufhidden=wipe).
function handlers.float_opened(args)
  local group = vim.api.nvim_create_augroup('QuickfixReviewFloat', { clear = false })
  float = { win = args.win }
  if state == 'holding' then
    float.hold = {
      win = vim.api.nvim_get_current_win(), pos = vim.api.nvim_win_get_cursor(0),
    }
  end
  float.autocmd = vim.api.nvim_create_autocmd({ 'CursorMoved', 'BufLeave' }, {
    group = group,
    callback = on_float_event,
  })
end

function M.on_event(name, args)
  local handler = handlers[name]
  if not handler then error('quickfix-review.jump: unknown event ' .. tostring(name)) end
  handler(args)
end

-- store.set_on_refill's callback
function M.on_refill(id, before, after)
  M.on_event('refill', { id = id, before = before, after = after })
end

return M
