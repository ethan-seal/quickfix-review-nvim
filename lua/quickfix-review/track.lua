-- Where a comment's lines are now. A comment is anchored to a snapshot of
-- the file it was written against (its anchor: sha, lnum, end_lnum); its
-- pos, { sha, lnum, end_lnum, state }, is where those lines are in the file
-- as it is now, with state:
--   current   the lines are where the anchor says, unchanged
--   shifted   the lines are unchanged but moved (lines added/removed above)
--   outdated  a commented line was changed or deleted, or a line was
--             inserted inside the range, or the file is missing
-- pos is derived, kept in memory only and never logged: it is recomputed
-- from the anchor, always by diffing the anchor's snapshot against the
-- current content (never through intermediate versions), so an outdated
-- comment keeps its original anchor. When the snapshot is missing, the
-- anchor's own lines are searched for instead (M.search).
--
-- Loaded buffers of real files are relocated on BufReadPost and
-- FileChangedShellPost; each comment then gets a tracking extmark (namespace
-- quickfix-review-track, never cleared wholesale) that follows in-session
-- edits and becomes invalid when its whole range is deleted. Files not
-- loaded are relocated from disk, read once per (path, size, mtime).
-- This module is the single source of truth for positions: one cache
-- (`cache`, keyed by file and by the buffer's changedtick or the file's
-- stat, and per comment by its anchor, so a changed anchor from a
-- re-anchor or another instance's synced update is relocated afresh)
-- serves M.pos and M.positions, which signs, the quickfix view, the float
-- and export all read. Every caller gets a fresh table. Diff
-- buffers (fugitive, diffview, codediff) hold an old revision and are never
-- relocated from.
local M = {}

local snapshots = require('quickfix-review.snapshots')
local utils = require('quickfix-review.utils')

local uv = vim.uv or vim.loop

-- Pure core ------------------------------------------------------------------

-- Map line L of the old file through `hunks` ({ sa, ca, sb, cb } in
-- vim.diff 'indices' form: a start is 1-based when its count is >= 1, and
-- the line after which the change sits when its count is 0).
-- Returns: the new line, and whether L itself was changed or deleted
function M.map_line(hunks, L)
  local delta = 0
  for _, h in ipairs(hunks) do
    local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
    if (ca == 0 and L <= sa) or (ca > 0 and L < sa) then return L + delta, false end
    if ca > 0 and L < sa + ca then
      -- L itself changed or was deleted
      if cb > 0 then return sb + math.min(L - sa, cb - 1), true end
      -- Deleted: the line before the gap (or 1)
      return math.max(sb, 1), true
    end
    delta = (cb == 0 and sb + 1 or sb + cb) - (ca == 0 and sa + 1 or sa + ca)
  end
  return L + delta, false
end

-- Map the range lnum..end_lnum of the old file through `hunks`. The range is
-- outdated if a hunk that changes or deletes old lines overlaps it, or a pure
-- insertion lies strictly inside it; insertions and deletions next to its
-- edges don't count. A range deleted whole collapses to one line.
-- Returns: lnum, end_lnum, state ('current', 'shifted' or 'outdated')
function M.map_range(hunks, lnum, end_lnum)
  local s = M.map_line(hunks, lnum)
  local e = M.map_line(hunks, end_lnum)
  if e < s then e = s end

  local outdated = false
  for _, h in ipairs(hunks) do
    local sa, ca = h[1], h[2]
    if ca > 0 then
      if sa <= end_lnum and sa + ca - 1 >= lnum then outdated = true end
    elseif lnum <= sa and sa < end_lnum then
      outdated = true
    end
  end

  if outdated then return s, e, 'outdated' end
  if s ~= lnum or e ~= end_lnum then return s, e, 'shifted' end
  return s, e, 'current'
end

-- The hunks turning `old` into `new` (lists of lines), compared in the
-- snapshots' canonical form, so CR line endings and a missing final newline
-- never make a difference. vim.text.diff on 0.11+, vim.diff on 0.10.
function M.diff(old, new)
  local diff = (vim.text and vim.text.diff) or vim.diff
  return diff(snapshots.canonical(old), snapshots.canonical(new), {
    result_type = 'indices',
    algorithm = 'histogram',
  })
end

local function make_pos(sha, lnum, end_lnum, state)
  return { sha = sha, lnum = lnum, end_lnum = end_lnum, state = state }
end

-- What a comment's pos is computed from: its anchor's sha and lines. A
-- cached pos (a tracking extmark's, or an unloaded file's) is reused only
-- while this is unchanged, so an anchor changed by :ReviewReanchor, a save,
-- or another instance's synced update is relocated afresh.
local function anchor_key(c)
  local a = c.anchor or c
  return tostring(a.sha) .. ':' .. tostring(a.lnum) .. ':' .. tostring(a.end_lnum or a.lnum)
end

-- How far from the anchor's line the fallback search looks
local SEARCH_WINDOW = 200

-- A line as compared by the search: without a trailing CR, and with a NUL
-- as "\n" (NVIM 0.12's nvim_buf_get_lines gives a NUL as "\0", readfile()
-- and older buffers as "\n"; a stored anchor line may hold either)
local function norm(line) return (line:gsub('%z', '\n'):gsub('\r+$', '')) end

-- `list` with every line normalised (see norm)
local function norm_all(list)
  local out = {}
  for i, l in ipairs(list) do out[i] = norm(l) end
  return out
end

-- Whether a line says too little to identify a block by itself (`end`, `}`,
-- blank): at most 4 characters once trimmed, or no letters or digits
local function trivial(line)
  local t = vim.trim(line)
  return #t <= 4 or not t:find('%w')
end

-- Where the anchor's block is in `lines` when its snapshot is missing: the
-- places within SEARCH_WINDOW lines of anchor.lnum holding exactly
-- anchor.lines, ranked by how many of the anchor.before/after context lines
-- still surround them, then by nearness to anchor.lnum. A unique best place
-- is 'current' (same lines) or 'shifted'. No place, a tie, or a block of
-- only trivial lines found in several places with no context to tell them
-- apart is 'outdated', at the anchor's lines clamped to the file.
-- Returns: lnum, end_lnum, state
function M.search(lines, anchor)
  local lnum = anchor.lnum
  local end_lnum = math.max(anchor.end_lnum or lnum, lnum)
  local span = end_lnum - lnum
  local block = norm_all(anchor.lines or {})
  local before, after = norm_all(anchor.before or {}), norm_all(anchor.after or {})
  local n = #block

  local function outdated()
    local count = math.max(#lines, 1)
    local l = math.max(1, math.min(lnum, count))
    return l, math.max(l, math.min(end_lnum, count)), 'outdated'
  end
  if n == 0 then return outdated() end

  local function at(i) return lines[i] and norm(lines[i]) end
  -- The block is whole (not truncated) only when it covers the range; only
  -- then does `after` directly follow it
  local whole = n == span + 1

  -- Every place holding the block, with its context score
  local found = {}
  for s = math.max(1, lnum - SEARCH_WINDOW), math.min(#lines - n + 1, lnum + SEARCH_WINDOW) do
    local match = true
    for k = 1, n do
      if at(s + k - 1) ~= block[k] then match = false break end
    end
    if match then
      local score = 0
      for k = 1, #before do
        if at(s - (#before - k + 1)) == before[k] then score = score + 1 end
      end
      if whole then
        for k = 1, #after do
          if at(s + n - 1 + k) == after[k] then score = score + 1 end
        end
      end
      table.insert(found, { s = s, score = score, dist = math.abs(s - lnum) })
    end
  end
  if #found == 0 then return outdated() end

  table.sort(found, function(x, y)
    if x.score ~= y.score then return x.score > y.score end
    return x.dist < y.dist
  end)
  local best, second = found[1], found[2]
  if second and second.score == best.score then
    -- Context can't tell them apart: nearness decides, unless it ties too or
    -- the block is only trivial lines, which say nothing on their own
    local all_trivial = true
    for _, l in ipairs(block) do
      if not trivial(l) then all_trivial = false break end
    end
    if all_trivial or second.dist == best.dist then return outdated() end
  end

  local new_end = math.max(best.s, math.min(best.s + span, #lines))
  local state = (best.s == lnum and new_end == end_lnum) and 'current' or 'shifted'
  return best.s, new_end, state
end

-- The diff hunks from a snapshot to a content, keyed by
-- '<snapshot sha>:<content sha>'. Hunks depend only on the two contents, so
-- entries never go stale; comments sharing an anchor sha share one diff.
-- Bounded: wiped when HUNKS_MAX entries are held.
local hunks = {}
local HUNKS_MAX = 16
local hunks_count = 0

-- The pos of comment `c` in content `lines` (whose sha is `sha`, computed
-- when nil). A comment with no snapshot sha (from before anchors, or whose
-- snapshot couldn't be saved) stays at its anchor lines, as current. When
-- its snapshot is missing or corrupt, its lines are searched for (M.search).
function M.relocate(c, lines, sha)
  local a = c.anchor or c
  sha = sha or snapshots.hash(lines)
  if not a.sha then return make_pos(sha, a.lnum, a.end_lnum or a.lnum, 'current') end
  if sha == a.sha then return make_pos(sha, a.lnum, a.end_lnum or a.lnum, 'current') end
  local key = a.sha .. ':' .. sha
  local h = hunks[key]
  if not h then
    local old = snapshots.get(a.sha)
    if not old then
      local lnum, end_lnum, state = M.search(lines, a)
      return make_pos(sha, lnum, end_lnum, state)
    end
    h = M.diff(old, lines)
    if hunks_count >= HUNKS_MAX then hunks, hunks_count = {}, 0 end
    hunks[key] = h
    hunks_count = hunks_count + 1
  end
  local lnum, end_lnum, state = M.map_range(h, a.lnum, a.end_lnum or a.lnum)
  return make_pos(sha, lnum, end_lnum, state)
end

-- In-memory state -------------------------------------------------------------

local ns = nil

-- The tracking namespace
function M.ns()
  if not ns then ns = vim.api.nvim_create_namespace('quickfix-review-track') end
  return ns
end

-- Per comment id: { buf, name, mark, pos, key }, its tracking extmark in a
-- loaded buffer, the pos of its last relocation there, and the anchor_key
-- it was relocated from
local marks = {}
-- Per buffer: { tick, lines, sha } of its content at changedtick `tick`
local contents = {}
-- Per file path: { size, sec, nsec, ino, used, lines, sha } of an unloaded
-- file, as last read. At most FILES_MAX are kept; the least recently used
-- (lowest `used`) is dropped to make room.
local files = {}
local FILES_MAX = 32
local files_count, files_clock = 0, 0
-- The one cache of comment positions, the single source of truth for where
-- a comment is now. Per utils.path_key of a file: { stamp, ids = { id ->
-- { key, pos } } }. `stamp` names the content the positions were computed
-- on: 'b<buf>:<changedtick>' for a loaded buffer holding the file, else
-- 's<size>:<sec>:<nsec>:<ino>' for the file on disk, or 'missing'. An entry
-- whose stamp no longer matches is dropped whole. Each pos is kept with the
-- anchor_key it was computed from, so a changed anchor (which changes no
-- stamp) is relocated afresh. Nothing outside this module holds a pos: every
-- reader is handed a fresh copy.
local cache = {}
-- Inside M.batch: its depth and the buffer map ({ exact = name -> buf,
-- bykey = path_key -> buf }, built on first use)
local batch_depth, batch_bufs = 0, nil
-- utils.path_key of each absolute filename whose path resolved, so a
-- position read costs no fnamemodify or realpath. Only absolute names (a
-- relative one depends on the cwd, and :lcd/:tcd fire no handler that could
-- clear it) and only resolved ones (a path under a missing file or
-- directory may resolve elsewhere once it exists). Cleared by forget_paths.
local path_memo = {}

-- The comments on a file, by its utils.path_key (store.view.in_file, which
-- registers itself when it loads: the store sits above track, see set_in_file)
local in_file_fn = nil

-- Set the function positions gets a file's comments from (called by
-- store/view.lua when it loads)
function M.set_in_file(fn)
  in_file_fn = fn
end

-- Forget everything (for tests); tracking extmarks are removed
function M._reset()
  for id in pairs(marks) do M.forget(id) end
  marks, contents, files, cache = {}, {}, {}, {}
  files_count, files_clock = 0, 0
  hunks, hunks_count = {}, 0
  batch_depth, batch_bufs = 0, nil
  path_memo = {}
end

-- The utils.path_key of `f`, memoised (see path_memo)
local function key_of(f)
  local k = path_memo[f]
  if k then return k end
  local resolved
  k, resolved = utils.resolved_key(f)
  if resolved and f:sub(1, 1) == '/' then path_memo[f] = k end
  return k
end

-- Forget the memoised path keys (after the cwd changes, or a buffer is
-- wiped out)
function M.forget_paths()
  path_memo = {}
end

-- The number of memoised path keys (for tests)
function M._path_memo_size()
  local n = 0
  for _ in pairs(path_memo) do n = n + 1 end
  return n
end

-- Forget the cached content of `buf` (when it is wiped out), and the
-- positions computed on it
function M.forget_buffer(buf)
  M.forget_paths()
  contents[buf] = nil
  local prefix = 'b' .. buf .. ':'
  for key, e in pairs(cache) do
    if e.stamp:sub(1, #prefix) == prefix then cache[key] = nil end
  end
end

-- Whether the content of `buf` is cached (for tests)
function M._has_contents(buf) return contents[buf] ~= nil end

-- Run fn(...) as a batch: until it returns, buffers are looked up in a map
-- built once. Only for loops that read positions and never add, remove or
-- rename a buffer. Reentrant.
-- Returns: fn's results (an error is raised again)
function M.batch(fn, ...)
  batch_depth = batch_depth + 1
  local res = vim.F.pack_len(pcall(fn, ...))
  batch_depth = batch_depth - 1
  if batch_depth == 0 then batch_bufs = nil end
  if not res[1] then error(res[2], 0) end
  return unpack(res, 2, res.n)
end

-- The number of cached unloaded files (for tests)
function M._files_count() return files_count end

-- Drop the cache entry of `path`, if any
local function drop_file(path)
  if files[path] then
    files[path] = nil
    files_count = files_count - 1
  end
end

-- Cache `f` as `path`'s entry, evicting the least recently used entry
-- when the cache is full
local function store_file(path, f)
  if not files[path] then
    if files_count >= FILES_MAX then
      local oldest, oldest_used
      for p, e in pairs(files) do
        if not oldest_used or e.used < oldest_used then oldest, oldest_used = p, e.used end
      end
      drop_file(oldest)
    end
    files_count = files_count + 1
  end
  files[path] = f
end

-- Whether `buf` is a loaded buffer holding a real file (not a diff buffer)
local function is_real(buf)
  return vim.api.nvim_buf_is_loaded(buf)
    and vim.bo[buf].buftype == ''
    and not utils.is_special_buffer(buf)
    and vim.api.nvim_buf_get_name(buf) ~= ''
end

-- The loaded real buffer holding `file`, or nil
local function buf_for(file)
  if batch_depth > 0 then
    if not batch_bufs then
      batch_bufs = { exact = {}, bykey = {} }
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if is_real(buf) then
          local name = vim.api.nvim_buf_get_name(buf)
          if not batch_bufs.exact[name] then batch_bufs.exact[name] = buf end
          local key = key_of(name)
          if not batch_bufs.bykey[key] then batch_bufs.bykey[key] = buf end
        end
      end
    end
    return batch_bufs.exact[file] or batch_bufs.bykey[key_of(file)]
  end
  local fallback
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local name = vim.api.nvim_buf_get_name(buf)
      if name == file and is_real(buf) then return buf end
      if not fallback and name ~= '' and is_real(buf) and utils.files_match(name, file) then
        fallback = buf
      end
    end
  end
  return fallback
end

-- The lines and sha of `buf`, cached by changedtick
local function content_of(buf)
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local cached = contents[buf]
  if cached and cached.tick == tick then return cached.lines, cached.sha end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local sha = snapshots.hash(lines)
  contents[buf] = { tick = tick, lines = lines, sha = sha }
  return lines, sha
end

-- Remove comment `id`'s tracking extmark and forget its position
function M.forget(id)
  local m = marks[id]
  if m then
    if vim.api.nvim_buf_is_valid(m.buf) then pcall(vim.api.nvim_buf_del_extmark, m.buf, M.ns(), m.mark) end
    marks[id] = nil
  end
end

-- Forget every comment not in `comments` (after a delete, a clear, or a
-- switch to another project's review): its tracking extmark and its cached
-- position
function M.prune(comments)
  local live = {}
  for _, c in ipairs(comments) do live[c.id] = true end
  for id in pairs(marks) do
    if not live[id] then M.forget(id) end
  end
  for key, e in pairs(cache) do
    for id in pairs(e.ids) do
      if not live[id] then e.ids[id] = nil end
    end
    if next(e.ids) == nil then cache[key] = nil end
  end
end

-- Relocate `c` in loaded buffer `buf` and place (or move) its tracking
-- extmark there. A range past the end of the buffer (a comment with no
-- snapshot, on lines the file no longer has) gets no extmark.
-- Returns: its pos
local function place(c, buf)
  local lines, sha = content_of(buf)
  local pos = M.relocate(c, lines, sha)
  local m = marks[c.id]
  if pos.end_lnum > #lines or #lines == 0 then
    if m then M.forget(c.id) end
    return pos
  end
  local opts = {
    end_row = pos.end_lnum, end_col = 0, strict = false,
    invalidate = true, end_right_gravity = false,
  }
  if m and m.buf == buf then opts.id = m.mark
  elseif m then M.forget(c.id) end
  local ok, mark = pcall(vim.api.nvim_buf_set_extmark, buf, M.ns(), pos.lnum - 1, 0, opts)
  if ok then
    marks[c.id] = {
      buf = buf, name = vim.api.nvim_buf_get_name(buf), mark = mark, pos = pos, key = anchor_key(c),
    }
  else
    marks[c.id] = nil
  end
  return pos
end

-- The position of a tracked comment from its extmark, or nil when it has
-- none (or its buffer was unloaded or renamed, or its anchor changed since
-- the extmark was placed)
local function from_mark(c)
  local m = marks[c.id]
  if not m then return nil end
  if not vim.api.nvim_buf_is_loaded(m.buf) or vim.api.nvim_buf_get_name(m.buf) ~= m.name
      or m.key ~= anchor_key(c) then
    M.forget(c.id)
    return nil
  end
  local ok, got = pcall(vim.api.nvim_buf_get_extmark_by_id, m.buf, M.ns(), m.mark, { details = true })
  if not ok or not got[1] then
    marks[c.id] = nil
    return nil
  end
  local row, d = got[1], got[3] or {}
  local count = vim.api.nvim_buf_line_count(m.buf)
  local base = m.pos
  if d.invalid then
    -- Every line of the range was replaced or deleted. With a snapshot,
    -- diff the buffer's content against it again: a whole-buffer replace
    -- such as :%!fmt may leave the lines as they were, and then the mark
    -- is forgotten so place() makes a new one. When the diff says outdated
    -- (the range really was deleted), the invalid mark is kept so an undo
    -- revalidates it and m.pos gives current/shifted again. Without a
    -- snapshot, the line before the gap.
    if (c.anchor or c).sha then
      local lines, sha = content_of(m.buf)
      local pos = M.relocate(c, lines, sha)
      if pos.state ~= 'outdated' then
        M.forget(c.id)
        return place(c, m.buf)
      end
      return pos
    end
    local l = math.max(1, math.min(row + 1, d.end_row or row + 1, count))
    return make_pos(base.sha, l, l, 'outdated')
  end
  local lnum = row + 1
  local end_lnum = math.max(lnum, math.min(d.end_row or lnum, count))
  local state = base.state
  if state ~= 'outdated' then
    local a = c.anchor or c
    if a.sha and end_lnum - lnum ~= (base.end_lnum or base.lnum) - base.lnum then
      -- A valid mark whose span changed had lines deleted or inserted
      -- inside the range. A comment with no sha has nothing to be outdated
      -- against, so it follows its mark and a save re-anchors it there.
      state = 'outdated'
    else
      state = (lnum == a.lnum and end_lnum == (a.end_lnum or a.lnum)) and 'current' or 'shifted'
    end
  end
  return make_pos(base.sha, lnum, end_lnum, state)
end

-- Whether `s` passes the UTF-8 test Neovim runs when it reads a file: each
-- lead byte gives a sequence length (0xC0-0xDF 2, 0xE0-0xEF 3, 0xF0-0xF7 4,
-- 0xF8-0xFB 5, 0xFC-0xFD 6; a stray continuation byte or 0xFE/0xFF fails)
-- and that many bytes must follow as continuation bytes. Overlong forms,
-- surrogates and code points past U+10FFFF pass, as they do for Neovim, and
-- so does a sequence cut off by the end of `s`, so `s` must end where the
-- file does. Returns nil when `s` fails, else the number of bytes of such a
-- cut-off sequence (0 when there is none), which Neovim reads as illegal
-- bytes and replaces each with '?'.
local function utf8_tail(s)
  local i = 1
  while true do
    local p = s:find('[\128-\255]', i)
    if not p then return 0 end
    local b, len = s:byte(p), nil
    if b >= 0xC0 and b <= 0xDF then len = 2
    elseif b >= 0xE0 and b <= 0xEF then len = 3
    elseif b >= 0xF0 and b <= 0xF7 then len = 4
    elseif b >= 0xF8 and b <= 0xFB then len = 5
    elseif b >= 0xFC and b <= 0xFD then len = 6
    else return nil end
    for k = 1, len - 1 do
      local cb = s:byte(p + k)
      if not cb then return k end
      if cb < 0x80 or cb > 0xBF then return nil end
    end
    i = p + len
  end
end

-- `lines` as readfile() gives them, converted to UTF-8 the way reading the
-- file into a buffer does: the first encoding of 'fileencodings' that
-- takes them (utf-8, and 'default', which is 'encoding', when they are
-- valid UTF-8, with a sequence cut off by the end of the file replaced by
-- '?'s; any other through iconv). So a file read as latin1 hashes
-- alike loaded and from disk. When none takes them they are kept as they
-- are, as a buffer keeps them. ('ucs-bom' is skipped: readfile() drops a
-- UTF-8 BOM and a UTF-16/32 file is not handled.) `ends_nl`: whether the
-- file ends in a newline, which readfile() drops.
local function decode(lines, ends_nl)
  local checked, tail = false, nil
  for enc in vim.gsplit(vim.o.fileencodings, ',', { plain = true, trimempty = true }) do
    enc = enc:lower()
    if enc == 'utf-8' or enc == 'utf8' or enc == 'default' then
      if not checked then
        checked = true
        tail = utf8_tail(table.concat(lines, '\n') .. (ends_nl and '\n' or ''))
      end
      if tail == 0 then return lines end
      if tail then
        -- Not followed by a newline, so the cut-off bytes end the last line
        local out, n = vim.list_slice(lines), #lines
        out[n] = out[n]:sub(1, -tail - 1) .. ('?'):rep(tail)
        return out
      end
    elseif enc ~= 'ucs-bom' then
      local out = {}
      for i, l in ipairs(lines) do
        local u = vim.iconv(l, enc, 'utf-8')
        if not u then out = nil; break end
        out[i] = u
      end
      if out then return out end
    end
  end
  return lines
end

-- Whether the file at `path`, `size` bytes long, ends in a newline.
local function ends_in_newline(path, size)
  if size == 0 then return false end
  local fd = uv.fs_open(path, 'r', 0)
  if not fd then return false end
  local last = uv.fs_read(fd, 1, size - 1)
  uv.fs_close(fd)
  return last == '\n'
end

-- The pos of `c` in its file on disk (`st`, its fs_stat, or nil when it
-- is missing), whose content is cached by (path, size, mtime, inode).
-- A missing file makes a comment with a snapshot outdated.
local function from_disk(c, st)
  local path = c.filename
  if not st or st.type ~= 'file' then
    drop_file(path)
    local a = c.anchor or c
    return make_pos(nil, a.lnum, a.end_lnum or a.lnum, a.sha and 'outdated' or 'current')
  end
  local f = files[path]
  if not f or f.size ~= st.size or f.sec ~= st.mtime.sec or f.nsec ~= st.mtime.nsec
      or f.ino ~= st.ino then
    local ok, lines = pcall(vim.fn.readfile, path)
    lines = ok and decode(lines, ends_in_newline(path, st.size)) or {}
    f = {
      size = st.size, sec = st.mtime.sec, nsec = st.mtime.nsec, ino = st.ino,
      lines = lines, sha = snapshots.hash(lines),
    }
    store_file(path, f)
  end
  files_clock = files_clock + 1
  f.used = files_clock
  return M.relocate(c, f.lines, f.sha)
end

-- The loaded buffer holding `c`'s tracking extmark, when it still holds
-- the file the extmark was placed in
local function mark_buf(c)
  local m = marks[c.id]
  if m and vim.api.nvim_buf_is_loaded(m.buf) and vim.api.nvim_buf_get_name(m.buf) == m.name then
    return m.buf
  end
  return nil
end

-- What a comment on `file` with no tracking extmark in a loaded buffer is
-- computed on now: the loaded buffer holding the file, else the file on disk.
-- Returns: stamp (see `cache`), buf or nil, fs_stat or nil
local function file_source(file)
  local buf = buf_for(file)
  if buf then
    return 'b' .. buf .. ':' .. vim.api.nvim_buf_get_changedtick(buf), buf, nil
  end
  local st = uv.fs_stat(file)
  if not st or st.type ~= 'file' then return 'missing', nil, nil end
  return string.format('s%d:%d:%d:%d', st.size, st.mtime.sec, st.mtime.nsec, st.ino), nil, st
end

-- What `c`'s position is computed on now: the loaded buffer holding its
-- file (the one its tracking extmark is in, if any), else the file on disk.
-- Returns: stamp (see `cache`), buf or nil, fs_stat or nil
local function source_of(c)
  local buf = mark_buf(c)
  if buf then
    return 'b' .. buf .. ':' .. vim.api.nvim_buf_get_changedtick(buf), buf, nil
  end
  return file_source(c.filename)
end

-- The cache entry of `path_key` for `stamp`, emptied when its stamp is
-- another's
local function entry(path_key, stamp)
  local e = cache[path_key]
  if not e or e.stamp ~= stamp then
    e = { stamp = stamp, ids = {} }
    cache[path_key] = e
  end
  return e
end

local function copy(p) return make_pos(p.sha, p.lnum, p.end_lnum, p.state) end

-- M.pos, given what `c`'s position is computed on (stamp, buf and st, as
-- source_of returns them) and `path_key`, the utils.path_key of its file
local function pos_at(c, path_key, stamp, buf, st)
  local e = entry(path_key, stamp)
  local key = anchor_key(c)
  local hit = e.ids[c.id]
  if hit and hit.key == key then return copy(hit.pos) end
  local pos = from_mark(c)
  if not pos then
    if buf then
      pos = place(c, buf)
    else
      pos = from_disk(c, st)
    end
  end
  e.ids[c.id] = { key = key, pos = copy(pos) }
  return copy(pos)
end

-- The pos of comment `c` now, a fresh table. Read from the position cache
-- while the content it was computed on and the comment's anchor are
-- unchanged; else from its tracking extmark in a loaded buffer of its file
-- (relocating and placing one if it has none there yet), else from the
-- file on disk.
function M.pos(c)
  return pos_at(c, key_of(c.filename), source_of(c))
end

-- Where every live comment on a file is now: `target` is a buffer number
-- (its file, see utils.get_real_filepath) or a file path.
-- Returns: a fresh { [comment id] = { sha, lnum, end_lnum, state } }
function M.positions(target)
  local name = type(target) == 'number' and utils.get_real_filepath(target) or target
  if type(name) ~= 'string' or name == '' then return {} end
  local path_key = key_of(name)
  local in_file = in_file_fn(path_key)
  local out = {}
  M.batch(function()
    -- The source of each filename's comments (the same for all of them but
    -- those with a tracking extmark), computed once for this call only: the
    -- content may change before the next
    local sources = {}
    for _, c in ipairs(in_file) do
      if mark_buf(c) then
        out[c.id] = pos_at(c, path_key, source_of(c))
      else
        local src = sources[c.filename]
        if not src then
          src = { file_source(c.filename) }
          sources[c.filename] = src
        end
        out[c.id] = pos_at(c, path_key, src[1], src[2], src[3])
      end
    end
  end)
  return out
end

-- Relocate every comment in `comments` on the file `buf` holds, from the
-- buffer's content (after it is read, reloaded from disk, or saved). Diff
-- buffers and buffers that are not files are left alone.
-- Returns: whether any comment's pos changed from the last one computed
-- (from its anchor, when none was)
function M.relocate_buffer(buf, comments)
  if not is_real(buf) then return false end
  local file = vim.api.nvim_buf_get_name(buf)
  local path_key = utils.path_key(file)
  local stamp = 'b' .. buf .. ':' .. vim.api.nvim_buf_get_changedtick(buf)
  -- Every comment's last pos, read before the entry is replaced below
  local mine, before = {}, {}
  local old = cache[path_key]
  for _, c in ipairs(comments) do
    if utils.files_match(c.filename, file) then
      table.insert(mine, c)
      local hit = old and old.ids[c.id]
      if hit and hit.key == anchor_key(c) then
        before[c.id] = hit.pos
      else
        local a = c.anchor or c
        before[c.id] = make_pos(a.sha, a.lnum, a.end_lnum or a.lnum, 'current')
      end
    end
  end
  local e = entry(path_key, stamp)
  local changed = false
  for _, c in ipairs(mine) do
    local b = before[c.id]
    local pos = place(c, buf)
    if b.lnum ~= pos.lnum or b.end_lnum ~= pos.end_lnum or b.state ~= pos.state then
      changed = true
    end
    e.ids[c.id] = { key = anchor_key(c), pos = copy(pos) }
  end
  return changed
end

return M
