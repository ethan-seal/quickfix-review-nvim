-- The comments as shown: the normalized view of the replayed log's records
-- (view_of), the list of them (set by sync, read by everything else), and
-- the quickfix list that displays them. The quickfix list is only a view
-- derived from the comments, which show() publishes.
local M = {}

local record = require('quickfix-review.store.record')

local QF_TITLE = 'Code Review Comments'

-- The live comments, normalized: the view of the replayed log's comments
local comments = {}
-- Id of the quickfix list showing the review, if one has been published
local qf_id = nil
local on_change = function(_) end
-- Called after every refill of the list view: (qf_id, idx before, idx after)
local on_refill = function(_, _, _) end

local function view_exists()
  return qf_id ~= nil and vim.fn.getqflist({ id = qf_id }).id == qf_id
end

-- The quickfix row for a comment: its headline, with " | Response: reply"
-- when it has one. The row carries only the comment's id in user_data; the
-- context stays in the store.
local function view_item(c)
  -- First lines only: a newline would break the quickfix row
  local text = record.headline(c):match('^[^\n]*')
  if c.response then
    text = text .. ' | Response: ' .. c.response:match('^[^\n]*')
  end
  if record.is_outdated(c) then text = '[outdated] ' .. text end
  local lnum, end_lnum = record.range(c)
  return {
    filename = c.filename,
    lnum = lnum,
    end_lnum = end_lnum,
    col = 1,
    text = text,
    type = c.kind:sub(1, 1):upper(),
    user_data = { id = c.id },
  }
end

-- In a track batch, so each comment's three record.range/is_outdated lookups
-- compute its pos once and buffers are looked up in one map
local function view_items()
  -- Required here: track requires snapshots, which requires the store
  return require('quickfix-review.track').batch(function()
    local items = {}
    for i, c in ipairs(comments) do
      items[i] = view_item(c)
    end
    return items
  end)
end

-- Refill the review's quickfix list, keeping its selected entry: the same
-- comment if it is still listed, else the same position (clamped). A refill
-- alone would reset the selection to the first entry.
local function refresh_view()
  if not view_exists() then return end
  local before = vim.fn.getqflist({ id = qf_id, idx = 0, items = 0 })
  local selected = before.items[before.idx]
  local selected_id = selected and type(selected.user_data) == 'table' and selected.user_data.id
  local items = view_items()
  local idx = math.min(before.idx, #items)
  for i, item in ipairs(items) do
    if selected_id and item.user_data.id == selected_id then
      idx = i
      break
    end
  end
  vim.fn.setqflist({}, 'r', { id = qf_id, items = items, title = QF_TITLE })
  if idx > 1 then vim.fn.setqflist({}, 'a', { id = qf_id, idx = idx }) end
  on_refill(qf_id, before.idx, vim.fn.getqflist({ id = qf_id, idx = 0 }).idx)
end

-- refresh_view, once, after the current event: for a sync inside a buffer
-- read or enter, where a quickfix jump may be running and a refill would
-- abort it with E925. Coalesced: one pending refill at a time.
local view_scheduled = false
local function refresh_view_later()
  if view_scheduled then return end
  view_scheduled = true
  vim.schedule(function()
    view_scheduled = false
    refresh_view()
  end)
end

-- The normalized comment for each logged record, so a record is normalized
-- once and an unchanged comment keeps its identity across changes. false for
-- a record that can't be shown (no file or no valid line number).
local views = setmetatable({}, { __mode = 'k' })

function M.view_of(r)
  local c = views[r]
  if c == nil then
    c = record.normalize(r) or false
    if c then
      -- Derived, never logged: a comment from before anchors is anchored at
      -- its line with no snapshot (the fallback search handles it), and
      -- its display position starts at its anchor.
      c.anchor = c.anchor or { lnum = c.lnum, end_lnum = c.end_lnum }
      c.pos = { sha = c.anchor.sha, lnum = c.anchor.lnum, end_lnum = c.anchor.end_lnum, state = 'current' }
    end
    views[r] = c
  end
  return c or nil
end

-- Render the comments: refill the quickfix view (after the current event
-- when `defer_view`, see refresh_view_later; on_change still runs now), then
-- on_change. Never called with the lock held.
function M.render(defer_view)
  if defer_view then refresh_view_later() else refresh_view() end
  on_change(comments)
end

-- The comments, in creation order. Treat as read-only.
function M.comments() return comments end

-- Replace the comments (a sync read the log)
function M.set_comments(list) comments = list end

-- Called after any change to the comments, including ones read from disk
function M.set_on_change(fn)
  on_change = fn
end

-- Called after every refill of the list view with (qf_id, idx before,
-- idx after), so a selection the refill moved isn't taken for navigation
function M.set_on_refill(fn)
  on_refill = fn
end

-- Publish the comments as a quickfix list and make it the current one
function M.show()
  if view_exists() then
    refresh_view()
    local nr = vim.fn.getqflist({ id = qf_id, nr = 0 }).nr
    local current = vim.fn.getqflist({ nr = 0 }).nr
    if nr ~= current then
      vim.cmd('silent ' .. (nr > current and 'cnewer ' or 'colder ') .. math.abs(nr - current))
    end
  else
    -- Record the id before filling, so the FileType event fired by the fill
    -- already sees the review as the current list
    vim.fn.setqflist({}, ' ', { title = QF_TITLE })
    qf_id = vim.fn.getqflist({ id = 0 }).id
    vim.fn.setqflist({}, 'r', { id = qf_id, items = view_items(), title = QF_TITLE })
  end
end

-- Whether the current quickfix list is the review view
function M.is_current_view()
  return view_exists() and vim.fn.getqflist({ id = 0 }).id == qf_id
end

return M
