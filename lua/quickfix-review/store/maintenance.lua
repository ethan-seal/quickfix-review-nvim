-- Keeping the review's storage bounded: snapshot garbage collection, and
-- listing the rotated logs of a v2 review (which its migration to v3 moves
-- into the journal, see store/migrate.lua). Checkpoint GC is in
-- store/checkpoint.lua.
local M = {}

local journal = require('quickfix-review.store.journal')
local location = require('quickfix-review.store.location')
local log = require('quickfix-review.log')
local segment = require('quickfix-review.store.segment')

local uv = vim.uv or vim.loop

-- The rotated logs of the v2 review at `loc` (log.<unix ms>.jsonl, or
-- <file>.log.<ms>.jsonl), oldest first: { path, ms }... Only this review's:
-- anchored on the log's own name, as several reviews (storage_file) may
-- share a directory
function M.list_rotated(loc)
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

-- Snapshot garbage collection. A snapshot is in use while any event of the
-- review's journal names it: every event is kept forever, so every comment's
-- and trash entry's anchor comes from them. Each snapshots dir belongs to
-- one journal, in every storage mode. For a review still in v2 (its log
-- could not be migrated), the events are its log.jsonl's.
--
-- References are every 64-hex run in the segments' bytes, not decoded
-- events: a torn record stays an undecodable line forever, and an event
-- shape this version doesn't know may still name snapshots, so neither may
-- let its snapshots go. A segment that can't be read, or whose header isn't
-- one this version reads, stops the GC; so does a log.jsonl tombstone with
-- no journal beside it.
--
-- Snapshots are written (snapshots.put) before the event naming them is
-- appended, outside the lock, so an unreferenced snapshot may be another
-- Neovim's about to be referenced: only those untouched for GC_GRACE are
-- deleted (put touches an existing one).
--
-- Only the active (highest-numbered) segment is ever written, so the
-- segments are read before taking the lock: holding it through many large
-- reads could make another Neovim's change time out. Under the lock the
-- segments are listed again, and the active one and any new one read.
local GC_GRACE = 24 * 3600
local SHA_RUN = segment.SHA_RUN

function M.gc(loc)
  if journal.readonly_error(loc) then return 0 end
  local dir_stat = uv.fs_stat(loc.snapshots)
  if not dir_stat or dir_stat.type ~= 'directory' then return 0 end
  local function abort(msg)
    vim.notify('quickfix-review: not collecting snapshots: ' .. msg, vim.log.levels.DEBUG)
    return 0
  end
  -- The files holding the review's events: its segments, else its v2 log
  local function sources()
    local segs = segment.list(loc.events)
    local out = {}
    for i, n in ipairs(segs) do out[i] = segment.path(loc.events, n) end
    if #out > 0 then return out end
    local h = log.read_header(loc.log)
    if h and log.is_tombstone(h) then return nil, loc.log .. ' was moved to ' .. loc.events .. ', which is missing' end
    -- A v2 review: its rotated logs, then log.jsonl
    for _, r in ipairs(M.list_rotated(loc)) do table.insert(out, r.path) end
    if uv.fs_stat(loc.log) then table.insert(out, loc.log) end
    return out
  end

  local refs, read = {}, {}
  -- Returns: an error message, or nil once `path`'s references are in refs
  local function collect(path)
    local data = location.read_bytes(path)
    if not data then return 'could not read ' .. path end
    if not log.readable_header(data) then return path .. ' has no header this version reads' end
    for sha in data:gmatch(SHA_RUN) do refs[sha:lower()] = true end
    read[path] = true
  end
  local first, serr = sources()
  if not first then return abort(serr) end
  if #first == 0 then return 0 end
  -- All but the active one, outside the lock
  for i = 1, #first - 1 do
    local err = collect(first[i])
    if err then return abort(err) end
  end

  local got, removed = journal.locked(loc, function()
    local now, err = sources()
    if not now then return abort(err) end
    for i, path in ipairs(now) do
      if not read[path] or i == #now then
        err = collect(path)
        if err then return abort(err) end
      end
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
  return M.gc(location.resolve())
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

return M
