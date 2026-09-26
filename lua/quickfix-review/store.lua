-- The review's comments. The plugin owns them here rather than in the quickfix
-- list, so other tools that replace the quickfix list (LSP references, grep)
-- can't clobber the review. The storage file is the source of truth: every
-- change is written through immediately, and the file is re-read whenever
-- something else (another Neovim, review-export, migrate.ts) has changed it.
-- The quickfix list is only a view that M.show() publishes.
local M = {}

local config = require('quickfix-review.config')
local storage = require('quickfix-review.storage')

local QF_TITLE = 'Code Review Comments'

local comments = {}
-- Which file (and which version of it) `comments` reflects
local synced = { path = nil, mtime = nil }
-- Id of the quickfix list showing the review, if one has been published
local qf_id = nil
local on_change = function(_) end
-- path:mtime of the unparseable storage file already reported, so it is
-- reported once rather than on every read and change
local bad_file_notified = nil

local function mtime(path)
  local stat = (vim.uv or vim.loop).fs_stat(path)
  return stat and (stat.mtime.sec .. '.' .. stat.mtime.nsec) or nil
end

-- Keep only the fields that describe a comment. Files written by older
-- versions were raw quickfix dumps and may carry a stale bufnr.
local function normalize(item)
  local filename = item.filename
  if (not filename or filename == '') and item.bufnr and item.bufnr ~= 0 then
    filename = vim.fn.bufname(item.bufnr)
  end
  if not filename or filename == '' then return nil end
  return {
    filename = vim.fn.fnamemodify(filename, ':p'),
    lnum = item.lnum,
    end_lnum = item.end_lnum,
    col = item.col or 1,
    text = item.text,
    type = item.type,
    user_data = item.user_data,
  }
end

local function view_exists()
  return qf_id ~= nil and vim.fn.getqflist({ id = qf_id }).id == qf_id
end

local function refresh_view()
  if view_exists() then
    vim.fn.setqflist({}, 'r', { id = qf_id, items = comments, title = QF_TITLE })
  end
end

-- Re-read the storage file if it isn't the version `comments` reflects
-- Returns: ok (boolean), err (string or nil)
local function sync()
  local path = config.options.storage_file
  local current = mtime(path)
  if path == synced.path and current == synced.mtime then return true end

  local list, err = storage.load(path)
  if not list then
    local key = path .. ':' .. tostring(current)
    if key ~= bad_file_notified then
      bad_file_notified = key
      vim.notify('quickfix-review: ' .. err .. '; the review will not be modified until the file is fixed',
        vim.log.levels.ERROR)
    end
    return false, err
  end
  bad_file_notified = nil

  comments = {}
  for _, item in ipairs(list) do
    local c = normalize(item)
    if c then table.insert(comments, c) end
  end
  synced = { path = path, mtime = current }
  refresh_view()
  on_change(comments)
  return true
end

-- On failure the file is untouched, so `comments` no longer reflects it:
-- forget the synced version so the next sync() re-reads the file.
local function write()
  local path = config.options.storage_file
  local ok, message = storage.save(comments, path)
  if ok then
    synced = { path = path, mtime = mtime(path) }
  else
    synced = { path = nil, mtime = nil }
  end
  return ok, message
end

-- Apply `fn` to the latest comments and write the result through to disk.
-- Refuses to change anything if the storage file can't be read, so an
-- unreadable file is never silently overwritten (sync() reports that once).
-- If the write fails the change is dropped: `comments` is re-read from the
-- untouched file, so memory never holds a change that isn't on disk.
-- Returns: whatever fn returns, or nil if the change was refused
local function update(fn)
  if not sync() then return nil end
  local result = fn()
  local saved, message = write()
  if not saved then
    vim.notify('quickfix-review: ' .. message, vim.log.levels.ERROR)
    sync()
  end
  refresh_view()
  on_change(comments)
  return result
end

-- Called after any change to the comments, including ones read from disk
function M.set_on_change(fn)
  on_change = fn
end

-- All comments, in creation order. Treat as read-only.
function M.all()
  sync()
  return comments
end

function M.add(item)
  update(function() table.insert(comments, normalize(item)) end)
end

-- Remove every comment for which pred(comment) is true
-- Returns: number removed (0 if the change was refused)
function M.remove(pred)
  return update(function()
    local kept, removed = {}, 0
    for _, c in ipairs(comments) do
      if pred(c) then removed = removed + 1 else table.insert(kept, c) end
    end
    comments = kept
    return removed
  end) or 0
end

function M.clear()
  update(function() comments = {} end)
end

-- Re-read the storage file even if it looks unchanged
-- Returns: ok (boolean), message (string)
function M.reload()
  synced = { path = nil, mtime = nil }
  local ok, err = sync()
  if not ok then return false, err end
  return true, string.format('Review loaded: %d comments', #comments)
end

-- Write the comments to disk even though every change already is
-- Returns: ok (boolean), message (string)
function M.save()
  local ok, err = sync()
  if not ok then return false, err end
  return write()
end

-- Publish the comments as a quickfix list and make it the current one
function M.show()
  M.all()
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
    vim.fn.setqflist({}, 'r', { id = qf_id, items = comments, title = QF_TITLE })
  end
end

-- Whether the current quickfix list is the review view
function M.is_current_view()
  return view_exists() and vim.fn.getqflist({ id = 0 }).id == qf_id
end

return M
