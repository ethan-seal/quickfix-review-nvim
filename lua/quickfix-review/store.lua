-- The review's comments. The plugin owns them here rather than in the quickfix
-- list, so other tools that replace the quickfix list (LSP references, grep)
-- can't clobber the review. The storage file is the source of truth: every
-- change is written through immediately, and the file is re-read whenever
-- something else (another Neovim, review-export) has changed it. Comments are
-- the storage schema's records (see storage.lua); the quickfix list is only a
-- view derived from them, which M.show() publishes.
local M = {}

local config = require('quickfix-review.config')
local storage = require('quickfix-review.storage')
local utils = require('quickfix-review.utils')

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

-- A stable identity for a comment: 16 hex chars from the OS RNG. Not
-- math.random, which LuaJIT leaves unseeded, so every Neovim would produce
-- the same sequence.
local function new_id()
  local bytes = assert((vim.uv or vim.loop).random(8))
  return (bytes:gsub('.', function(b) return string.format('%02x', b:byte()) end))
end

local function has_id(item)
  return type(item.id) == 'string' and item.id ~= ''
end

-- The fields normalize() understands; any other field of a record is kept in
-- its `extra` table. `text` is a legacy field that is parsed, then dropped.
local KNOWN = {
  id = true, filename = true, kind = true, body = true, response = true, lnum = true,
  end_lnum = true, context = true, created_at = true, text = true,
}

-- A line number (1 or more), or nil. A numeric string ("12", as an external
-- tool may write) is accepted.
local function to_line(v)
  if type(v) == 'string' then v = tonumber(v) end
  if type(v) ~= 'number' or v ~= math.floor(v) or v < 1 then return nil end
  return v
end

local function nonempty(s)
  return type(s) == 'string' and s ~= '' and s or nil
end

-- Keep only the fields of a comment record, giving it an id if it has none
-- (comments saved before ids existed). Returns nil for a record that has no
-- file or no valid line number.
local function normalize(item)
  local filename = item.filename
  if type(filename) ~= 'string' or filename == '' then return nil end
  local lnum = to_line(item.lnum)
  if not lnum then return nil end
  -- Older saves were raw getqflist() items, where end_lnum 0 means "unset";
  -- an end before the start is never valid, so treat it as a single line.
  local end_lnum = to_line(item.end_lnum)
  if not end_lnum or end_lnum < lnum then end_lnum = lnum end

  local kind, body = nonempty(item.kind), nonempty(item.body)
  local response = nonempty(item.response)
  -- An external tool (or an older one) may write the v1 text into a v2
  -- record, e.g. appending " | Response: ..." to it; merge it in
  if type(item.text) == 'string' then
    local t_kind, t_body, t_response = storage.parse_text(item.text)
    kind = kind or t_kind
    body = body or nonempty(t_body)
    if t_response then response = t_response end
  end

  local extra = {}
  for k, v in pairs(item) do
    if not KNOWN[k] then extra[k] = v end
  end

  return {
    id = has_id(item) and item.id or new_id(),
    filename = vim.fn.fnamemodify(filename, ':p'),
    kind = kind and kind:lower() or 'note',
    body = body or '',
    response = response,
    lnum = lnum,
    end_lnum = end_lnum,
    context = type(item.context) == 'table' and item.context or nil,
    created_at = type(item.created_at) == 'number' and item.created_at or os.time(),
    extra = next(extra) ~= nil and extra or nil,
  }
end

local function view_exists()
  return qf_id ~= nil and vim.fn.getqflist({ id = qf_id }).id == qf_id
end

-- A comment as displayed: "[KIND] body", or "[KIND:L1-5] body" for a range
function M.headline(c)
  local label = c.kind:upper()
  if c.end_lnum > c.lnum then
    label = string.format('%s:L%d-%d', label, c.lnum, c.end_lnum)
  end
  return '[' .. label .. '] ' .. c.body
end

-- The quickfix row for a comment: its headline, with " | Response: reply"
-- when it has one. The row carries only the comment's id in user_data; the
-- context stays in the store.
local function view_item(c)
  local text = M.headline(c)
  if c.response then
    text = text .. ' | Response: ' .. c.response
  end
  return {
    filename = c.filename,
    lnum = c.lnum,
    end_lnum = c.end_lnum,
    col = 1,
    text = text,
    type = c.kind:sub(1, 1):upper(),
    user_data = { id = c.id },
  }
