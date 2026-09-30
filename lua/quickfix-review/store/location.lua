-- Where the review is stored: the project root, the storage dir and the
-- paths in it (resolve), pinned for the length of a change (with_location).
local M = {}

local config = require('quickfix-review.config')
local notify = require('quickfix-review.notify')
local utils = require('quickfix-review.utils')

local uv = vim.uv or vim.loop

-- Where the review lives. Per project, in the project's storage dir (next
-- to where comments.json used to be): the journal's event segments in
-- `events/`, its checkpoints in `checkpoints/`, the flock'ed `journal.lock`
-- (and the mkdir lock dir `lock` where flock is unavailable), and the v2
-- files a migration reads: log.jsonl (a tombstone once migrated) and
-- state.json. See docs/journal.md. The project root is the git toplevel of
-- the global cwd, else the cwd itself (symlinks resolved). Memoized on the
-- cwd and the storage_dir option, so it is a string compare on every store
-- call.
--
-- With the explicit (deprecated, global) storage_file, the same files sit
-- next to that file, named after it (<file>.events, <file>.checkpoints,
-- <file>.journal.lock, <file>.snapshots, and the v2 <file>.log.jsonl and
-- <file>.state.json; <file>.lock is the mkdir lock), so several storage_file
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
-- Returns: root, retryable (true when git failed and the answer is a guess)
local function project_root(cwd)
  local top, transient = utils.git_toplevel(cwd)
  if top then
    good_roots[cwd] = top
    -- Warned about again if git fails for this cwd again
    notify.forget('fallback:' .. cwd)
    return top, false
  end
  if not transient then return cwd, false end
  local guess = good_roots[cwd] or cwd
  -- Warned about once per cwd while git keeps failing
  notify.once('fallback:' .. cwd, string.format('git rev-parse failed in %s; using %s.'
    .. ' Comments may be stored under a different directory until git answers', cwd, guess),
    vim.log.levels.WARN)
  return guess, true
end

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
      log = explicit .. '.log.jsonl', state = explicit .. '.state.json', lock = explicit .. '.lock',
      flock = explicit .. '.journal.lock',
      events = explicit .. '.events', checkpoints = explicit .. '.checkpoints',
      snapshots = explicit .. '.snapshots',
    }
  end
  local cwd = vim.fn.getcwd(-1, -1)
  local opt = config.options.storage_dir
  if resolved.cwd == cwd and resolved.opt == opt
      and (not resolved.retry_at or uv.hrtime() < resolved.retry_at) then
    return resolved
  end

  local top, retry = project_root(cwd)
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
  local per_project = nil
  if type(dir) ~= 'string' or dir == '' then
    per_project = true
    dir = vim.fn.stdpath('data') .. '/quickfix-review/'
      .. vim.fn.fnamemodify(root, ':t') .. '-' .. vim.fn.sha256(root):sub(1, 12)
  end
  -- ~ and $VARS are expanded; the result is absolute, without a trailing slash
  dir = (vim.fn.fnamemodify(vim.fs.normalize(dir), ':p'):gsub('(.)/+$', '%1'))
  resolved = {
    cwd = cwd, opt = opt, root = root, dir = dir, shared = shared, per_project = per_project,
    path = dir .. '/comments.json',
    log = dir .. '/log.jsonl', state = dir .. '/state.json', lock = dir .. '/lock',
    flock = dir .. '/journal.lock',
    events = dir .. '/events', checkpoints = dir .. '/checkpoints',
    snapshots = dir .. '/snapshots',
    retry_at = retry and uv.hrtime() + RETRY_NS or nil,
  }
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
