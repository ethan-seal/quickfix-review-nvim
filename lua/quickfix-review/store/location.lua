-- Where the review is stored: the project root, the storage dir and the
-- paths in it (resolve), pinned for the length of a change (with_location).
local M = {}

local config = require('quickfix-review.config')
local notify = require('quickfix-review.notify')
local segment = require('quickfix-review.store.segment')
local utils = require('quickfix-review.utils')

local uv = vim.uv or vim.loop

-- Where the review lives. Per project, in the project's storage dir (next
-- to where comments.json used to be): the journal's event segments in
-- `events/`, its checkpoints in `checkpoints/`, the flock'ed `journal.lock`
-- (and the mkdir lock dir `lock` where flock is unavailable). See
-- docs/journal.md. The project root is the git toplevel of
-- the global cwd, else the cwd itself (symlinks resolved). Memoized on the
-- cwd and the storage_dir option, so it is a string compare on every store
-- call.
--
-- By default a git toplevel's review is in the repo, at
-- <root>/.quickfix-review/ (in_repo): `events/` and `snapshots/` are
-- tracked, everything else (locks, checkpoints, `.refs`, gc.stamp, temp
-- files) is under `local/`, which ignores itself (local/.gitignore is `*`);
-- events/.gitattributes merges segments with git's union driver. No temp
-- file is ever written into events/ or snapshots/ there: they go to
-- local/tmp (loc.tmp, see ensure_tmp), so a crash leaves nothing for
-- `git add -A` to pick up. Outside a git repo the review is in
-- stdpath('data') (stdpath_dir), laid out flat as before.
--
-- Every location has: dir, path (comments.json), lock, flock, events,
-- checkpoints, snapshots, refs (where the `.refs` sidecars go: events/
-- except in the repo), gc_stamp, and tmp (nil except in the repo: each
-- writer then puts its temp file where it always has).
--
-- With the explicit (deprecated, global) storage_file, the same files sit
-- next to that file, named after it (<file>.events, <file>.checkpoints,
-- <file>.journal.lock, <file>.snapshots; <file>.lock is the mkdir lock), so several storage_file
-- values in one directory never share a journal. The path is used as given,
-- not resolved: migrating renames the file, which would change a resolved
-- path.
--
-- A git that fails or times out is not a "not a repo" answer: the last root
-- git gave for this cwd is used, else the cwd itself with a warning, and the
-- memo is only kept for RETRY_NS, so git is asked again (and the review
-- moves to the real root once it answers; sync sees the changed log).
local resolved = {}
-- The last root git gave, per cwd
local good_roots = {}
local RETRY_NS = 5e9

-- Test hook: how long a fallback root is kept before git is asked again
-- (a fallback memoized now is kept no longer than that either)
function M._set_retry_ns(ns)
  RETRY_NS = ns
  utils._set_retry_ns(ns)
  if resolved.retry_at then resolved.retry_at = math.min(resolved.retry_at, uv.hrtime() + ns) end
end

-- The project root of `cwd`: its git toplevel, else the cwd itself
-- Returns: root, retryable (true when git failed and the answer is a
-- guess), in_git (the root is a git toplevel: git said so, or the guess is
-- the root git last gave)
local function project_root(cwd)
  local top, transient = utils.git_toplevel(cwd)
  if top then
    good_roots[cwd] = top
    -- Warned about again if git fails for this cwd again
    notify.forget('fallback:' .. cwd)
    return top, false, true
  end
  if not transient then return cwd, false, false end
  local guess = good_roots[cwd] or cwd
  local in_git = good_roots[cwd] ~= nil
  -- Warned about once per cwd while git keeps failing
  notify.once('fallback:' .. cwd, string.format('git rev-parse failed in %s; using %s.'
    .. ' Comments may be stored under a different directory until git answers', cwd, guess),
    vim.log.levels.WARN)
  return guess, true, in_git
