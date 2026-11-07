-- Checkpoints of a v3 journal (docs/journal.md#checkpoints): the reduced
-- state as of a position (seg, offset) in the journal, in
-- `checkpoints/<seg>-<offset>.json`. Derived and disposable: any of them
-- may be deleted at any time, and one that is invalid is ignored (and
-- deleted by the next GC). Never the source of truth, so a corrupt or stale
-- one costs time, never data.
--
-- { v = 3, state_v = reduce.STATE_VERSION, journal_id, seg, offset, lines,
--   state = { comments, trash, removed }, imports = { sha... },
--   refs = { sha... }, prefix_sha, sealed = { { size, sha }... } }
-- `lines` is how many lines of segment `seg` precede `offset` (for the
-- line numbers of warnings); `refs` the snapshot hashes the segment names
-- up to `offset`. No index is ever written (reduce.persisted).
--
-- The content hashes tie a checkpoint to the bytes it was built from:
-- `prefix_sha` is the sha256 of segment `seg`'s bytes [0, offset), and
-- `sealed` has one { size, sha } per segment 1 .. seg-1, over its whole
-- file. A segment can be replaced with other bytes behind the same header
-- (a git checkout or merge of an in-repo journal), so load hashes them
-- again every time, whatever the inode or size: a checkpoint without them
-- is rejected ('no content hash'), and one whose bytes differ ('content
-- changed'). Either costs a replay from an older checkpoint, never data.
local M = {}

local log = require('quickfix-review.log')
local reduce = require('quickfix-review.reduce')
local segment = require('quickfix-review.store.segment')

local uv = vim.uv or vim.loop

local JSON_NIL = { luanil = { object = true, array = true } }

function M.name(seg, offset) return string.format('%06d-%012d.json', seg, offset) end

-- The checkpoint files in `dir`, newest (furthest position) first:
-- { path, seg, offset }...; and the paths of temp files (`*.tmp.<pid>`)
function M.list(dir)
  local out, tmps = {}, {}
  local handle = uv.fs_scandir(dir)
  while handle do
    local name = uv.fs_scandir_next(handle)
    if not name then break end
    local seg, offset = name:match('^(%d+)%-(%d+)%.json$')
    if seg then
      table.insert(out, { path = dir .. '/' .. name, seg = tonumber(seg), offset = tonumber(offset) })
    elseif name:match('%.tmp%.%d+$') then
      table.insert(tmps, dir .. '/' .. name)
    end
  end
  table.sort(out, function(a, b)
    if a.seg ~= b.seg then return a.seg > b.seg end
    return a.offset > b.offset
  end)
  return out, tmps
end

local function is_list(t)
  if type(t) ~= 'table' then return false end
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n == #t
end

-- The checkpoint at `path`, decoded and checked against the journal `j`
-- ({ events = dir, journal_id }): the rules of docs/journal.md#checkpoints
-- (v, state_v, journal_id, a position on a line start within its segment,
-- the content hashes of the bytes before it), and a state the reducer
-- accepts. `hashes` (optional) is a cache of sealed segments' { size, sha }
-- taken earlier in the same operation (segment.content_hash), filled as
-- segments are hashed.
-- Returns: { state (reindexed), imports (set), seg, offset, lines, refs
-- (list of hashes, or nil when it has none), sealed (the verified
-- { size, sha } of segments 1 .. seg-1, by number) }, or nil and why it is
-- invalid
function M.load(path, j, hashes)
  local fh = io.open(path, 'rb')
  if not fh then return nil, 'unreadable' end
  local raw = fh:read('*a')
  fh:close()
  local ok, doc = pcall(vim.json.decode, raw, JSON_NIL)
  if not ok or type(doc) ~= 'table' then return nil, 'does not parse' end
  if doc.v ~= 3 then return nil, 'not v3' end
  if doc.state_v ~= reduce.STATE_VERSION then return nil, 'stale state_v' end
  if doc.journal_id ~= j.journal_id then return nil, 'another journal' end
  if type(doc.seg) ~= 'number' or type(doc.offset) ~= 'number' or doc.offset < 1 then return nil, 'no position' end
  local st = uv.fs_stat(segment.path(j.events, doc.seg))
  if not st or doc.offset > st.size then return nil, 'past the end of the journal' end
  if not log.at_line_start(segment.path(j.events, doc.seg), doc.offset) then return nil, 'mid-line' end
  -- The content hashes: the prefix first, then each sealed segment's size
  -- (cheap), then its hash
  if type(doc.prefix_sha) ~= 'string' or not is_list(doc.sealed) or #doc.sealed ~= doc.seg - 1 then
    return nil, 'no content hash'
  end
  for _, e in ipairs(doc.sealed) do
    if type(e) ~= 'table' or type(e.size) ~= 'number' or type(e.sha) ~= 'string' then return nil, 'no content hash' end
  end
  local prefix = segment.read_fd(segment.path(j.events, doc.seg), doc.offset)
  if not prefix or #prefix ~= doc.offset then return nil, 'unreadable segment' end
  if segment.sha(prefix) ~= doc.prefix_sha then return nil, 'content changed' end
  for i, e in ipairs(doc.sealed) do
    local st = uv.fs_stat(segment.path(j.events, i))
    if not st or st.size ~= e.size then return nil, 'content changed' end
  end
  hashes = hashes or {}
  local sealed = {}
  for i, e in ipairs(doc.sealed) do
    local h = segment.content_hash(j.events, i, hashes)
    if not h or h.size ~= e.size or h.sha ~= e.sha then return nil, 'content changed' end
    sealed[i] = { size = e.size, sha = e.sha }
  end
  -- The reducer's own checks of a state: the records are copied, and the
  -- index rebuilt
  local state = reduce.new()
  local ignored = reduce.load_state(state, doc.state)
  if ignored or not is_list(doc.state.comments) or not is_list(doc.state.removed) then return nil, 'bad state' end
  local imports = {}
  for _, sha in ipairs(is_list(doc.imports) and doc.imports or {}) do
    if type(sha) == 'string' then imports[sha] = true end
  end
  local refs
  if is_list(doc.refs) then
    refs = {}
    for _, sha in ipairs(doc.refs) do
      if type(sha) == 'string' and #sha == 64 and sha:match('^%x+$') then table.insert(refs, sha:lower()) end
    end
  end
  return {
    state = state, imports = imports, seg = doc.seg, offset = doc.offset,
    lines = type(doc.lines) == 'number' and doc.lines or 0, refs = refs, sealed = sealed,
  }
end

-- Encode a checkpoint of `state` at (seg, offset) of journal `journal_id`,
-- built from the bytes whose hashes are `prefix_sha` (segment seg's
-- [0, offset)) and `sealed` ({ size, sha } of segments 1 .. seg-1): both
-- required, as a checkpoint without them is never loaded
-- Returns: the JSON, or nil and an error
function M.encode(journal_id, seg, offset, lines, state, imports, refs, prefix_sha, sealed)
  if type(prefix_sha) ~= 'string' or type(sealed) ~= 'table' or #sealed ~= seg - 1 then
    return nil, 'no content hash for the checkpoint'
  end
  local list = {}
  for i = 1, seg - 1 do
    local e = sealed[i]
    if type(e) ~= 'table' or type(e.size) ~= 'number' or type(e.sha) ~= 'string' then
      return nil, 'no content hash of segment ' .. i .. ' for the checkpoint'
    end
    list[i] = { size = e.size, sha = e.sha }
  end
  local ok, encoded = pcall(vim.json.encode, {
    v = 3, state_v = reduce.STATE_VERSION, journal_id = journal_id, seg = seg, offset = offset,
    lines = lines, state = reduce.persisted(state), imports = vim.tbl_keys(imports), refs = refs,
    prefix_sha = prefix_sha, sealed = list,
  })
  if not ok then return nil, 'could not encode the checkpoint' end
  return encoded
end

-- Delete the checkpoints of journal `j` ({ events, journal_id }) in `dir`
-- that are not needed: every temp file (only written under the lock, which
-- the caller holds, so any present is a dead writer's), every invalid one,
-- and the valid ones past the newest `keep`. Call with the lock held. Never
-- touches `events/`.
-- Returns: how many files were deleted
function M.gc(dir, j, keep)
  local list, tmps = M.list(dir)
  local count = 0
  for _, p in ipairs(tmps) do
    if os.remove(p) then count = count + 1 end
  end
  local kept = 0
  -- Each sealed segment hashed at most once in this GC
  local hashes = {}
  for _, cp in ipairs(list) do
    if kept < keep and M.load(cp.path, j, hashes) then
      kept = kept + 1
    elseif os.remove(cp.path) then
      count = count + 1
    end
  end
  return count
end

-- Write checkpoint `encoded` at (seg, offset) into `dir` durably (temp
-- file, fsync, rename, dir fsync), then GC (see gc). Call with the lock
-- held. Two instances writing the same position write the same bytes.
-- Returns: ok, err
function M.write(dir, j, seg, offset, encoded, mode, keep)
  if vim.fn.isdirectory(dir) == 0 then
    local ok = pcall(vim.fn.mkdir, dir, 'p')
    if not ok or vim.fn.isdirectory(dir) == 0 then return false, 'Could not create ' .. dir end
  end
  local ok, err = segment.durable_write(dir .. '/' .. M.name(seg, offset), encoded, mode)
  if not ok then return false, err end
  M.gc(dir, j, keep)
  return true, nil
end

return M
