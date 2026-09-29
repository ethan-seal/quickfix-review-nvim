-- The files of a v3 journal (docs/journal.md#layout): the numbered event
-- segments in `events/` (000001.jsonl, ...), their `.refs` sidecars, and the
-- durable writes the journal's derived files (refs, checkpoints, the v2
-- tombstone) are made with. No state: every function takes paths.
--
-- A segment file is never renamed, rewritten or truncated once it exists:
-- it is created complete (a temp file outside `events/`, hard-linked into
-- place, so a reader never sees it without its header) and only ever
-- appended to (log.append) while it is the highest-numbered one.
local M = {}

local uv = vim.uv or vim.loop

-- Every 64-hex run: a snapshot sha (see store/maintenance.lua gc)
M.SHA_RUN = '%f[%x]' .. ('%x'):rep(64) .. '%f[^%x]'

-- The file name of segment `n`: zero-padded, so names sort by position
function M.name(n) return string.format('%06d.jsonl', n) end

function M.path(dir, n) return dir .. '/' .. M.name(n) end

function M.refs_path(dir, n) return dir .. '/' .. string.format('%06d.refs', n) end

-- The segment numbers in `dir`, ascending (empty when it is missing)
function M.list(dir)
  local out = {}
  local handle = uv.fs_scandir(dir)
  while handle do
    local name = uv.fs_scandir_next(handle)
    if not name then break end
    local n = name:match('^(%d%d%d%d%d%d+)%.jsonl$')
    if n then table.insert(out, tonumber(n)) end
  end
  table.sort(out)
  return out
end

-- fsync the directory `dir`, so a rename or link in it is durable. Not
-- every platform can open a directory: a failure is ignored.
function M.fsync_dir(dir)
  local fd = uv.fs_open(dir, 'r', 0)
  if not fd then return end
  pcall(uv.fs_fsync, fd)
  uv.fs_close(fd)
end

-- Write `str` to a new file at `path` (a temp name, which must not exist),
-- with `mode`, and fsync it
-- Returns: ok, err
local function write_new(path, str, mode)
  local fd, err = uv.fs_open(path, 'wx', mode or 420)
  if not fd then return false, err end
  local n, werr = uv.fs_write(fd, str, 0)
  if n ~= #str then
    uv.fs_close(fd)
    os.remove(path)
    return false, werr or string.format('short write (%d of %d bytes)', n or 0, #str)
  end
  local synced, serr = uv.fs_fsync(fd)
  uv.fs_close(fd)
  if not synced then
    os.remove(path)
    return false, serr
  end
  return true, nil
end

-- Write `str` to `path` durably: to `<path>.tmp.<pid>`, fsync'ed, renamed
-- into place, and the directory fsync'ed. A reader sees the old file or
-- the new one, never a part.
-- Returns: ok, err
function M.durable_write(path, str, mode)
  local tmp = path .. '.tmp.' .. uv.os_getpid()
  os.remove(tmp)
  local ok, err = write_new(tmp, str, mode)
  if not ok then return false, err end
  local renamed, rerr = uv.fs_rename(tmp, path)
  if not renamed then
    os.remove(tmp)
    return false, rerr
  end
  M.fsync_dir(vim.fn.fnamemodify(path, ':h'))
  return true, nil
end

-- Create segment `n` in `dir` holding `events` (its header first), with
-- `mode`: written to a temp file beside `dir` (never inside it, where a
-- reader could take it for a segment), fsync'ed, then hard-linked to its
-- name, which fails if it exists (as O_EXCL would), and the dir fsync'ed.
-- Returns: 'created', 'exists' (nothing written), or nil and an error
function M.create(dir, n, events, mode)
  local parts = {}
  for i, ev in ipairs(events) do
    local ok, line = pcall(vim.json.encode, ev)
    if not ok then return nil, 'could not encode a ' .. tostring(ev.op) .. ' event' end
    parts[i] = line .. '\n'
  end
  if vim.fn.isdirectory(dir) == 0 then
    local ok = pcall(vim.fn.mkdir, dir, 'p')
    if not ok or vim.fn.isdirectory(dir) == 0 then return nil, 'Could not create ' .. dir end
  end
  local res, err = M.create_file(M.path(dir, n), table.concat(parts), mode, dir .. '.tmp.' .. uv.os_getpid())
  if res == 'created' then M.fsync_dir(vim.fn.fnamemodify(dir, ':h')) end
  return res, err
end

-- Create `path` holding `str`, with `mode`, never replacing it: written to
-- `tmp` (default `<path>.tmp.<pid>`), fsync'ed, hard-linked to `path`
-- (which fails if it exists, as O_EXCL would, but never shows a partial
-- file), and `path`'s dir fsync'ed.
-- Returns: 'created', 'exists' (nothing written), or nil and an error
function M.create_file(path, str, mode, tmp)
  tmp = tmp or (path .. '.tmp.' .. uv.os_getpid())
  os.remove(tmp)
  local ok, err = write_new(tmp, str, mode)
  if not ok then return nil, 'Could not write ' .. tmp .. ': ' .. tostring(err) end
  local linked, lerr, lname = uv.fs_link(tmp, path)
  os.remove(tmp)
  if not linked then
    if lname == 'EEXIST' then return 'exists' end
    return nil, 'Could not create ' .. path .. ': ' .. tostring(lerr)
  end
  M.fsync_dir(vim.fn.fnamemodify(path, ':h'))
  return 'created'
end

-- The snapshot hashes the lines of `data` after its first (the header)
-- name, up to byte `upto` (default all): a sorted list
function M.refs_of(data, upto)
  if upto then data = data:sub(1, upto) end
  local nl = data:find('\n', 1, true)
  local set = {}
  if nl then
    for sha in data:sub(nl + 1):gmatch(M.SHA_RUN) do set[sha:lower()] = true end
  end
  local out = vim.tbl_keys(set)
  table.sort(out)
  return out
end

-- Write the `.refs` sidecar of segment `n` in `dir` (the hashes it names,
-- see refs_of), durably. Derived: a missing or stale one is rebuilt.
-- Returns: ok, err
function M.write_refs(dir, n, mode)
  local fh = io.open(M.path(dir, n), 'rb')
  if not fh then return false, 'Could not read ' .. M.path(dir, n) end
  local data = fh:read('*a')
  fh:close()
  return M.durable_write(M.refs_path(dir, n), vim.json.encode(M.refs_of(data)) .. '\n', mode)
end

return M