end

local function view_items()
  local items = {}
  for i, c in ipairs(comments) do
    items[i] = view_item(c)
  end
  return items
end

local function refresh_view()
  if view_exists() then
    vim.fn.setqflist({}, 'r', { id = qf_id, items = view_items(), title = QF_TITLE })
  end
end

-- Where the review lives: the explicit (deprecated, global) storage_file, or
-- comments.json in the project's storage dir. The project root is the git
-- toplevel of the global cwd, else the cwd itself (symlinks resolved).
-- Memoized on the cwd and the storage_dir option, so it is a string compare
-- on every store call.
local resolved = {}

local function resolve()
  local explicit = config.options.storage_file
  if explicit ~= nil then
    return { path = explicit, dir = vim.fn.fnamemodify(explicit, ':h'), explicit = true }
  end
  local cwd = vim.fn.getcwd(-1, -1)
  local opt = config.options.storage_dir
  if resolved.cwd == cwd and resolved.opt == opt then return resolved end

  local root = utils.realpath(utils.git_toplevel(cwd) or cwd)
  local dir
  if type(opt) == 'function' then
    dir = opt(root)
  elseif type(opt) == 'string' then
    dir = opt
  end
  if type(dir) ~= 'string' or dir == '' then
    dir = vim.fn.stdpath('data') .. '/quickfix-review/'
      .. vim.fn.fnamemodify(root, ':t') .. '-' .. vim.fn.sha256(root):sub(1, 12)
  end
  -- ~ and $VARS are expanded; the result is absolute, without a trailing slash
  dir = (vim.fn.fnamemodify(vim.fs.normalize(dir), ':p'):gsub('(.)/+$', '%1'))
  resolved = { cwd = cwd, opt = opt, root = root, dir = dir, path = dir .. '/comments.json' }
  return resolved
end

-- The storage file the review is read from and written to
function M.path()
  return resolve().path
end

-- The project's storage directory (for an explicit storage_file, its directory)
function M.dir()
  return resolve().dir
end

-- The project root the storage dir belongs to, or nil for an explicit storage_file
function M.root()
  return resolve().root
end

local function mkdir_for(path)
  local parent = vim.fn.fnamemodify(path, ':h')
  if vim.fn.isdirectory(parent) == 0 then vim.fn.mkdir(parent, 'p') end
end

-- Storage paths whose legacy import has been tried this session
local import_tried = {}

