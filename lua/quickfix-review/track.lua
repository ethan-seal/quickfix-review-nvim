-- Where a comment's lines are now. A comment is anchored to a snapshot of
-- the file it was written against (its anchor: sha, lnum, end_lnum); its
-- pos, { sha, lnum, end_lnum, state }, is where those lines are in the file
-- as it is now, with state:
--   current   the lines are where the anchor says, unchanged
--   shifted   the lines are unchanged but moved (lines added/removed above)
--   outdated  a commented line was changed or deleted, or a line was
--             inserted inside the range, or the file or snapshot is missing
-- pos is derived, kept in memory only and never logged: it is recomputed
-- from the anchor, always by diffing the anchor's snapshot against the
-- current content (never through intermediate versions), so an outdated
-- comment keeps its original anchor.
--
-- Loaded buffers of real files are relocated on BufReadPost and
-- FileChangedShellPost; each comment then gets a tracking extmark (namespace
-- quickfix-review-track, never cleared wholesale) that follows in-session
-- edits and becomes invalid when its whole range is deleted. Files not
-- loaded are relocated from disk, cached by (path, size, mtime). Diff
-- buffers (fugitive, diffview, codediff) hold an old revision and are never
-- relocated from.
local M = {}

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
  local snapshots = require('quickfix-review.snapshots')
  local diff = (vim.text and vim.text.diff) or vim.diff
  return diff(snapshots.canonical(old), snapshots.canonical(new), {
    result_type = 'indices',
    algorithm = 'histogram',
    ignore_cr_at_eol = true,
  })
end

local function make_pos(sha, lnum, end_lnum, state)
  return { sha = sha, lnum = lnum, end_lnum = end_lnum, state = state }
end

-- The pos of comment `c` in content `lines` (whose sha is `sha`, computed
-- when nil). A comment with no snapshot sha (from before anchors, or whose
-- snapshot couldn't be saved) stays at its anchor lines, as current. A
-- missing snapshot leaves it at its anchor, outdated.
function M.relocate(c, lines, sha)
  local snapshots = require('quickfix-review.snapshots')
  local a = c.anchor or c
  sha = sha or snapshots.hash(lines)
  if not a.sha then return make_pos(sha, a.lnum, a.end_lnum or a.lnum, 'current') end
  if sha == a.sha then return make_pos(sha, a.lnum, a.end_lnum or a.lnum, 'current') end
  local old = snapshots.get(a.sha)
  if not old then return make_pos(sha, a.lnum, a.end_lnum or a.lnum, 'outdated') end
  local lnum, end_lnum, state = M.map_range(M.diff(old, lines), a.lnum, a.end_lnum or a.lnum)
  return make_pos(sha, lnum, end_lnum, state)
end

-- In-memory state -------------------------------------------------------------

local ns = nil

-- The tracking namespace
function M.ns()
  if not ns then ns = vim.api.nvim_create_namespace('quickfix-review-track') end
  return ns
end

-- Per comment id: { buf, name, mark, pos }, its tracking extmark in a loaded
-- buffer and the pos of its last relocation there
local marks = {}
-- Per buffer: { tick, lines, sha } of its content at changedtick `tick`
local contents = {}
-- Per file path: { size, sec, nsec, lines, sha, pos = { id -> pos } } of an
-- unloaded file, as last read
local files = {}

-- Forget everything (for tests); tracking extmarks are removed
function M._reset()
  for id in pairs(marks) do M.forget(id) end
  marks, contents, files = {}, {}, {}
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
  local sha = require('quickfix-review.snapshots').hash(lines)
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
-- switch to another project's review)
function M.prune(comments)
  local live = {}
  for _, c in ipairs(comments) do live[c.id] = true end
  for id in pairs(marks) do
    if not live[id] then M.forget(id) end
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
    marks[c.id] = { buf = buf, name = vim.api.nvim_buf_get_name(buf), mark = mark, pos = pos }
  else
    marks[c.id] = nil
  end
  return pos
end

-- The position of a tracked comment from its extmark, or nil when it has
-- none (or its buffer was unloaded or renamed)
local function from_mark(c)
  local m = marks[c.id]
  if not m then return nil end
  if not vim.api.nvim_buf_is_loaded(m.buf) or vim.api.nvim_buf_get_name(m.buf) ~= m.name then
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
    -- The whole range was deleted: the line before the gap
    local l = math.max(1, math.min(row + 1, d.end_row or row + 1, count))
    return make_pos(base.sha, l, l, 'outdated')
  end
  local lnum = row + 1
  local end_lnum = math.max(lnum, math.min(d.end_row or lnum, count))
  local state = base.state
  if state ~= 'outdated' then
    local a = c.anchor or c
    state = (lnum == a.lnum and end_lnum == (a.end_lnum or a.lnum)) and 'current' or 'shifted'
  end
  return make_pos(base.sha, lnum, end_lnum, state)
end

-- The pos of `c` in its file on disk, cached by (path, size, mtime). A
-- missing file makes a comment with a snapshot outdated.
local function from_disk(c)
  local path = c.filename
  local st = uv.fs_stat(path)
  if not st or st.type ~= 'file' then
    files[path] = nil
    local a = c.anchor or c
    return make_pos(nil, a.lnum, a.end_lnum or a.lnum, a.sha and 'outdated' or 'current')
  end
  local f = files[path]
  if not f or f.size ~= st.size or f.sec ~= st.mtime.sec or f.nsec ~= st.mtime.nsec then
    local ok, lines = pcall(vim.fn.readfile, path)
    if not ok then lines = {} end
    f = {
      size = st.size, sec = st.mtime.sec, nsec = st.mtime.nsec,
      lines = lines, sha = require('quickfix-review.snapshots').hash(lines), pos = {},
    }
    files[path] = f
  end
  local pos = f.pos[c.id]
  if not pos then
    pos = M.relocate(c, f.lines, f.sha)
    f.pos[c.id] = pos
  end
  return pos
end

-- The pos of comment `c` now (also stored as c.pos). From its tracking
-- extmark in a loaded buffer of its file (relocating and placing one if it
-- has none there yet), else from the file on disk.
function M.pos(c)
  local pos = from_mark(c)
  if not pos then
    local buf = buf_for(c.filename)
    if buf then
      pos = place(c, buf)
    else
      pos = from_disk(c)
    end
  end
  c.pos = make_pos(pos.sha, pos.lnum, pos.end_lnum, pos.state)
  return c.pos
end

-- Relocate every comment in `comments` on the file `buf` holds, from the
-- buffer's content (after it is read or reloaded from disk). Diff buffers
-- and buffers that are not files are left alone.
-- Returns: whether any comment's pos changed
function M.relocate_buffer(buf, comments)
  if not is_real(buf) then return false end
  local file = vim.api.nvim_buf_get_name(buf)
  local changed = false
  for _, c in ipairs(comments) do
    if utils.files_match(c.filename, file) then
      local before = c.pos
      local pos = place(c, buf)
      if not before or before.lnum ~= pos.lnum or before.end_lnum ~= pos.end_lnum
          or before.state ~= pos.state then
        changed = true
      end
      c.pos = make_pos(pos.sha, pos.lnum, pos.end_lnum, pos.state)
    end
  end
  return changed
end

return M
