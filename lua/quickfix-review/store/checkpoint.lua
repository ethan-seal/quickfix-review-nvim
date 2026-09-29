-- Checkpoints of a v3 journal (docs/journal.md#checkpoints): the reduced
-- state as of a position (seg, offset) in the journal, in
-- `checkpoints/<seg>-<offset>.json`. Derived and disposable: any of them
-- may be deleted at any time, and one that is invalid is ignored (and
-- deleted by the next GC). Never the source of truth, so a corrupt or stale
-- one costs time, never data.
--
-- { v = 3, state_v = reduce.STATE_VERSION, journal_id, seg, offset, lines,
--   state = { comments, trash, removed }, imports = { sha... },
--   refs = { sha... } }
-- `lines` is how many lines of segment `seg` precede `offset` (for the
-- line numbers of warnings); `refs` the snapshot hashes the segment names
-- up to `offset`. No index is ever written (reduce.persisted).
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
-- (v, state_v, journal_id, a position on a line start within its segment),
-- and a state the reducer accepts.
-- Returns: { state (reindexed), imports (set), seg, offset, lines }, or nil
-- and why it is invalid
function M.load(path, j)
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
  -- The reducer's own checks of a state (the checkpoint event's handler):
  -- the records are copied, and the index rebuilt
  local state = reduce.new()
  local _, ignored = reduce.apply(state, { op = 'checkpoint', state = doc.state })
  if ignored or not is_list(doc.state.comments) or not is_list(doc.state.removed) then return nil, 'bad state' end
  local imports = {}
  for _, sha in ipairs(is_list(doc.imports) and doc.imports or {}) do
    if type(sha) == 'string' then imports[sha] = true end
  end
  return {
    state = state, imports = imports, seg = doc.seg, offset = doc.offset,
    lines = type(doc.lines) == 'number' and doc.lines or 0,
  }
end

-- Encode a checkpoint of `state` at (seg, offset) of journal `journal_id`
-- Returns: the JSON, or nil and an error
function M.encode(journal_id, seg, offset, lines, state, imports, refs)
  local ok, encoded = pcall(vim.json.encode, {
    v = 3, state_v = reduce.STATE_VERSION, journal_id = journal_id, seg = seg, offset = offset,
    lines = lines, state = reduce.persisted(state), imports = vim.tbl_keys(imports), refs = refs,
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
  for _, cp in ipairs(list) do
    if kept < keep and M.load(cp.path, j) then
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
