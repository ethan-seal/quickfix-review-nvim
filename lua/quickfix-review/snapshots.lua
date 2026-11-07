-- Content-addressed snapshots of commented files. A comment's anchor names
-- the version of the file it was written against by the sha of a snapshot;
-- the snapshot is the file's lines in canonical form, stored as
-- <snapshots dir>/<sha> (see store.snapshots_dir: per project, resolved at
-- every call so :cd switches it).
--
-- Canonical form: the lines, each without its trailing CRs, joined with
-- "\n", plus a final "\n" whatever the file's eol/fixeol. So a buffer's lines
-- and readfile() of the same file hash alike, and CRLF, LF and a missing
-- final newline share a sha. (readfile() drops a BOM and every CR before a
-- NL, but not the CRs of a last line without a NL; a buffer with 'ff' unix
-- keeps every CR. All are stripped here.)
--
-- A line holding a NUL would split in two when read back, so the anchor's
-- lnum no longer indexes the snapshot. readfile() gives a NUL as "\n", and so
-- does nvim_buf_get_lines before NVIM 0.12; from 0.12 it gives "\0". Both are
-- taken as "\n" first, so a buffer and the file on disk hash alike. Such a
-- line is escaped: "\r" -> "\r1", "\n" -> "\r0",
-- plus a final "\r" marking it as escaped. With trailing CRs stripped, no
-- other stored line ends in a CR, so the marker is unambiguous and canonical
-- is idempotent on what get returns. Other lines are stored as they are, so
-- their shas are unchanged. (Snapshots stored when a CR CR line was escaped,
-- as "x\r1\r", still read back as "x\r", which canonical takes as "x".)
local M = {}

local storage = require('quickfix-review.storage')
local location = require('quickfix-review.store.location')

local uv = vim.uv or vim.loop

-- Snapshots read recently, most recent last: { path, lines }. Keyed by path,
-- so a snapshot of another project's dir is never served after :cd.
local CACHE_SIZE = 8
local cache = {}

-- Warned-about corrupt snapshot paths, so a redraw loop warns once
local warned = {}

local function canonical(lines)
  local out = {}
  for i, line in ipairs(lines) do
    line = line:gsub('%z', '\n'):gsub('\r+$', '')
    if line:find('\n', 1, true) then
      line = line:gsub('\r', '\r1'):gsub('\n', '\r0') .. '\r'
    end
    out[i] = line
  end
  return table.concat(out, '\n') .. '\n'
end

-- `lines` in canonical form (a string), as hashed and stored
M.canonical = canonical

local function is_sha(sha)
  return type(sha) == 'string' and #sha == 64 and sha:match('^%x+$') ~= nil
end

local function cache_get(path)
  for i, entry in ipairs(cache) do
    if entry.path == path then
      table.remove(cache, i)
      table.insert(cache, entry)
      return entry.lines
    end
  end
end

local function cache_put(path, lines)
  table.insert(cache, { path = path, lines = lines })
  if #cache > CACHE_SIZE then table.remove(cache, 1) end
end

-- The sha of `lines` (a list of strings) in canonical form
function M.hash(lines)
  return vim.fn.sha256(canonical(lines))
end

local UNESCAPE = { ['0'] = '\n', ['1'] = '\r' }

-- A stored line back as the line it was (see canonical)
local function unescape(line)
  if line:sub(-1) ~= '\r' then return line end
  return (line:sub(1, -2):gsub('\r([01])', UNESCAPE))
end

local function read_file(path)
  local fh = io.open(path, 'rb')
  if not fh then return nil end
  local content = fh:read('*a')
  fh:close()
  return content
end

-- Store `lines` and return their sha. An existing snapshot with the right
-- content is kept and its mtime touched: store.gc_snapshots deletes only
-- unreferenced snapshots untouched for a day, so this keeps one that another
-- Neovim is about to reference alive. One whose content is wrong is rewritten.
-- Returns: sha (string) or nil, err (string or nil)
function M.put(lines)
  local content = canonical(lines)
  local sha = vim.fn.sha256(content)
  local loc = location.resolve()
  local dir = loc.snapshots
  local path = dir .. '/' .. sha

  local stat = uv.fs_stat(path)
  if stat and stat.type == 'file' and stat.size == #content and read_file(path) == content then
    local now = os.time()
    uv.fs_utime(path, now, now)
    return sha, nil
  end

  if vim.fn.isdirectory(dir) == 0 then
    local ok, made = pcall(vim.fn.mkdir, dir, 'p')
    if not ok or made == 0 then
      return nil, 'Could not create ' .. dir .. (ok and '' or ': ' .. tostring(made))
    end
  end

  -- In the repo, the temp file goes to local/tmp: never left in snapshots/
  local tmp_dir, terr = location.ensure_tmp(loc)
  if terr then return nil, 'Could not write snapshot ' .. path .. ': ' .. terr end
  local wrote, err = storage.atomic_write(path, content, tmp_dir)
  if not wrote then
    return nil, 'Could not write snapshot ' .. path .. ': ' .. (err or 'unknown error')
  end
  return sha, nil
end

-- The lines of snapshot `sha`, or nil when it is missing or corrupt (its
-- content doesn't hash to `sha`; that warns once per file). The result is a
-- fresh list the caller may change.
function M.get(sha)
  if not is_sha(sha) then return nil end
  local path = location.resolve().snapshots .. '/' .. sha:lower()

  local hit = cache_get(path)
  if hit then return vim.list_extend({}, hit) end

  local content = read_file(path)
  if not content then return nil end

  if content:sub(-1) ~= '\n' or vim.fn.sha256(content) ~= sha:lower() then
    if not warned[path] then
      warned[path] = true
      vim.notify('quickfix-review: snapshot ' .. path .. ' is corrupt (content does not match its hash); ignoring it',
        vim.log.levels.WARN)
    end
    return nil
  end

  local lines = vim.split(content:sub(1, -2), '\n', { plain = true })
  for i, line in ipairs(lines) do lines[i] = unescape(line) end
  cache_put(path, lines)
  return vim.list_extend({}, lines)
end

-- Forget the cached snapshots (for tests)
function M._clear_cache()
  cache = {}
  warned = {}
end

return M
