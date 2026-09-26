-- Storage functionality for quickfix-review.nvim
local M = {}

local uv = vim.uv or vim.loop

-- Replace `path` with `str` so that readers only ever see the old or the new
-- contents: write a per-process temp file next to it, fsync, then rename it
-- over `path`. On failure the temp file is removed and `path` is untouched.
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

  return true, nil
end

-- Save comments to file (an empty list is saved too, so clearing persists)
-- Returns: success (boolean), message (string)
function M.save(comments, filepath)
  local ok, encoded = pcall(vim.json.encode, comments)
  if not ok then
    return false, 'Failed to encode comments as JSON'
  end

  local wrote, err = M.atomic_write(filepath, encoded)
  if not wrote then
    return false, 'Could not write ' .. filepath .. ': ' .. (err or 'unknown error')
  end

  return true, string.format('Review saved to %s (%d comments)', filepath, #comments)
end

-- Load comments from file. A missing or empty file is an empty review.
-- Returns: comments (table or nil), err (string or nil)
function M.load(filepath)
  local f = io.open(filepath, 'r')
  if not f then
    return {}, nil
  end

  local content = f:read('*all')
  f:close()

  if not content or vim.trim(content) == '' then
    return {}, nil
  end

  -- luanil: JSON null becomes nil at every depth (vim.fn.json_decode would
  -- give vim.NIL, which is truthy), e.g. the null commit migrate.ts wrote
  local ok, comments = pcall(vim.json.decode, content, { luanil = { object = true, array = true } })
  local invalid = 'Failed to parse saved review at ' .. filepath .. ' (invalid JSON)'
  if not ok or type(comments) ~= 'table' then
    return nil, invalid
  end

  -- The top level must be a list without holes. With luanil.array a null
  -- element becomes a hole, and ipairs would silently drop everything after
  -- it (then the next save would persist the truncation). `#` can't detect
  -- this: its result is any border when the table has holes.
  local count, max = 0, 0
  for k in pairs(comments) do
    if type(k) ~= 'number' or k ~= math.floor(k) or k < 1 then
      return nil, invalid
    end
    count = count + 1
    if k > max then max = k end
  end
  if max ~= count then
    return nil, invalid
  end

  return comments, nil
end

return M
