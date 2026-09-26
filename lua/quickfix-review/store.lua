-- The review's comments. The plugin owns them here rather than in the quickfix
-- list, so other tools that replace the quickfix list (LSP references, grep)
-- can't clobber the review. The source of truth is an append-only event log
-- (log.jsonl, see log.lua): every change is appended as an event, and the
-- comments are the log replayed through reduce.lua, so no change can lose
-- data. state.json is a cache of that replay, never needed for correctness.
-- Events another Neovim appends are picked up by reading the log's tail.
-- Comments are the storage schema's records (see storage.lua); the quickfix
-- list is only a view derived from them, which M.show() publishes.
local M = {}

local config = require('quickfix-review.config')
local log = require('quickfix-review.log')
local reduce = require('quickfix-review.reduce')
local storage = require('quickfix-review.storage')
local utils = require('quickfix-review.utils')

local uv = vim.uv or vim.loop

local QF_TITLE = 'Code Review Comments'

-- The live comments, normalized: the view of `reduced.comments`
local comments = {}
-- The log replayed: records as logged, and the trash
local reduced = reduce.new()
-- Id of the quickfix list showing the review, if one has been published
local qf_id = nil
local on_change = function(_) end
-- Called after every refill of the list view: (qf_id, idx before, idx after)
local on_refill = function(_, _, _) end


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
-- its `extra` table. `text` is a legacy field that is parsed, then dropped
-- (or kept as extra.legacy_text when the record didn't take all of it).
local KNOWN = {
  id = true, filename = true, kind = true, body = true, response = true, lnum = true,
  end_lnum = true, context = true, created_at = true, text = true, anchor = true,
}

-- A finite number (not NaN or +-inf, which vim.json.encode refuses), or nil
local function finite(v)
  if type(v) ~= 'number' or v ~= v or v == math.huge or v == -math.huge then return nil end
  return v
end

-- A line number (1 or more), or nil. A numeric string ("12", as an external
-- tool may write) is accepted; "1e999" (inf) is not.
local function to_line(v)
  if type(v) == 'string' then v = tonumber(v) end
  v = finite(v)
  if not v or v ~= math.floor(v) or v < 1 then return nil end
  return v
end

local function has_nonfinite(v)
  if type(v) == 'number' then return finite(v) == nil end
  if type(v) ~= 'table' then return false end
  for _, x in pairs(v) do
    if has_nonfinite(x) then return true end
  end
  return false
end

-- `v` without its non-finite numbers, at any depth; a list is rebuilt
-- without holes. Only tables that held one are copied.
local function drop_nonfinite(v)
  if not has_nonfinite(v) then return v end
  if type(v) ~= 'table' then return nil end
  local n = 0
  for _ in pairs(v) do n = n + 1 end
  local out = setmetatable({}, getmetatable(v))
  if n == #v then
    for _, x in ipairs(v) do
      local kept = drop_nonfinite(x)
      if kept ~= nil then table.insert(out, kept) end
    end
  else
    for k, x in pairs(v) do out[k] = drop_nonfinite(x) end
  end
  return out
end

-- Records whose non-finite numbers were dropped, by id, so each is warned about once
local nonfinite_warned = {}

local function nonempty(s)
  return type(s) == 'string' and s ~= '' and s or nil
end

local function string_list(t)
  if type(t) ~= 'table' then return nil end
  local out = {}
  for i = 1, #t do
    if type(t[i]) ~= 'string' then return nil end
    out[i] = t[i]
  end
  return out
end

-- A comment's anchor, { sha, lnum, end_lnum, lines, before, after }, as
-- written when it was made: lnum/end_lnum are relative to the snapshot
-- `sha`. nil when `a` has no valid line number; a bad field is dropped.
local function parse_anchor(a)
  if type(a) ~= 'table' then return nil end
  local lnum = to_line(a.lnum)
  if not lnum then return nil end
  local end_lnum = to_line(a.end_lnum)
  if not end_lnum or end_lnum < lnum then end_lnum = lnum end
  return {
    sha = nonempty(a.sha),
    lnum = lnum,
    end_lnum = end_lnum,
    lines = string_list(a.lines),
    before = string_list(a.before),
    after = string_list(a.after),
  }
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
  -- record, e.g. appending " | Response: ..." to it; merge it in. Text the
  -- record didn't take all of (its kind or body differ from the text's) is
  -- kept as extra.legacy_text rather than lost.
  local legacy_text
  if type(item.text) == 'string' then
    local t_kind, t_body, t_response = storage.parse_text(item.text)
    t_body = nonempty(t_body)
    kind = kind or t_kind
    body = body or t_body
    if t_response then response = t_response end
    local kind_taken = t_kind == nil or kind:lower() == t_kind
    local body_taken = t_body == nil or body == t_body
    if not (kind_taken and body_taken) then legacy_text = item.text end
  end

  local extra = {}
  for k, v in pairs(item) do
    if not KNOWN[k] then extra[k] = v end
  end
  if legacy_text and extra.legacy_text == nil then extra.legacy_text = legacy_text end

  local id = has_id(item) and item.id or new_id()
  local context = type(item.context) == 'table' and item.context or nil
  -- inf and NaN (1e999 in JSON) can't be written back: vim.json.encode
  -- refuses them
  if has_nonfinite(extra) or has_nonfinite(context) then
    extra, context = drop_nonfinite(extra), drop_nonfinite(context)
    if not nonfinite_warned[id] then
      nonfinite_warned[id] = true
      vim.notify(string.format('quickfix-review: dropped infinite or NaN numbers from comment %s', id),
        vim.log.levels.WARN)
    end
  end

  return {
    id = id,
    filename = vim.fn.fnamemodify(filename, ':p'),
    kind = kind and kind:lower() or 'note',
    body = body or '',
    response = response,
    lnum = lnum,
    end_lnum = end_lnum,
    context = context,
    anchor = parse_anchor(item.anchor),
    created_at = finite(item.created_at) or os.time(),
    extra = next(extra) ~= nil and extra or nil,
  }
end

local function view_exists()
  return qf_id ~= nil and vim.fn.getqflist({ id = qf_id }).id == qf_id
end

-- Where a comment is now, { sha, lnum, end_lnum, state } (see track.lua), or
-- nil for a record not read through the store (no id or anchor)
function M.pos(c)
  if type(c.id) ~= 'string' or type(c.filename) ~= 'string' or type(c.anchor) ~= 'table' then
    return nil
  end
  -- Required here: track requires snapshots, which requires the store
  return require('quickfix-review.track').pos(c)
end

-- Whether a comment's code changed since it was made (see track.lua)
function M.is_outdated(c)
  local p = M.pos(c)
  return p ~= nil and p.state == 'outdated'
end

-- The lines a comment is displayed at: its pos (where its anchor's lines
-- are now), else its anchor, else the record's top-level lnum/end_lnum (a
-- record not read through the store).
-- Returns: lnum, end_lnum
function M.range(c)
  local r = M.pos(c) or c.anchor or c
  local lnum = r.lnum or c.lnum
  return lnum, r.end_lnum or lnum
end

