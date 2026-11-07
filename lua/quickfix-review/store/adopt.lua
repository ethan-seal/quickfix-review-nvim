-- Adopting an orphaned review (:ReviewAdopt): the review of another storage
-- dir, e.g. the dir the project had before it was moved or renamed (the
-- dir is keyed on the realpath of the project root), copied into the
-- current project's dir. The event segments and snapshots are copied
-- (never hard-linked: the active segment is appended to, and a shared inode
-- would make both reviews share every write); checkpoints and `.refs` are
-- derived and rebuilt. The old dir is only read.
--
-- The one event adopt appends (to the copied active segment, before the
-- journal is put in place: segments are never rewritten) is a rebase
-- { from_root = the old project root }, when the review holds absolute
-- filenames under it (records logged before filenames were relative): the
-- reader shows them under the current root (record.resolve_filename). The
-- old root is not stored anywhere: it is found among the ancestors of those
-- filenames, as the one whose name and sha256 give the old dir's name
-- (location.resolve's `<name>-<sha256(root):sub(1, 12)>`). A dir not named
-- so (a custom storage_dir), or records logged through a symlinked path,
-- give no root, and adopt copies the journal as it is.
local M = {}

local journal = require('quickfix-review.store.journal')
local log = require('quickfix-review.log')
local location = require('quickfix-review.store.location')
local lock = require('quickfix-review.store.lock')
local segment = require('quickfix-review.store.segment')

local uv = vim.uv or vim.loop

-- The paths of the review in storage dir `dir`, laid out as location.resolve
-- lays out a stdpath dir (the source of an adopt is always read so)
local location_of = location.stdpath_location

-- Whether the dir at `loc` already holds a review (location.has_review):
-- structural, so adopting never has to merge two journals
local has_review = location.has_review

-- Whether the review at `loc` is a journal that never held a comment: no
-- comments.json, and nothing live, trashed
-- or removed (e.g. a journal holding only the empty import of a review
-- created before empty imports were skipped). A cleared review has
-- removals, so it is not empty.
local function empty_journal(loc)
  if uv.fs_stat(loc.path) then return false end
  local r = journal.replay(loc.events, nil)
  if not r then return false end
  local st = r.state
  return #st.comments == 0 and next(st.trash) == nil and #st.removed == 0
end

-- The project root the storage dir `old_real` was made for, confirmed by
-- its name (see the header), among the ancestors of the absolute filenames
-- in `state` (live and trashed records), or nil
local function old_root(old_real, state)
  local name, hash = vim.fn.fnamemodify(old_real, ':t'):match('^(.+)%-(' .. ('%x'):rep(12) .. ')$')
  if not name then return nil end
  local seen = {}
  local function find(filename)
    if type(filename) ~= 'string' or filename:sub(1, 1) ~= '/' then return nil end
    local dir = filename
    while true do
      dir = dir:match('^(.*)/[^/]*$')
      if not dir or dir == '' then return nil end
      if seen[dir] then return nil end
      seen[dir] = true
      if dir:match('[^/]*$') == name and vim.fn.sha256(dir):sub(1, 12) == hash then return dir end
    end
  end
  for _, r in ipairs(state.comments) do
    local root = find(r.filename)
    if root then return root end
  end
  for _, r in pairs(state.trash) do
    local root = find(r.filename)
    if root then return root end
  end
  return nil
end

-- Copy the file `src` to the new file `dst` (which must not exist) with
-- `src`'s mode, fsync'ed: a copy of the bytes, never a link
-- Returns: ok, err
local function copy_file(src, dst)
  local st = uv.fs_stat(src)
  local data = location.read_bytes(src)
  if not st or not data then return false, 'Could not read ' .. src end
  local fd, err = uv.fs_open(dst, 'wx', bit.band(st.mode, 511))
  if not fd then return false, 'Could not create ' .. dst .. ': ' .. tostring(err) end
  local n, werr = uv.fs_write(fd, data, 0)
  local synced, serr = true, nil
  if n == #data then synced, serr = uv.fs_fsync(fd) end
  uv.fs_close(fd)
  if n ~= #data or not synced then
    os.remove(dst)
    return false, 'Could not write ' .. dst .. ': ' .. tostring(werr or serr or 'short write')
  end
  return true, nil
end

-- Copy the snapshots in `from` that `to` lacks (snapshots are named by the
-- sha of their content, so an existing one is the same). With `tmp_dir`
-- (in the repo) each is copied there and then linked into `to`, so no
-- partial file is ever left under a sha name in snapshots/.
-- Returns: ok, err
local function copy_snapshots(from, to, tmp_dir)
  local handle = uv.fs_scandir(from)
  if not handle then return true, nil end
  if vim.fn.isdirectory(to) == 0 and not pcall(vim.fn.mkdir, to, 'p') then
    return false, 'Could not create ' .. to
  end
  while true do
    local name, kind = uv.fs_scandir_next(handle)
    if not name then break end
    if kind == 'file' and name:match('^%x+$') and not uv.fs_stat(to .. '/' .. name) then
      if tmp_dir then
        local tmp = segment.tmp_for(to .. '/' .. name, tmp_dir)
        os.remove(tmp)
        local ok, err = copy_file(from .. '/' .. name, tmp)
        if not ok then return false, err end
        local linked, lerr, lname = uv.fs_link(tmp, to .. '/' .. name)
        os.remove(tmp)
        if not linked and lname ~= 'EEXIST' then
          return false, 'Could not create ' .. to .. '/' .. name .. ': ' .. tostring(lerr)
        end
      else
        local ok, err = copy_file(from .. '/' .. name, to .. '/' .. name)
        if not ok then return false, err end
      end
    end
  end
  segment.fsync_dir(to)
  if tmp_dir then segment.fsync_dir(tmp_dir) end
  return true, nil
end

-- Why the review at `old` can't be adopted into `loc`, or nil
-- Returns: reason or nil, the journal's inspect() result, and whether `loc`
-- holds an empty journal (see empty_journal) to be replaced
local function refusal(loc, old)
  local replace = false
  if has_review(loc) then
    if not empty_journal(loc) then
      return 'the current project already has a review in ' .. loc.dir
        .. ' (adopting only copies into a project that has none)'
    end
    replace = true
  end
  local info, err = journal.inspect(old.events)
  if not info then
    return old.dir .. ' holds no v3 review (' .. tostring(err) .. '); a review from an older version'
      .. ' is migrated when it is opened in its own project'
  end
  return nil, info, replace
end

-- Copy the journal of the storage dir `old_dir` into the current project's
-- (per-project) storage dir, which must hold no review. Both reviews'
-- locks are held while copying. Does not sync: the caller does.
-- Returns: true and the number of segments copied, or false and a reason
function M.adopt(old_dir)
  if type(old_dir) ~= 'string' or old_dir == '' then return false, 'no directory given' end
  local loc = location.resolve()
  if not loc.per_project then
    return false, 'adopting needs the default per-project storage dir (storage_file or storage_dir is set)'
  end
  local old_real = uv.fs_realpath(vim.fn.fnamemodify(vim.fs.normalize(old_dir), ':p'))
  if not old_real or vim.fn.isdirectory(old_real) == 0 then return false, old_dir .. ' is not a directory' end
  local cur_real = uv.fs_realpath(loc.dir)
  if old_real == loc.dir or old_real == cur_real then
    return false, old_dir .. ' is the current project\'s own storage dir'
  end
  local old = location_of(old_real)
  local why = refusal(loc, old)
  if why then return false, why end

  local got, ok, res = journal.locked(loc, function()
    local lok, cok, cres = lock.with_lock(old, function()
      -- Again under the locks: another Neovim may have written meanwhile
      local reason, info, replace = refusal(loc, old)
      if reason then return false, reason end
      local replayed, perr = journal.replay(old.events, nil)
      if not replayed then return false, old.dir .. ': ' .. tostring(perr) end
      local from_root = old_root(old.dir, replayed.state)
      -- Copied into a staging dir beside events/ (in the repo, in
      -- local/tmp), then renamed into place, so a reader sees no journal or
      -- all of it
      local tmp_dir, terr = location.ensure_tmp(loc)
      if terr then return false, terr end
      local staging_dir = tmp_dir or loc.dir
      local staging = staging_dir .. '/events.adopt-' .. uv.os_getpid()
      vim.fn.delete(staging, 'rf')
      if not pcall(vim.fn.mkdir, staging, 'p') or vim.fn.isdirectory(staging) == 0 then
        return false, 'Could not create ' .. staging
      end
      for _, n in ipairs(info.segs) do
        local cp, cerr = copy_file(segment.path(old.events, n), segment.path(staging, n))
        if not cp then
          vim.fn.delete(staging, 'rf')
          return false, cerr
        end
      end
      if from_root then
        local last = segment.path(staging, info.segs[#info.segs])
        local lmode = bit.band((uv.fs_stat(last) or { mode = 420 }).mode, 511)
        local aok, aerr = log.append(last, { log.event('rebase', { from_root = from_root }) }, lmode)
        if not aok then
          vim.fn.delete(staging, 'rf')
          return false, 'Could not write to ' .. last .. ': ' .. tostring(aerr)
        end
      end
      -- In the repo, events/.gitattributes moves with the journal: the
      -- existing one (its bytes kept) into the staging dir, else a new one,
      -- so the adopted events/ is still marked (and an events/ holding only
      -- it can be replaced). Moved back if the journal can't be moved in.
      local marker, staged_marker, marker_moved
      if loc.in_repo then
        marker, staged_marker = loc.events .. '/.gitattributes', staging .. '/.gitattributes'
        if uv.fs_lstat(marker) then
          local mv, merr = uv.fs_rename(marker, staged_marker)
          if not mv then
            vim.fn.delete(staging, 'rf')
            return false, 'Could not move ' .. marker .. ': ' .. tostring(merr)
          end
          marker_moved = true
        else
          local res, cerr = segment.create_file(staged_marker, location.GITATTRIBUTES, 420,
            segment.tmp_for(staged_marker, tmp_dir))
          if not res then
            vim.fn.delete(staging, 'rf')
            return false, tostring(cerr)
          end
        end
      end
      local function abandon()
        if marker_moved then
          if vim.fn.isdirectory(loc.events) == 0 then pcall(vim.fn.mkdir, loc.events, 'p') end
          uv.fs_rename(staged_marker, marker)
        end
        vim.fn.delete(staging, 'rf')
      end
      segment.fsync_dir(staging)
      -- An empty journal (see empty_journal) is moved aside, and put back if
      -- the new one can't be moved in; an empty events/ (a review never
      -- written to) is replaced
      local aside
      if replace then
        aside = staging_dir .. '/events.replaced-' .. uv.os_getpid()
        vim.fn.delete(aside, 'rf')
        local moved, merr = uv.fs_rename(loc.events, aside)
        if not moved then
          abandon()
          return false, 'Could not move ' .. loc.events .. ' aside: ' .. tostring(merr)
        end
      elseif uv.fs_stat(loc.events) then
        uv.fs_rmdir(loc.events)
      end
      local renamed, rerr = uv.fs_rename(staging, loc.events)
      if not renamed then
        if aside then uv.fs_rename(aside, loc.events) end
        abandon()
        return false, 'Could not move ' .. staging .. ' to ' .. loc.events .. ': ' .. tostring(rerr)
      end
      segment.fsync_dir(loc.dir)
      if tmp_dir then segment.fsync_dir(tmp_dir) end
      if aside then vim.fn.delete(aside, 'rf') end
      local sok, serr = copy_snapshots(old.snapshots, loc.snapshots, tmp_dir)
      if not sok then
        vim.notify('quickfix-review: adopted the review, but not all of its snapshots: ' .. tostring(serr),
          vim.log.levels.WARN)
      end
      return true, #info.segs
    end)
    if not lok then return false, cok end
    return cok, cres
  end)
  if not got then return false, ok end
  return ok, res
end

return M