end

-- The stdpath('data') storage dir of project root `root` (a realpath):
-- <data>/quickfix-review/<basename>-<sha256(root):sub(1, 12)>, the default
-- outside a git repo (and every project's default before reviews moved
-- into the repo)
function M.stdpath_dir(root)
  return vim.fn.stdpath('data') .. '/quickfix-review/'
    .. vim.fn.fnamemodify(root, ':t') .. '-' .. vim.fn.sha256(root):sub(1, 12)
end

-- The paths of the review in the flat-layout storage dir `dir` (a stdpath
-- dir, or a storage_dir option's), as resolve lays one out
function M.stdpath_location(dir)
  local events, snapshots = dir .. '/events', dir .. '/snapshots'
  return {
    dir = dir, path = dir .. '/comments.json',
    lock = dir .. '/lock', flock = dir .. '/journal.lock',
    events = events, checkpoints = dir .. '/checkpoints', snapshots = snapshots,
    refs = events, gc_stamp = snapshots .. '/gc.stamp', tmp = nil,
  }
end

-- The paths of the in-repo review at `dir` (<root>/.quickfix-review)
local function repo_location(dir)
  local l = dir .. '/local'
  return {
    dir = dir, in_repo = true, path = l .. '/comments.json',
    lock = l .. '/lock', flock = l .. '/journal.lock',
    events = dir .. '/events', checkpoints = l .. '/checkpoints', snapshots = dir .. '/snapshots',
    refs = l .. '/refs', gc_stamp = l .. '/gc.stamp', tmp = l .. '/tmp',
  }
end

-- Whether the dir at `loc` already holds a review: any event segment or a
-- comments.json. Structural, not "has comments": a review that was written
-- to and then cleared still counts. The in-repo marker files are not a
-- review.
function M.has_review(loc)
  return #segment.list(loc.events) > 0 or uv.fs_stat(loc.path) ~= nil
end

-- Create `path` holding `str` unless it exists (an existing one is left
-- byte-identical, whatever it holds), its temp file in `tmp_dir`
-- Returns: ok, err
local function seed(path, str, tmp_dir)
  local tmp = tmp_dir .. '/' .. vim.fn.fnamemodify(path, ':t') .. '.tmp.' .. uv.os_getpid()
  local res, err = segment.create_file(path, str, 420, tmp)
  if res == 'created' or res == 'exists' then return true, nil end
  return false, err
end

-- Make the in-repo review's local/tmp (seeding local/.gitignore first, so
-- nothing under local/ is ever untracked-but-visible) and return it; nil
-- for every other location, whose writers put temp files where they always
-- have.
-- Returns: the tmp dir or nil, err
function M.ensure_tmp(loc)
  if not loc.in_repo then return nil, nil end
  if vim.fn.isdirectory(loc.tmp) == 0 then
    pcall(vim.fn.mkdir, loc.tmp, 'p')
    if vim.fn.isdirectory(loc.tmp) == 0 then return nil, 'Could not create ' .. loc.tmp end
  end
  local ok, err = seed(loc.dir .. '/local/.gitignore', '*\n', loc.tmp)
  if not ok then return nil, err end
  return loc.tmp, nil
end

-- Seed the in-repo review's marker files: local/.gitignore (via
-- ensure_tmp) and events/.gitattributes. Existing ones are left alone.
-- Nothing for other locations.
-- Returns: ok, err
function M.seed_markers(loc)
  if not loc.in_repo then return true, nil end
  local _, terr = M.ensure_tmp(loc)
  if terr then return false, terr end
  if vim.fn.isdirectory(loc.events) == 0 then
    pcall(vim.fn.mkdir, loc.events, 'p')
    if vim.fn.isdirectory(loc.events) == 0 then return false, 'Could not create ' .. loc.events end
  end
  return seed(loc.events .. '/.gitattributes', M.GITATTRIBUTES, loc.tmp)