-- A comment as displayed: "[KIND] body", or "[KIND:L1-5] body" for a range
function M.headline(c)
  local label = c.kind:upper()
  local lnum, end_lnum = M.range(c)
  if end_lnum > lnum then
    label = string.format('%s:L%d-%d', label, lnum, end_lnum)
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
  if M.is_outdated(c) then text = '[outdated] ' .. text end
  local lnum, end_lnum = M.range(c)
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

-- In a track batch, so each comment's three M.range/is_outdated lookups
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

-- Where the review lives. Per project: log.jsonl (the review), state.json
-- (its cache) and the lock dir `lock`, in the project's storage dir, next to
-- where comments.json used to be. The project root is the git toplevel of the
-- global cwd, else the cwd itself (symlinks resolved). Memoized on the cwd
-- and the storage_dir option, so it is a string compare on every store call.
--
-- With the explicit (deprecated, global) storage_file, the log, cache and
-- lock sit next to that file, named after it (<file>.log.jsonl,
-- <file>.state.json, <file>.lock, <file>.snapshots), so two storage_file
-- values never share a log. The path is used as given, not resolved: migrating renames the file,
-- which would change a resolved path.
--
-- A git that fails or times out is not a "not a repo" answer: the last root
-- git gave for this cwd is used, else the cwd itself with a warning, and the
-- memo is only kept for RETRY_NS, so git is asked again (and the review
-- moves to the real root once it answers; sync sees the changed log).
local resolved = {}
-- The last root git gave, per cwd
local good_roots = {}
-- cwds warned about falling back to the cwd while git keeps failing
local fallback_warned = {}
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
    good_roots[cwd], fallback_warned[cwd] = top, nil
    return top, false
  end
  if not transient then return cwd, false end
  local guess = good_roots[cwd] or cwd
  if not fallback_warned[cwd] then
    fallback_warned[cwd] = true
    vim.notify(string.format('quickfix-review: git rev-parse failed in %s; using %s.'
      .. ' Comments may be stored under a different directory until git answers', cwd, guess),
      vim.log.levels.WARN)
  end
  return guess, true
end