-- First use of a project with no comments.json: copy the comments under the
-- project root out of the legacy global file (old default storage_file). The
-- legacy file is only read, never upgraded, backed up or rewritten. The
-- comments.json is written even when nothing matches, so the import happens
-- once per project, across restarts.
local function import_legacy(loc)
  if import_tried[loc.path] then return end
  import_tried[loc.path] = true

  local legacy = config.legacy_storage_file()
  if vim.fn.filereadable(legacy) == 0 then return end
  if utils.files_match(legacy, loc.path) then return end

  local list, err = storage.load(legacy)
  if not list then
    vim.notify('quickfix-review: not importing from ' .. legacy .. ': ' .. err, vim.log.levels.WARN)
    return
  end

  local imported, seen = {}, {}
  for _, item in ipairs(list) do
    local c = type(item) == 'table' and normalize(item) or nil
    if c and utils.is_under(c.filename, loc.root) then
      if seen[c.id] then c.id = new_id() end
      seen[c.id] = true
      table.insert(imported, c)
    end
  end

  mkdir_for(loc.path)
  local ok, message = storage.save(imported, loc.path)
  if not ok then
    vim.notify('quickfix-review: import from ' .. legacy .. ' failed: ' .. message, vim.log.levels.ERROR)
    return
  end
  if #imported > 0 then
    vim.notify(string.format('quickfix-review: imported %d comments from %s', #imported, legacy))
  end
end

-- Re-read the storage file if it isn't the version `comments` reflects
-- Returns: ok (boolean), err (string or nil)
local function sync()
  local loc = resolve()
  local path = loc.path
  local current = mtime(path)
  if current == nil and not loc.explicit then
    import_legacy(loc)
    current = mtime(path)
  end
  if path == synced.path and current == synced.mtime then return true end

  local list, err, upgraded = storage.load(path)
  -- Keep the file as it was before an upgrade rewrites it
  if upgraded then
    local backed_up, berr = storage.backup_once(path, '.pre-v' .. storage.VERSION .. '.bak')
    if not backed_up then list, err = nil, berr end
  end
  local function refuse(e)
    local key = path .. ':' .. tostring(current)
    if key ~= bad_file_notified then
      bad_file_notified = key
      vim.notify('quickfix-review: ' .. e .. '; the review will not be modified until the file is fixed',
        vim.log.levels.ERROR)
    end
    return false, e
  end
  if not list then return refuse(err) end

  local loaded = {}
  -- An upgraded file is rewritten in the current schema, once
  local rewrite = upgraded
  local dropped = 0
  local seen = {}
  for _, item in ipairs(list) do
    local c = normalize(item)
    if not c then
      dropped = dropped + 1
    else
      if not has_id(item) or type(item.created_at) ~= 'number' then rewrite = true end
      -- A legacy text field (merged by normalize) and numeric-string line
      -- numbers are rewritten in the current schema, once
      if type(item.text) == 'string' or type(item.lnum) == 'string' or type(item.end_lnum) == 'string' then
        rewrite = true
      end
      -- A hand-copied comment shares its id; give the copy its own, so
      -- remove(id) never deletes both
      if seen[c.id] then
        c.id = new_id()
        rewrite = true
      end
      seen[c.id] = true
      table.insert(loaded, c)
    end
  end
  -- Records that can't be shown (no file, or no valid line number) are
  -- dropped, and the file rewritten without them: keep the original first.
  -- If that backup fails the review stays read-only, so nothing is lost.
  if dropped > 0 then
    local bak_suffix = '.pre-repair.bak'
    local backed_up, berr = storage.backup_once(path, bak_suffix)
    if not backed_up then return refuse(berr) end
    vim.notify(string.format('quickfix-review: dropped %d comment(s) with an invalid line number or no file in %s;'
      .. ' original kept at %s', dropped, path, path .. bak_suffix), vim.log.levels.WARN)
    rewrite = true
  end
  bad_file_notified = nil
  comments = loaded
  synced = { path = path, mtime = current }
  -- Persist ids (and creation times) given to comments that had none, once,
  -- so they stay stable.
  -- An upgraded file is rewritten too (after the backup above).
  -- Not write(): on failure that would forget the synced version, so every
  -- sync would re-read the file and hand out new ids. A failure is left
  -- silent; the next real change retries the write and reports it.
  if rewrite and storage.save(comments, path) then
    synced = { path = path, mtime = mtime(path) }
  end
  refresh_view()
  on_change(comments)
  return true
end

-- On failure the file is untouched, so `comments` no longer reflects it:
-- forget the synced version so the next sync() re-reads the file.
local function write()
  local path = resolve().path
  mkdir_for(path)
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

-- Add a comment
-- Returns: true if it was added, false if it has no file or the change was refused
function M.add(item)
  return update(function()
    local c = normalize(item)
    if not c then return false end
    table.insert(comments, c)
    return true
  end) == true
end

-- The comment with this id, or nil. Treat as read-only.
function M.get(id)
  sync()
  for _, c in ipairs(comments) do
    if c.id == id then return c end
  end
  return nil
end

-- Remove every comment for which pred(comment) is true
-- Returns: number removed, or nil if the change was refused (unreadable file)
function M.remove_if(pred)
  return update(function()
    local kept, removed = {}, 0
    for _, c in ipairs(comments) do
      if pred(c) then removed = removed + 1 else table.insert(kept, c) end
    end
    comments = kept
    return removed
  end)
end

-- Remove the comment with this id
-- Returns: number removed (0 if there is none), or nil if the change was refused
function M.remove(id)
  return M.remove_if(function(c) return c.id == id end)
end

-- Remove every comment
-- Returns: true, or nil if the change was refused
function M.clear()
  return update(function()
    comments = {}
    return true
  end)
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
    vim.fn.setqflist({}, 'r', { id = qf_id, items = view_items(), title = QF_TITLE })
  end
end

-- Whether the current quickfix list is the review view
function M.is_current_view()
  return view_exists() and vim.fn.getqflist({ id = 0 }).id == qf_id
end

return M