end

-- events/.gitattributes of an in-repo review: segments are only ever
-- appended to, so two branches' appends merge as the union of their lines
M.GITATTRIBUTES = '*.jsonl merge=union\n'

-- The location a change (mutate) resolved first: every resolve() during the
-- change returns it, so a fallback root's retry window expiring mid-change
-- can't send the change's syncs (and what they call) to another project
local pinned = nil

function M.resolve()
  if pinned then return pinned end
  local explicit = config.options.storage_file
  if explicit ~= nil then
    return {
      path = explicit, dir = vim.fn.fnamemodify(explicit, ':h'), explicit = true,
      lock = explicit .. '.lock',
      flock = explicit .. '.journal.lock',
      events = explicit .. '.events', checkpoints = explicit .. '.checkpoints',
      snapshots = explicit .. '.snapshots',
      refs = explicit .. '.events', gc_stamp = explicit .. '.snapshots/gc.stamp', tmp = nil,
    }
  end
  local cwd = vim.fn.getcwd(-1, -1)
  local opt = config.options.storage_dir
  if resolved.cwd == cwd and resolved.opt == opt
      and (not resolved.retry_at or uv.hrtime() < resolved.retry_at) then
    return resolved
  end

  local top, retry, in_git = project_root(cwd)
  local root = utils.realpath(top)
  local dir
  -- A fixed string dir is one review shared by every project
  local shared = nil
  if type(opt) == 'function' then
    dir = opt(root)
  elseif type(opt) == 'string' and opt ~= '' then
    dir, shared = opt, true
  end
  -- The default dir is this root's alone (keyed on its realpath), so its
  -- records may name files relative to the root (see record.relativize)
  -- (in the repo when it is a git toplevel, else stdpath_dir)
  local per_project, in_repo = nil, false
  if type(dir) ~= 'string' or dir == '' then
    per_project = true
    if in_git then
      dir, in_repo = root .. '/.quickfix-review', true
    else
      dir = M.stdpath_dir(root)
    end
  end
  -- ~ and $VARS are expanded; the result is absolute, without a trailing slash
  dir = (vim.fn.fnamemodify(vim.fs.normalize(dir), ':p'):gsub('(.)/+$', '%1'))
  resolved = in_repo and repo_location(dir) or M.stdpath_location(dir)
  resolved.cwd, resolved.opt, resolved.root = cwd, opt, root
  resolved.shared, resolved.per_project = shared, per_project
  resolved.retry_at = retry and uv.hrtime() + RETRY_NS or nil
  return resolved
end

-- Call fn(loc, ...) with the location resolved once and pinned (see
-- pinned), so everything it does (snapshots.put, syncs, a change) uses that
-- location even if a fallback root's retry window expires meanwhile. Nests;
-- the previous pin is restored even if fn errors.
-- Returns: what fn returns
function M.with_location(fn, ...)
  local loc = M.resolve()
  local prev = pinned
  pinned = loc
  local res = vim.F.pack_len(pcall(fn, loc, ...))
  pinned = prev
  if not res[1] then error(res[2], 0) end
  return unpack(res, 2, res.n)
end

-- Where comments.json is kept once it has been migrated into the log
M.MIGRATED = '.pre-log.bak'

-- Create the directory of path if it is missing.
-- Returns: ok (boolean), err (string or nil)
function M.mkdir_for(path)
  local parent = vim.fn.fnamemodify(path, ':h')
  if vim.fn.isdirectory(parent) == 1 then return true, nil end
  local ok, err = pcall(vim.fn.mkdir, parent, 'p')
  if vim.fn.isdirectory(parent) == 1 then return true, nil end
  return false, ok and 'not a directory' or tostring(err)
end

function M.read_bytes(path)
  local fh = io.open(path, 'rb')
  if not fh then return nil end
  local content = fh:read('*a')
  fh:close()
  return content
end

return M