local function resolve()
  local explicit = config.options.storage_file
  if explicit ~= nil then
    return {
      path = explicit, dir = vim.fn.fnamemodify(explicit, ':h'), explicit = true,
      log = explicit .. '.log.jsonl', state = explicit .. '.state.json', lock = explicit .. '.lock',
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
  if type(dir) ~= 'string' or dir == '' then
    dir = vim.fn.stdpath('data') .. '/quickfix-review/'
      .. vim.fn.fnamemodify(root, ':t') .. '-' .. vim.fn.sha256(root):sub(1, 12)
  end
  -- ~ and $VARS are expanded; the result is absolute, without a trailing slash
  dir = (vim.fn.fnamemodify(vim.fs.normalize(dir), ':p'):gsub('(.)/+$', '%1'))
  resolved = {
    cwd = cwd, opt = opt, root = root, dir = dir, shared = shared, path = dir .. '/comments.json',
    log = dir .. '/log.jsonl', state = dir .. '/state.json', lock = dir .. '/lock',
    snapshots = dir .. '/snapshots',
    retry_at = retry and uv.hrtime() + RETRY_NS or nil,
  }
  return resolved
end

-- The comments.json of the review: the pre-log storage file, which is
-- migrated into the log (and renamed to comments.json.pre-log.bak) on first use
function M.path()
  return resolve().path
end

-- The review's event log, its source of truth
function M.log_path()
  return resolve().log
end

-- The cache of the replayed log
function M.state_path()
  return resolve().state
end

-- The directory of the review's file snapshots (see snapshots.lua):
-- `snapshots/` in the storage dir, or `<storage_file>.snapshots`
function M.snapshots_dir()
  return resolve().snapshots
end

-- The project's storage directory (for an explicit storage_file, its directory)
function M.dir()
  return resolve().dir
end

-- The project root the storage dir belongs to, or nil for an explicit storage_file
function M.root()
  return resolve().root
end

-- Where comments.json is kept once it has been migrated into the log
local MIGRATED = '.pre-log.bak'
-- state.json is written after this many events, besides on exit and :ReviewSave
local FLUSH_EVERY = 50
local JSON_NIL = { luanil = { object = true, array = true } }

-- Create the directory of path if it is missing.
-- Returns: ok (boolean), err (string or nil)
local function mkdir_for(path)
  local parent = vim.fn.fnamemodify(path, ':h')
  if vim.fn.isdirectory(parent) == 1 then return true, nil end
  local ok, err = pcall(vim.fn.mkdir, parent, 'p')
  if vim.fn.isdirectory(parent) == 1 then return true, nil end
  return false, ok and 'not a directory' or tostring(err)
end

local function read_bytes(path)
  local fh = io.open(path, 'rb')
  if not fh then return nil end
  local content = fh:read('*a')
  fh:close()
  return content
end

-- The normalized comment for each logged record, so a record is normalized
-- once and an unchanged comment keeps its identity across changes. false for
-- a record that can't be shown (no file or no valid line number).
local views = setmetatable({}, { __mode = 'k' })

local function view_of(record)
  local c = views[record]
  if c == nil then
    c = normalize(record) or false
    if c then
      -- Derived, never logged: a comment from before anchors is anchored at
      -- its line with no snapshot (the fallback search handles it), and
      -- its display position starts at its anchor.
      c.anchor = c.anchor or { lnum = c.lnum, end_lnum = c.end_lnum }
      c.pos = { sha = c.anchor.sha, lnum = c.anchor.lnum, end_lnum = c.anchor.end_lnum, state = 'current' }
    end
    views[record] = c
  end
  return c or nil
end

-- What `reduced` reflects: which log (path, header log_id, inode), how far it
-- has been read (bytes and lines), and the source_sha256 of its imports
local synced
-- Events applied since state.json was last written
local unsaved = 0
-- Set when `reduced` is a comments.json loaded read-only (its storage dir is
-- not writable, so it can't be migrated): { log = the log it stands in for,
-- key = the comments.json version (size:mtime) loaded }
local readonly = nil

local function fresh_sync(loc)
  return { log = loc and loc.log, state = loc and loc.state, offset = 0, lines = 0, imports = {} }
end

-- Unreadable lines of the log already warned about (log.read's `seen`), so
-- each is warned about once: { log = path, log_id = its header's, lines = {} }
local log_seen = nil

-- The `seen` table for reading the log at `loc`, new when the log (path or
-- header log_id) is another one than the lines were seen in
local function seen_lines(loc)
  local id = log.read_id(loc.log)
  if not (log_seen and log_seen.log == loc.log and log_seen.log_id == id) then
    log_seen = { log = loc.log, log_id = id, lines = {} }
  end
  return log_seen.lines
end

-- The log (path:ino:size:mtime) comments.json was last checked against (see
-- check_reappeared): a sync that finds the log unchanged skips that stat
local reappeared_log_key

local function reset(loc)
  log_seen = nil
  reappeared_log_key = nil
  synced = fresh_sync(loc)
  reduced = reduce.new()
  unsaved = 0
  readonly = nil
end
reset(nil)

-- Messages shown once per session, by key
local notified = {}

local function notify_once(key, msg, level)
  if notified[key] then return end
  notified[key] = true
  vim.notify('quickfix-review: ' .. msg, level)
end

-- The error the review is currently refused for, so it is reported once
-- rather than on every read and change
local bad_notified = nil

local function refuse(e)
  if e ~= bad_notified then
    bad_notified = e
    vim.notify('quickfix-review: ' .. e .. '; the review will not be modified until the file is fixed',
      vim.log.levels.ERROR)
  end
  return false, e
end

-- Run fn with the review's lock held (log.with_lock), creating the storage
-- dir first. Nested calls (a sync inside a change) run under the outer lock.
-- Returns: true and fn's two results, or false and the lock error
local lock_held = false

local function locked(loc, fn)
  if lock_held then return true, fn() end
  local mk_ok, mk_err = mkdir_for(loc.log)
  if not mk_ok then return false, 'Could not create ' .. vim.fn.fnamemodify(loc.log, ':h') .. ': ' .. mk_err end
  lock_held = true
  local ok, got, a, b = pcall(log.with_lock, loc.lock, fn)
  lock_held = false
  if not ok then error(got, 0) end
  return got, a, b
end

local function apply(events)
  for _, ev in ipairs(events) do
    if ev.op == 'import' and type(ev.source_sha256) == 'string' then
      synced.imports[ev.source_sha256] = true
    elseif ev.op == 'checkpoint' and type(ev.imports) == 'table' then
      -- The imports of the log it rotated, so a crashed migration is still
      -- recognised (see check_reappeared)
      for _, sha in ipairs(ev.imports) do
        if type(sha) == 'string' then synced.imports[sha] = true end
      end
    end
    local _, ignored = reduce.apply(reduced, ev)
    if ignored == 'duplicate' then
      notify_once('duplicate', string.format('ignoring logged comments whose id is already in the review'
        .. ' (first: event %s in %s)', tostring(ev.eid), synced.log), vim.log.levels.WARN)
    end
  end
  unsaved = unsaved + #events
end

-- Write state.json (the replayed log, and how far it was read) if events
-- were applied since it was last written, or always with `force`. It is only
-- a cache: a failure is returned, never fatal.
-- Returns: ok (boolean), err (string or nil)
local function flush(force)
  if not synced.log_id or (unsaved == 0 and not force) then return true, nil end
  local doc = {
    log_id = synced.log_id, offset = synced.offset, lines = synced.lines,
    imports = vim.tbl_keys(synced.imports), state = reduced,
  }
  local ok, encoded = pcall(vim.json.encode, doc)
  if not ok then return false, 'could not encode the review cache' end
  -- A new cache gets the log's mode, so a private review's cache is private
  if not uv.fs_stat(synced.state) then
    local stat = uv.fs_stat(synced.log)
    local fd = uv.fs_open(synced.state, 'a', stat and bit.band(stat.mode, 511) or 420)
    if fd then uv.fs_close(fd) end
  end
  local wrote, err = storage.atomic_write(synced.state, encoded)
  if wrote then unsaved = 0 end
  return wrote, err
end

local function is_list(t)
  if type(t) ~= 'table' then return false end
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n == #t
end

-- The reduced state from state.json, if it is a cache of this log (same
-- log_id, no longer than the log); fills `base` with where it was read to
local function load_cache(loc, stat, base)
  local content = read_bytes(loc.state)
  if not content then return nil end
  local ok, doc = pcall(vim.json.decode, content, JSON_NIL)
  if not ok or type(doc) ~= 'table' or type(doc.state) ~= 'table' then return nil end
  local st = doc.state
  if type(doc.log_id) ~= 'string' or type(doc.offset) ~= 'number' or type(doc.lines) ~= 'number'
      or doc.offset > stat.size or not is_list(st.comments) or type(st.trash) ~= 'table'
      -- A cache from before `removed` existed is replayed from the log
      or not is_list(st.removed) then
    return nil
  end
  if log.read_id(loc.log) ~= doc.log_id then return nil end
  -- A log rewritten in place may keep its log_id: an offset mid-line is stale
  if not log.at_line_start(loc.log, doc.offset) then return nil end
  base.log_id, base.offset, base.lines = doc.log_id, doc.offset, doc.lines
  for _, sha in ipairs(is_list(doc.imports) and doc.imports or {}) do base.imports[sha] = true end
  return { comments = st.comments, trash = st.trash, removed = st.removed }
end

-- Bring `reduced` up to date with the log: read its tail, or replay it (from
-- state.json if that is valid, unless opts.full) when it is new, was
-- replaced or shrank. On failure nothing changes.
-- Returns: ok (boolean), err (string or nil), changed (boolean)
local function read_log(loc, stat, opts)
  local full = opts.full or not synced.log_id or synced.ino ~= stat.ino or stat.size < synced.offset
  -- A log of the same inode, and no shorter, may still be another one
  -- (rewritten in place rather than renamed over): a different (or no)
  -- header log_id means replay it from the start
  if not full and log.read_id(loc.log) ~= synced.log_id then full = true end
  -- ... and one rewritten in place under the same header is caught when the
  -- offset read to no longer follows a \n
  if not full and not log.at_line_start(loc.log, synced.offset) then full = true end
  if not full and stat.size == synced.offset then return true, nil, false end

  local base, state = synced, reduced
  local cached = false
  if full then
    base, state = fresh_sync(loc), nil
    if not opts.full then state = load_cache(loc, stat, base) end
    cached = state ~= nil
    if not state then
      base = fresh_sync(loc)
      state = reduce.new()
    end
  end
  local res, err = log.read(loc.log, base.offset, base.lines, seen_lines(loc))
  -- The log was replaced (rotated, see rotate) between the stat and the
  -- read: what was read (or failed to be) is another file than was stat'ed.
  -- Read the new one instead, once.
  local now = not opts.retried and uv.fs_stat(loc.log)
  if now and now.ino ~= stat.ino and (not res or (res.ino and res.ino ~= stat.ino)) then
    return read_log(loc, now, { full = opts.full, retried = true })
  end
  if not res then return false, err end
  if base.offset == 0 then base.log_id = res.log_id end

  if full then unsaved = 0 end
  synced, reduced = base, state
  synced.ino = stat.ino
  apply(res.events)
  synced.offset, synced.lines = res.offset, res.lines
  -- A replay that didn't come from the cache is worth caching
  if full and not cached and unsaved == 0 then unsaved = 1 end
  return true, nil, full or #res.events > 0
end

-- Load the records of a comments.json (its raw bytes): upgraded, normalized,
-- hand-copied duplicate ids split, and records that can't be shown dropped
-- with a warning. `backup` is where the original is kept (the
-- comments.json.pre-log.bak of a migration), or nil when it is left in place
-- (loaded read-only).
-- Returns: records, or nil and an error
local function load_records(raw, path, backup)
  local list, err = storage.parse(raw, path)
  if not list then return nil, err end
  local loaded, seen, dropped = {}, {}, 0
  for _, item in ipairs(list) do
    local c = type(item) == 'table' and normalize(item) or nil
    if not c then
      dropped = dropped + 1
    else
      -- A hand-copied comment shares its id; give the copy its own, so
      -- remove(id) never deletes both
      if seen[c.id] then c.id = new_id() end
      seen[c.id] = true
      table.insert(loaded, c)
    end
  end
  if dropped > 0 then
    local kept = backup and ('original kept at ' .. backup)
      or 'storage is read-only; the file is unchanged'
    vim.notify(string.format('quickfix-review: dropped %d comment(s) with an invalid line number or no file in %s;'
      .. ' %s', dropped, path, kept), vim.log.levels.WARN)
  end
  return loaded
end

local function serialise_all(records)
  local out = {}
  for i, c in ipairs(records) do out[i] = storage.serialise(c) end
  return out
end

-- An explicit storage_file that is the legacy global file (the old
-- default): that file is also every project's legacy import source, so it
-- is never renamed away, or a later per-project review would import nothing
local function is_legacy_global(loc)
  return loc.explicit == true and utils.files_match(loc.path, config.legacy_storage_file())
end

-- Move comments.json into a new log: under the lock, write the header and an
-- import of its comments (with the sha256 of its bytes) in one fsync'ed
-- append, then rename it to comments.json.pre-log.bak, which keeps the
-- original bytes. A crash before the rename is finished by the next sync,
-- which finds the import's sha256 in the log. An unreadable comments.json
-- is refused: no log is written and the file is left alone.
-- Returns: ok (boolean), err (string or nil)
local function migrate(loc)
  local got, ok, err = locked(loc, function()
    local st = uv.fs_stat(loc.log)
    if st and st.size > 0 then return true end -- another Neovim did it
    local src = uv.fs_stat(loc.path)
    if not src then return true end
    local raw = read_bytes(loc.path)
    if not raw then return nil, 'Could not read ' .. loc.path end
    local records, lerr = load_records(raw, loc.path, loc.path .. MIGRATED)
    if not records then return nil, lerr end
    local import = log.event('import', { source_sha256 = vim.fn.sha256(raw), comments = serialise_all(records) })
    local wrote, werr, landed = log.append(loc.log, { log.new_header(), import }, bit.band(src.mode, 511))
    if not wrote and landed ~= 2 then return nil, 'Could not write ' .. loc.log .. ': ' .. werr end
    if not wrote then
      vim.notify(string.format('quickfix-review: migrated %s into %s, but it may not be durable: %s',
        loc.path, loc.log, tostring(werr)), vim.log.levels.WARN)
    end
    -- The legacy global file stays in place: it is still the per-project
    -- import source (see import_legacy); the log's import sha256 marks it done
    if is_legacy_global(loc) then return true end
    local renamed, rerr = uv.fs_rename(loc.path, loc.path .. MIGRATED)
    if not renamed then
      vim.notify(string.format('quickfix-review: migrated %s into %s but could not rename it: %s',
        loc.path, loc.log, tostring(rerr)), vim.log.levels.WARN)
    end
    return true
  end)
  if not got then return false, ok end
  return ok == true, err
end

-- Storage paths whose legacy import has been tried this session
local import_tried = {}

-- First use of a project with neither a log nor a comments.json: copy the
-- comments under the project root out of the legacy global file (old default
-- storage_file) into a new log, as an import event. The legacy file is only
-- read, never upgraded, backed up or rewritten. The log is written even when
-- nothing matches, so the import happens once per project, across restarts:
-- a log is the "already imported" marker. When the legacy file is missing,
-- its .pre-log.bak is read instead: older versions renamed the legacy file
-- away when storage_file pointed at it, leaving only that copy.
-- Comments made while storage_file pointed at the legacy file live in its
-- log (<legacy>.log.jsonl); that log's reduced state is imported too. It
-- already holds an import of the legacy file, so while the file is
-- unchanged since (its sha256 is among the log's imports) the log alone is
-- the source; otherwise the file's records whose ids the log doesn't know
-- are added. The legacy log is only read: never locked, synced, rotated or
-- given a state.json.
local function import_legacy(loc)
  if import_tried[loc.log] then return end
  import_tried[loc.log] = true

  local legacy_path = config.legacy_storage_file()
  local legacy_log = legacy_path .. '.log.jsonl'
  local log_st = uv.fs_stat(legacy_log)
  if not log_st or log_st.size == 0 or utils.files_match(legacy_log, loc.log) then legacy_log = nil end

  local legacy = legacy_path
  if vim.fn.filereadable(legacy) == 0 then
    legacy = legacy .. MIGRATED
    if vim.fn.filereadable(legacy) == 0 then legacy = nil end
  end
  if legacy and (utils.files_match(legacy, loc.path) or utils.files_match(legacy, loc.log)) then return end
  if not legacy and not legacy_log then return end

  -- The legacy log's state and the shas of the files it imported
  local state, imports, log_raw_sha
  if legacy_log then
    local res, lerr = log.read(legacy_log, 0, 0, {})
    if res then
      state, imports = reduce.new(), {}
      for _, ev in ipairs(res.events) do
        if ev.op == 'import' and type(ev.source_sha256) == 'string' then imports[ev.source_sha256] = true end
        if ev.op == 'checkpoint' and type(ev.imports) == 'table' then
          for _, sha in ipairs(ev.imports) do
            if type(sha) == 'string' then imports[sha] = true end
          end
        end
        reduce.apply(state, ev)
      end
      local bytes = read_bytes(legacy_log)
      log_raw_sha = bytes and vim.fn.sha256(bytes) or nil
    else
      vim.notify('quickfix-review: not importing from ' .. legacy_log .. ': ' .. tostring(lerr), vim.log.levels.WARN)
      if not legacy then return end
    end
  end

  local raw, file_list
  if legacy then
    raw = read_bytes(legacy)
    local err
    file_list, err = storage.parse(raw, legacy)
    if not file_list then
      vim.notify('quickfix-review: not importing from ' .. legacy .. ': ' .. err, vim.log.levels.WARN)
      if not state then return end
      legacy, raw = nil, nil
    end
  end

  local list, source
  if state then
    list, source = vim.list_extend({}, state.comments), legacy_log
    -- The file changed after the log imported it: add what the log lacks
    if file_list and not imports[vim.fn.sha256(raw)] then
      local known = {}
      for _, c in ipairs(state.comments) do known[c.id] = true end
      for id, _ in pairs(state.trash) do known[id] = true end
      for _, r in ipairs(state.removed) do known[r.id] = true end
      for _, item in ipairs(file_list) do
        local c = type(item) == 'table' and normalize(item) or nil
        if not c or not known[c.id] then table.insert(list, c and storage.serialise(c) or item) end
      end
      source = legacy_log .. ' and ' .. legacy
    end
  else
    list, source = file_list, legacy
  end

  local imported, seen, dropped = {}, {}, 0
  for _, item in ipairs(list) do
    local c = type(item) == 'table' and normalize(item) or nil
    if not c then dropped = dropped + 1 end
    -- A shared dir is every project's review: import everything
    if c and (loc.shared or utils.is_under(c.filename, loc.root)) then
      if seen[c.id] then c.id = new_id() end
      seen[c.id] = true
      table.insert(imported, storage.serialise(c))
    end
  end
  if dropped > 0 then
    vim.notify(string.format('quickfix-review: not importing %d comment(s) from %s: invalid line number'
      .. ' or no file name (the file is unchanged)', dropped, source), vim.log.levels.WARN)
  end

  local got, ok, werr = locked(loc, function()
    local st = uv.fs_stat(loc.log)
    if st and st.size > 0 then return 'exists' end -- another Neovim did it
    local import = log.event('import', { source_sha256 = raw and vim.fn.sha256(raw) or log_raw_sha,
      comments = imported })
    return log.append(loc.log, { log.new_header(), import })
  end)
  if not got or not ok then
    vim.notify('quickfix-review: import from ' .. source .. ' failed: ' .. tostring(got and werr or ok),
      vim.log.levels.ERROR)
    return
  end
  if ok == true and #imported > 0 then
    vim.notify(string.format('quickfix-review: imported %d comments from %s', #imported, source))
  end
end

-- comments.json in a storage dir that is not writable, so it can't be
-- migrated: load it read-only into `reduced` (as if imported, but nothing is
-- written), again only when it changes. Changes are refused (see mutate).
-- Returns: ok (boolean), err (string or nil), changed (boolean)
local function load_readonly(loc, src)
  local key = string.format('%d:%d.%d', src.size, src.mtime.sec, src.mtime.nsec)
  if readonly and readonly.log == loc.log and readonly.key == key then return true, nil, false end
  local raw = read_bytes(loc.path)
  if not raw then return false, 'Could not read ' .. loc.path end
  local records, err = load_records(raw, loc.path, nil)
  if not records then return false, err end
  reset(loc)
  reduce.apply(reduced, { op = 'import', comments = serialise_all(records) })
  readonly = { log = loc.log, key = key }
  return true, nil, true
end

-- The log is missing (or empty): migrate comments.json into it (or load it
-- read-only if its dir is not writable), or import from the legacy global
-- file, or leave it to the first change to create
-- Returns: ok (boolean), err (string or nil), changed (boolean: `reduced`
-- was replaced)
local function init_storage(loc)
  local src = uv.fs_stat(loc.path)
  if src and not uv.fs_access(loc.dir, 'W') then return load_readonly(loc, src) end
  -- No longer read-only: what was shown is migrated now, or gone
  local was_readonly = readonly ~= nil
  if was_readonly then reset(loc) end
  local ok, err = true, nil
  if src then
    ok, err = migrate(loc)
  elseif not loc.explicit then
    import_legacy(loc)
  end
  return ok, err, was_readonly
end

-- The first line of the log at `path` is incomplete (no \n at all), or the
-- log is only a header while comments.json sits beside it: the header and
-- import of a migration (or the header and first event of a change) were
-- torn by a short write, so nothing but a partial header or event is lost.
local function is_torn(loc)
  local fd = uv.fs_open(loc.log, 'r', 0)
  if not fd then return false end
  local head = uv.fs_read(fd, 4096, 0)
  uv.fs_close(fd)
  if not head then return false end
  if not head:find('\n', 1, true) then return #head > 0 end
  if not uv.fs_stat(loc.path) then return false end
  local res = log.read(loc.log, 0, 0, seen_lines(loc))
  return res ~= nil and #res.events == 0
end

-- A torn log (see is_torn) is moved aside, to log.jsonl.torn-<unix time>,
-- and the migration (or import) retried
-- Returns: ok (boolean), err (string or nil)
local function recover_torn(loc)
  -- Checked again under the lock, where no write is in flight
  if not is_torn(loc) then return true, nil end
  local got, moved = locked(loc, function()
    if not is_torn(loc) then return nil end
    local aside, n = loc.log .. '.torn-' .. os.time(), 1
    while uv.fs_stat(aside) do
      aside, n = loc.log .. '.torn-' .. os.time() .. '-' .. n, n + 1
    end
    local renamed, rerr = uv.fs_rename(loc.log, aside)
    if not renamed then
      vim.notify(string.format('quickfix-review: %s is incomplete, but could not be moved aside: %s',
        loc.log, tostring(rerr)), vim.log.levels.WARN)
      return nil
    end
    vim.notify(string.format('quickfix-review: %s was incomplete (an interrupted write); moved it to %s',
      loc.log, aside), vim.log.levels.WARN)
    return aside
  end)
  if not got or not moved then return true, nil end
  local ok, err = init_storage(loc)
  return ok, err
end

-- comments.json versions (path:size:mtime) already looked at
local reappeared_seen = {}

-- comments.json next to an existing log: either a migration that crashed
-- before its rename (the log holds an import with its sha256), which is
-- finished now, or something wrote it after the migration (an external tool,
-- an older plugin). That one is not read, and not deleted: warn once.
local function check_reappeared(loc)
  -- The legacy global file is left in place by design (see migrate)
  if is_legacy_global(loc) then return end
  local st = uv.fs_stat(loc.path)
  if not st then return end
  local key = string.format('%s:%d:%d.%d', loc.path, st.size, st.mtime.sec, st.mtime.nsec)
  if reappeared_seen[key] then return end
  reappeared_seen[key] = true
  local raw = read_bytes(loc.path)
  if raw and synced.imports[vim.fn.sha256(raw)] then
    locked(loc, function()
      if uv.fs_stat(loc.path) then uv.fs_rename(loc.path, loc.path .. MIGRATED) end
    end)
    return
  end
  vim.notify(string.format('quickfix-review: %s reappeared next to the review log %s; it is not read'
    .. ' (the log is the review) and is left alone', loc.path, loc.log), vim.log.levels.WARN)
end

-- Log rotation. A log grown past the log_max_bytes option is rotated by the
-- change that grew it, under the lock: the log on disk (not this instance's
-- memory) is replayed, a new log (a header and one checkpoint event holding
-- that state, see reduce.lua) is written beside it, the old log is
-- hard-linked (or copied) to log.<unix ms>.jsonl, and the new one renamed
-- over log.jsonl. So log.jsonl is never missing, nor only a header, for a
-- reader, which never takes the lock. Rotated logs are kept for
-- :ReviewHistory, and deleted after log_retention_days if that is set: the
-- checkpoint holds the trash, so nothing is lost with them.
local DAY_MS = 24 * 60 * 60 * 1000

local function now_ms()
  local sec, usec = uv.gettimeofday()
  return sec * 1000 + math.floor(usec / 1000)
end

-- A positive number option, or `default`
local function positive(v, default)
  if type(v) == 'number' and v > 0 then return v end
  return default
end

-- log.jsonl (or <file>.log.jsonl) as rotated at `ms`: log.<ms>.jsonl
local function rotated_name(loc, ms)
  return (loc.log:gsub('%.jsonl$', '')) .. '.' .. string.format('%d', ms) .. '.jsonl'
end

-- The rotated logs of the review at `loc`, oldest first: { path, ms }...
-- Only this review's: anchored on the log's own name, as several reviews
-- (storage_file) may share a directory
local function list_rotated(loc)
  local dir = vim.fn.fnamemodify(loc.log, ':h')
  local base = vim.fn.fnamemodify(loc.log, ':t'):gsub('%.jsonl$', '')
  local pattern = '^' .. vim.pesc(base) .. '%.(%d+)%.jsonl$'
  local out = {}
  local handle = uv.fs_scandir(dir)
  while handle do
    local name = uv.fs_scandir_next(handle)
    if not name then break end
    local ms = name:match(pattern)
    if ms then table.insert(out, { path = dir .. '/' .. name, ms = tonumber(ms) }) end
  end
  table.sort(out, function(a, b) return a.ms < b.ms end)
  return out
end

-- The rotated logs of the review, oldest first
function M.rotated_logs()
  local out = {}
  for i, r in ipairs(list_rotated(resolve())) do out[i] = r.path end
  return out
end

-- The size of the header and checkpoint a rotated-to log starts with, by
-- log path: { ino (of that log), bytes }. A log is rotated again only once
-- it is larger than twice that, so a checkpoint that alone exceeds
-- log_max_bytes does not rotate on every change.
local head = {}

-- The size above which the log (stat'ed as `stat`) at `loc` is rotated
local function rotate_limit(loc, stat)
  local limit = positive(config.options.log_max_bytes, config.defaults.log_max_bytes)
  local h = head[loc.log]
  if h and h.ino == stat.ino then limit = math.max(limit, 2 * h.bytes) end
  return limit
end

-- A .rotating-<pid> temp file older than this is removed even if its pid is
-- alive (a reused pid)
local STRAY_SECONDS = 10 * 60

-- Remove the .rotating-<pid> temp files of rotations that crashed (their
-- process is gone, or they are old). Call with the lock held.
local function remove_strays(loc)
  local dir = vim.fn.fnamemodify(loc.log, ':h')
  local pattern = '^' .. vim.pesc(vim.fn.fnamemodify(loc.log, ':t')) .. '%.rotating%-(%d+)$'
  local me = uv.os_getpid()
  local handle = uv.fs_scandir(dir)
  while handle do
    local name = uv.fs_scandir_next(handle)
    if not name then break end
    local pid = tonumber(name:match(pattern) or '')
    if pid and pid ~= me then
      local path = dir .. '/' .. name
      local st = uv.fs_stat(path)
      if st and (not log.pid_alive(pid) or os.time() - st.mtime.sec > STRAY_SECONDS) then os.remove(path) end
    end
  end
end

-- Rotate the log at `loc` (see above). Call with the lock held. A failure
-- leaves the log as it was and is only warned about: the change that
-- triggered it is already in the log.
-- Returns: true if the log was rotated
local function rotate(loc)
  local function warn(e)
    vim.notify('quickfix-review: could not rotate ' .. loc.log .. ': ' .. tostring(e), vim.log.levels.WARN)
    return false
  end
  local old = uv.fs_stat(loc.log)
  if not old then return false end
  local res, err = log.read(loc.log, 0, 0, seen_lines(loc))
  if not res then return warn(err) end
  -- Not known yet (another Neovim rotated, or a restart): how large the
  -- log's leading checkpoint is, so it isn't rotated again too soon
  if res.events[1] and res.events[1].op == 'checkpoint' and not (head[loc.log] and head[loc.log].ino == old.ino) then
    local ok, cp = pcall(vim.json.encode, res.events[1])
    local bytes = (ok and #cp or 0) + #vim.json.encode(log.new_header()) + 2
    head[loc.log] = { ino = old.ino, bytes = bytes }
    if old.size <= 2 * bytes then return false end
  end
  local state, imports = reduce.new(), {}
  for _, ev in ipairs(res.events) do
    if ev.op == 'import' and type(ev.source_sha256) == 'string' then imports[ev.source_sha256] = true end
    if ev.op == 'checkpoint' and type(ev.imports) == 'table' then
      for _, sha in ipairs(ev.imports) do
        if type(sha) == 'string' then imports[sha] = true end
      end
    end
    reduce.apply(state, ev)
  end
  local checkpoint = log.event('checkpoint', { state = state, imports = vim.tbl_keys(imports) })

  local mode = bit.band(old.mode, 511)
  local tmp = loc.log .. '.rotating-' .. uv.os_getpid()
  remove_strays(loc)
  os.remove(tmp)
  local wrote, werr = log.append(tmp, { log.new_header(), checkpoint }, mode)
  if not wrote then
    os.remove(tmp)
    return warn(werr)
  end
  uv.fs_chmod(tmp, mode)

  -- Never over an existing rotated log (two rotations in one millisecond)
  local ms = now_ms()
  while uv.fs_stat(rotated_name(loc, ms)) do ms = ms + 1 end
  local rotated = rotated_name(loc, ms)
  local kept, kerr = uv.fs_link(loc.log, rotated)
  if not kept then kept, kerr = uv.fs_copyfile(loc.log, rotated, { excl = true }) end
  if not kept then
    os.remove(tmp)
    os.remove(rotated)
    return warn(kerr)
  end
  local renamed, rerr = uv.fs_rename(tmp, loc.log)
  if not renamed then
    os.remove(tmp)
    os.remove(rotated)
    return warn(rerr)
  end
  local new = uv.fs_stat(loc.log)
  if new then head[loc.log] = { ino = new.ino, bytes = new.size } end
  return true
end

-- Storage paths whose rotated logs have been checked for retention this session
local retention_done = {}

-- Delete the rotated logs older than log_retention_days (by the time in
-- their name), once per review per session. Nothing else is touched.
local function apply_retention(loc)
  local days = positive(config.options.log_retention_days, nil)
  if not days or retention_done[loc.log] then return end
  retention_done[loc.log] = true
  local cutoff = now_ms() - days * DAY_MS
  for _, r in ipairs(list_rotated(loc)) do
    if r.ms < cutoff then os.remove(r.path) end
  end
end

-- Bring the comments up to date with the log (migrating or importing first
-- when there is none). opts.full replays the whole log, ignoring the cache.
-- opts.defer_view refills the quickfix view after the current event rather
-- than now (see refresh_view_later); on_change still runs now.
-- Returns: ok (boolean), err (string or nil)
local function sync(opts)
  opts = opts or {}
  local loc = resolve()
  local changed = false
  local function refresh()
    if opts.defer_view then refresh_view_later() else refresh_view() end
  end
  -- A review that can't be read after a switch (or once its log is gone)
  -- shows nothing, rather than the previous review's comments
  local function fail(err)
    if changed then
      comments = {}
      refresh()
      on_change(comments)
    end
    return refuse(err)
  end
  if synced.log ~= loc.log then
    flush()
    reset(loc)
    changed = true
  end
  local stat = uv.fs_stat(loc.log)
  if not stat or stat.size == 0 then
    -- The log was removed: so is the review
    if synced.log_id then
      reset(loc)
      changed = true
    end
    local ok, err, replaced = init_storage(loc)
    changed = changed or replaced
    if not ok then return fail(err) end
    stat = uv.fs_stat(loc.log)
  elseif readonly then
    -- A log appeared (another Neovim migrated): it is the review now
    reset(loc)
    changed = true
  end
  -- A log not read yet may be one whose first write was torn
  if stat and stat.size > 0 and not synced.log_id then
    local ok, err = recover_torn(loc)
    if not ok then return fail(err) end
    stat = uv.fs_stat(loc.log)
  end
  if stat and stat.size > 0 then
    local ok, err, read_changed = read_log(loc, stat, opts)
    if not ok then return fail(err) end
    changed = changed or read_changed
    -- comments.json is looked at again only once the log changed (or after
    -- a reset): a sync with nothing new costs no stat for it. One that
    -- reappears while the log is idle is noticed at its next change.
    local key = string.format('%s:%d:%d:%d.%d', loc.log, stat.ino, stat.size,
      stat.mtime.sec, stat.mtime.nsec)
    if key ~= reappeared_log_key then
      check_reappeared(loc)
      reappeared_log_key = key
    end
    apply_retention(loc)
  end
  bad_notified = nil
  if changed then
    local list = {}
    for _, r in ipairs(reduced.comments) do
      local c = view_of(r)
      if c then table.insert(list, c) end
    end
    comments = list
    refresh()
    on_change(comments)
  end
  if unsaved >= FLUSH_EVERY then flush() end
  return true
end

-- Append the events build() returns to the log, built against its latest
-- state, all with the log locked. Memory changes only by reading back what
-- was appended, so it never holds a change that isn't on disk. Refuses to
-- change anything if the log (or a comments.json to migrate) is unusable
-- (sync() reports that once) or the lock can't be taken.
-- build() returns: events (a list, possibly empty), result
-- Returns: result, or nil if the change was refused or failed, and then
-- 'partial' as a second value when some, but not all, of it was written
-- The error for a change to a review loaded read-only, or nil
local function readonly_error(loc)
  if not (readonly and readonly.log == loc.log) then return nil end
  return string.format('%s is not writable: %s is shown read-only; the change was not saved', loc.dir, loc.path)
end

-- Snapshot garbage collection. A snapshot is in use while any event of the
-- review's retained logs (the current one and the rotated ones) names it:
-- every comment's and trash entry's anchor comes from those events (the
-- checkpoint a rotated-to log starts with carries both). Each snapshots dir
-- belongs to one log, in every storage mode.
--
-- References are every 64-hex run in the logs' bytes, not decoded events: a
-- torn record stays an undecodable line forever, and an event shape this
-- version doesn't know may still name snapshots, so neither may let its
-- snapshots go. A log that can't be read, or whose header isn't one this
-- version reads, stops the GC.
--
-- Snapshots are written (snapshots.put) before the event naming them is
-- appended, outside the lock, so an unreferenced snapshot may be another
-- Neovim's about to be referenced: only those untouched for GC_GRACE are
-- deleted (put touches an existing one). The lock keeps the set of logs
-- stable against a concurrent rotation.
local GC_GRACE = 24 * 3600
local SHA_RUN = '%f[%x]' .. ('%x'):rep(64) .. '%f[^%x]'

local function gc(loc)
  if readonly_error(loc) then return 0 end
  local dir_stat = uv.fs_stat(loc.snapshots)
  if not dir_stat or dir_stat.type ~= 'directory' or not uv.fs_stat(loc.log) then return 0 end
  local function abort(msg)
    vim.notify('quickfix-review: not collecting snapshots: ' .. msg, vim.log.levels.DEBUG)
    return 0
  end

  local got, removed = locked(loc, function()
    local refs = {}
    local logs = { loc.log }
    for _, r in ipairs(list_rotated(loc)) do table.insert(logs, r.path) end
    for _, path in ipairs(logs) do
      local data = read_bytes(path)
      if not data then return abort('could not read ' .. path) end
      if not log.readable_header(data) then return abort(path .. ' has no header this version reads') end
      for sha in data:gmatch(SHA_RUN) do refs[sha:lower()] = true end
    end

    local count = 0
    local handle = uv.fs_scandir(loc.snapshots)
    while handle do
      local name, kind = uv.fs_scandir_next(handle)
      if not name then break end
      if (kind == 'file' or kind == nil) and #name == 64 and name:match('^[0-9a-f]+$') and not refs[name] then
        -- Stat'ed right before the unlink, narrowing the window for a
        -- concurrent put's touch
        local path = loc.snapshots .. '/' .. name
        local st = uv.fs_stat(path)
        if st and st.type == 'file' and os.time() - st.mtime.sec > GC_GRACE and os.remove(path) then
          count = count + 1
        end
      end
    end
    return count
  end)
  if not got then return abort(tostring(removed)) end
  return removed or 0
end

-- Delete the review's unreferenced snapshots older than a day (see gc).
-- Returns: how many were deleted
function M.gc_snapshots()
  return gc(resolve())
end

-- Collect the snapshots of the review once this session, 5s after startup
-- (not in the test suite, which sets vim.g._quickfix_review_no_startup_gc)
function M.schedule_startup_gc()
  if vim.g._quickfix_review_startup_gc or vim.g._quickfix_review_no_startup_gc then return end
  vim.g._quickfix_review_startup_gc = true
  vim.defer_fn(function()
    local ok, err = pcall(M.gc_snapshots)
    if not ok then vim.notify('quickfix-review: snapshot GC failed: ' .. tostring(err), vim.log.levels.DEBUG) end
  end, 5000)
end

-- opts.defer_view: as for M.all, for every sync the change makes
local function mutate(build, opts)
  local loc = resolve()
  -- Before locking: the lock can't be taken in a dir that is not writable
  if readonly_error(loc) then sync(opts) end
  local ro_err = readonly_error(loc)
  if ro_err then
    vim.notify('quickfix-review: ' .. ro_err, vim.log.levels.ERROR)
    return nil
  end
  local partial = false
  local got, result, err = locked(loc, function()
    if not sync(opts) then return nil end
    local events, res = build()
    if #events == 0 then return res end
    local stat = uv.fs_stat(loc.log)
    local header = (not stat or stat.size == 0) and 1 or 0
    if header == 1 then table.insert(events, 1, log.new_header()) end
    local wrote, werr, landed = log.append(loc.log, events)
    -- Read back what was written: all of it, some or none
    sync(opts)
    local grown = uv.fs_stat(loc.log)
    if wrote and grown and grown.size > rotate_limit(loc, grown) and rotate(loc) then
      -- The new log (another inode) is replayed from its checkpoint, and
      -- the cache keyed to it
      sync(opts)
      flush(true)
      -- Outside this change: it reads every retained log, and takes the lock
      vim.schedule(function() gc(loc) end)
    end
    if wrote then return res end
    landed = (landed or 0) - header
    if landed >= #events - header then
      -- In the log, which is the review: only its fsync (or close) failed
      vim.notify(string.format('quickfix-review: the change was written to %s but may not be durable: %s',
        loc.log, tostring(werr)), vim.log.levels.WARN)
      return res
    end
    if landed > 0 then
      partial = true
      return nil, string.format('Could not write all of the change to %s: %s; the change may be incomplete',
        loc.log, tostring(werr))
    end
    return nil, 'Could not write ' .. loc.log .. ': ' .. tostring(werr)
  end)
  if not got then result, err = nil, result end
  if err then vim.notify('quickfix-review: ' .. err, vim.log.levels.ERROR) end
  if result == nil and partial then return nil, 'partial' end
  return result
end

-- Called after any change to the comments, including ones read from disk
function M.set_on_change(fn)
  on_change = fn
end

-- Called after every refill of the list view with (qf_id, idx before,
-- idx after), so a selection the refill moved isn't taken for navigation
function M.set_on_refill(fn)
  on_refill = fn
end

-- Redraw the quickfix view and call on_change after comments moved (a
-- relocation), without reading or writing the log: positions are never logged.
-- opts.defer_view refills the view after the current event (as for M.all).
function M.refresh(opts)
  if opts and opts.defer_view then refresh_view_later() else refresh_view() end
  on_change(comments)
end

-- All comments, in creation order. Treat as read-only.
-- opts.defer_view: for callers inside a buffer read or enter, where a
-- quickfix jump may be running: a change another Neovim logged refills the
-- list after the event, as refilling during the jump would abort it (E925).
function M.all(opts)
  sync(opts and { defer_view = opts.defer_view } or nil)
  return comments
end

-- Add a comment
-- Returns: true if it was added, false if it has no file or the change was refused
function M.add(item)
  return mutate(function()
    local c = normalize(item)
    if not c then return {}, false end
    return { log.event('add', { comment = storage.serialise(c) }) }, true
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

-- The deleted comments, by id (kept in the log, so they can be restored).
-- Treat as read-only.
function M.trash()
  sync()
  local out = {}
  for id, r in pairs(reduced.trash) do
    out[id] = view_of(r) or r
  end
  return out
end

-- The deleted comments, newest removal first: { id, op ('delete' or
-- 'clear'), ts (unix ms, or nil), comment (its view, or the raw record) }
function M.trash_list()
  sync()
  local out = {}
  for i = #reduced.removed, 1, -1 do
    local e = reduced.removed[i]
    local r = reduced.trash[e.id]
    if r then
      table.insert(out, { id = e.id, op = e.op, ts = e.ts, comment = view_of(r) or r })
    end
  end
  return out
end

-- The most recent removal: { op = 'delete', ids = { id } } for a delete, or
-- { op = 'clear', ids = {...} } holding every comment of the last clear still
-- in the trash; nil when the trash is empty
function M.last_removal()
  sync()
  local last = reduced.removed[#reduced.removed]
  if not last then return nil end
  if last.op ~= 'clear' or last.eid == nil then return { op = last.op, ids = { last.id } } end
  local ids = {}
  for _, e in ipairs(reduced.removed) do
    if e.eid == last.eid and reduced.trash[e.id] then table.insert(ids, e.id) end
  end
  return { op = 'clear', ids = ids }
end

-- Make deleted comments live again: one restore event, holding the logged
-- record, per id in the trash, all in one append. An id that is live, or
-- in neither the review nor the trash, is skipped (nothing is logged for it).
-- Returns: { restored = n, live = { id... }, unknown = { id... } }, or nil
-- if the change was refused
function M.restore(ids)
  return mutate(function()
    local events, res, seen = {}, { restored = 0, live = {}, unknown = {} }, {}
    for _, id in ipairs(ids) do
      local r = reduced.trash[id]
      if seen[id] then
        -- listed twice: restored (or reported) once
      elseif reduce.get(reduced, id) then
        table.insert(res.live, id)
      elseif not r then
        table.insert(res.unknown, id)
      else
        table.insert(events, log.event('restore', { id = id, comment = r }))
      end
      seen[id] = true
    end
    res.restored = #events
    return events, res
  end)
end

-- Whether two anchors name different lines of different content
local function anchor_changed(old, new)
  old = old or {}
  return old.sha ~= new.sha or old.lnum ~= new.lnum or old.end_lnum ~= new.end_lnum
end

-- Re-anchor comments: `changes` is a list of { id = ..., anchor = { sha,
-- lnum, end_lnum, lines, before, after } }. One update event per comment
-- whose anchor actually changes, setting the anchor and the record's
-- top-level lnum/end_lnum to match (never pos, which is derived and kept in
-- memory only), with the previous values in `prev`. A comment that is gone,
-- or an anchor with no snapshot sha, is skipped.
-- opts.defer_view: as for M.all.
-- Returns: number of comments updated, or nil if the change was refused
function M.update(changes, opts)
  return mutate(function()
    local events = {}
    for _, ch in ipairs(changes) do
      local a = parse_anchor(ch.anchor)
      local r = reduce.get(reduced, ch.id)
      if r and a and a.sha and anchor_changed(r.anchor, a) then
        table.insert(events, log.event('update', {
          id = ch.id,
          set = { anchor = a, lnum = a.lnum, end_lnum = a.end_lnum },
          prev = { anchor = r.anchor, lnum = r.lnum, end_lnum = r.end_lnum },
        }))
      end
    end
    return events, #events
  end, opts)
end

-- Change a comment's text: one update event setting its body, with the
-- previous body (as shown, so a legacy record's `text`) in `prev`. Nothing is
-- logged when the comment is gone or the body is unchanged.
-- Returns: 'edited', 'unchanged', 'missing' (no live comment with this id),
-- or nil if the body isn't a non-empty string or the change was refused
function M.edit(id, body)
  if type(body) ~= 'string' or body == '' then return nil end
  return mutate(function()
    local r = reduce.get(reduced, id)
    local c = r and view_of(r)
    if not c then return {}, 'missing' end
    if c.body == body then return {}, 'unchanged' end
    return { log.event('update', { id = id, set = { body = body }, prev = { body = c.body } }) }, 'edited'
  end)
end

-- Remove every comment for which pred(comment) is true: one delete event,
-- holding the comment, per match
-- Returns: number removed, or nil if the change was refused (unreadable file)
-- or failed, and then 'partial' when some of the deletes may have landed
function M.remove_if(pred)
  return mutate(function()
    local events = {}
    for _, r in ipairs(reduced.comments) do
      local c = view_of(r)
      if c and pred(c) then
        table.insert(events, log.event('delete', { id = r.id, comment = r }))
      end
    end
    return events, #events
  end)
end

-- Remove the comment with this id
-- Returns: number removed (0 if there is none), or nil if the change was
-- refused or failed (and 'partial', as for remove_if)
function M.remove(id)
  return M.remove_if(function(c) return c.id == id end)
end

-- Remove every comment (one clear event holding them all)
-- Returns: true, or nil if the change was refused
function M.clear()
  return mutate(function()
    if #reduced.comments == 0 then return {}, true end
    return { log.event('clear', { comments = reduced.comments }) }, true
  end)
end

-- Replay the whole log, ignoring the cache
-- Returns: ok (boolean), message (string)
function M.reload()
  local ok, err = sync({ full = true })
  if not ok then return false, err end
  return true, string.format('Review loaded: %d comments', #comments)
end

-- Write the cache (state.json) now. Every change is already in the log, so
-- this is never needed for the review to be saved.
-- Returns: ok (boolean), message (string)
function M.save()
  local ok, err = sync()
  if not ok then return false, err end
  if readonly then
    return false, string.format('%s is not writable: %s is shown read-only', resolve().dir, resolve().path)
  end
  if not synced.log_id then
    return true, 'Review saved (no comments yet)'
  end
  local wrote, werr = flush(true)
  if not wrote then
    return false, 'Could not write ' .. synced.state .. ': ' .. tostring(werr)
  end
  return true, string.format('Review saved to %s (%d comments)', synced.log, #comments)
end

-- Write the cache if events were applied since it was last written (on exit)
function M.flush()
  flush()
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
