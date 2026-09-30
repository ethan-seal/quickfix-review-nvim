-- Storage functionality for quickfix-review.nvim
local M = {}

local segment = require('quickfix-review.store.segment')

local uv = vim.uv or vim.loop

-- Replace `path` with `str` so that readers only ever see the old or the new
-- contents: write a per-process temp file next to it, fsync, then rename it
-- over `path` and fsync its directory, so the rename survives a crash.
-- On failure the temp file is removed and `path` is untouched.
-- A symlink is followed, so the link stays and its target is replaced, and an
-- existing file keeps its permission bits.
-- Returns: ok (boolean), err (string or nil)
function M.atomic_write(path, str)
  -- A new file (or a dangling link) has no realpath: write `path` itself
  local target = uv.fs_realpath(path) or path
  local stat = uv.fs_stat(target)
  local mode = stat and bit.band(stat.mode, 511) or 420 -- 0777 mask; new files 0644
  local tmp = target .. '.tmp.' .. uv.os_getpid()
  local fd, err = uv.fs_open(tmp, 'w', mode)
  if not fd then return false, err end

  local function fail(e)
    if fd then uv.fs_close(fd) end
    uv.fs_unlink(tmp)
    return false, e or 'unknown error'
  end

  -- fs_open's mode is narrowed by the umask; an existing file's mode is not
  if stat then
    local chmoded, merr = uv.fs_fchmod(fd, mode)
    if not chmoded then return fail(merr) end
  end

  local n, werr = uv.fs_write(fd, str, 0)
  if not n then return fail(werr) end
  if n ~= #str then return fail(string.format('short write (%d of %d bytes)', n, #str)) end

  local synced, serr = uv.fs_fsync(fd)
  if not synced then return fail(serr) end

  local closed, cerr = uv.fs_close(fd)
  fd = nil
  if not closed then return fail(cerr) end

  local renamed, rerr = uv.fs_rename(tmp, target)
  if not renamed then return fail(rerr) end
  segment.fsync_dir(vim.fn.fnamemodify(target, ':h'))

  return true, nil
end

-- The schema version this code reads and writes. The file is
-- { "version": 2, "comments": [ comment... ] }, where a comment is
-- { id, filename, kind, body, response?, lnum, end_lnum, context?, anchor?, created_at }
-- (anchor: { sha?, lnum, end_lnum, lines?, before?, after? }, see store/record.lua).
-- Other fields a record carries in the file (written by external tools) are
-- kept in memory as `extra` and written back at the top level of the record.
-- Version 1 was a bare list of quickfix-shaped items.
M.VERSION = 2

-- A table whose keys are exactly 1..n. With luanil.array a JSON null element
-- becomes a hole, and ipairs would silently drop everything after it (then
-- the next save would persist the truncation). `#` can't detect this: its
-- result is any border when the table has holes. An empty table is a list
-- (JSON [] and {} both decode to one).
local function is_list(t)
  if type(t) ~= 'table' then return false end
  local count, max = 0, 0
  for k in pairs(t) do
    if type(k) ~= 'number' or k ~= math.floor(k) or k < 1 then return false end
    count = count + 1
    if k > max then max = k end
  end
  return max == count
end

-- v1 kept git context in user_data, flat ({ commit, commit_short, snippet },
-- as context.capture returns it) or, in principle, nested under `context`.
-- Qf rows put the comment id there too, which is not context.
local function v1_context(ud)
  if type(ud) ~= 'table' then return nil end
  if type(ud.context) == 'table' then return ud.context end
  if ud.id == nil then return ud end -- keeps an empty dict an empty dict
  local ctx = {}
  for k, v in pairs(ud) do
    if k ~= 'id' then ctx[k] = v end
  end
  return next(ctx) ~= nil and ctx or nil
end

-- Parse a v1-style comment text: "[ISSUE:L1-5] body | Response: reply". The
-- range is dropped (lnum/end_lnum are authoritative). Also used for a `text`
-- field that an external tool writes into a v2 record.
-- Returns: kind (lowercase, or nil without a leading [KIND] prefix), body,
-- response (or nil)
function M.parse_text(text)
  local kind, rest = text:match('^%[([^:%]]+)[^%]]*%]%s*(.*)$')
  if not kind then rest = text end
  local body, response = rest:match('^(.-)%s*|%s*Response:%s*(.+)$')
  if not body then body = rest end
  return kind and kind:lower() or nil, body, response
end

-- v1 encoded kind, range and response in the text; text without a leading
-- [KIND] prefix is a note.
local function v1_comment(item)
  local kind, body, response = M.parse_text(type(item.text) == 'string' and item.text or '')

  return {
    id = item.id,
    -- Very old saves were raw getqflist() items that may have only a bufnr.
    -- That bufnr is from another session and names an unrelated buffer now,
    -- so such a record has no file (and is dropped, with a warning).
    filename = item.filename,
    kind = kind or 'note',
    body = body,
    response = response,
    lnum = item.lnum,
    end_lnum = item.end_lnum,
    context = v1_context(item.user_data),
    -- v1 has no creation time, so an upgraded comment is stamped when it is
    -- upgraded; the real time is unknowable
    created_at = type(item.created_at) == 'number' and item.created_at or os.time(),
  }
end

local function from_1_to_2(doc)
  local comments = {}
  for i, item in ipairs(doc.comments) do
    comments[i] = v1_comment(item)
  end
  return { version = 2, comments = comments }
end

-- steps[n] turns a version n document into a version n + 1 one
local steps = {
  [1] = from_1_to_2,
}

-- Bring a decoded document up to M.VERSION. A bare list is version 1.
-- Returns: { version = M.VERSION, comments = list }
function M.upgrade(doc)
  if doc.version == nil then doc = { version = 1, comments = doc } end
  while doc.version < M.VERSION do
    doc = steps[doc.version](doc)
  end
  return doc
end

-- A record as written: its `extra` fields flattened back to the top level,
-- where known fields win a clash. The in-memory record is not changed. This
-- is also the payload format of the event log (see log.lua).
local function serialise(c)
  if c.extra == nil then return c end
  local out = {}
  for k, v in pairs(c) do
    if k ~= 'extra' then out[k] = v end
  end
  for k, v in pairs(c.extra) do
    if out[k] == nil then out[k] = v end
  end
  return out
end

M.serialise = serialise

-- Decode the contents of a storage file (a comments.json, of any schema
-- version), upgrading an older schema in memory. Empty content is an empty
-- review.
-- Returns: comments (table or nil), err (string or nil), upgraded (boolean)
function M.parse(content, filepath)
  if not content or vim.trim(content) == '' then
    return {}, nil, false
  end

  -- luanil: JSON null becomes nil at every depth (vim.fn.json_decode would
  -- give vim.NIL, which is truthy), e.g. a null commit outside a git repo
  local ok, doc = pcall(vim.json.decode, content, { luanil = { object = true, array = true } })
  local invalid = 'Failed to parse saved review at ' .. filepath .. ' (invalid JSON)'
  if not ok or type(doc) ~= 'table' then
    return nil, invalid
  end

  if not is_list(doc) then
    local v = doc.version
    if v == nil then return nil, invalid end
    if type(v) ~= 'number' or v ~= math.floor(v) or v < 1 or v > M.VERSION then
      return nil, 'Failed to parse saved review at ' .. filepath .. ' (unknown version '
        .. vim.inspect(v) .. ')'
    end
    if not is_list(doc.comments) then
      return nil, invalid
    end
  end

  local from = doc.version or 1
  doc = M.upgrade(doc)
  return doc.comments, nil, from < M.VERSION
end

return M
