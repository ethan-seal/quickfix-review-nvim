-- A comment record: its identity (new_id), normalizing a record read from
-- disk or given by a caller (normalize, parse_anchor), and how it is placed
-- and displayed (pos, range, headline).
local M = {}

local notify = require('quickfix-review.notify')
local storage = require('quickfix-review.storage')
local track = require('quickfix-review.track')

-- A stable identity for a comment: 16 hex chars from the OS RNG. Not
-- math.random, which LuaJIT leaves unseeded, so every Neovim would produce
-- the same sequence.
function M.new_id()
  local bytes = assert((vim.uv or vim.loop).random(8))
  return (bytes:gsub('.', function(b) return string.format('%02x', b:byte()) end))
end

function M.has_id(item)
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
function M.parse_anchor(a)
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

-- `root` joined with the root-relative `rel`
local function join(root, rel)
  return (root:gsub('/+$', '')) .. '/' .. rel
end

-- The absolute path of a stored filename: a relative one (written by
-- relativize) joined to `root`, the project root of the review it was read
-- from; an absolute one, or a relative one with no root (never written by
-- this plugin: only a hand-edited or foreign record), made absolute by
-- fnamemodify(':p') as before. `rebases` (the review's old project roots,
-- see reduce.lua) apply first: an absolute filename strictly under one of
-- them (the longest that matches) is taken as the same relative path under
-- `root`, so a review adopted from a moved project (store/adopt.lua) shows
-- its comments from before relative filenames where the files are now.
function M.resolve_filename(filename, root, rebases)
  if root and filename:sub(1, 1) ~= '/' then return join(root, filename) end
  if root and rebases and filename:sub(1, 1) == '/' then
    local best
    for _, from in ipairs(rebases) do
      if type(from) == 'string' and filename:sub(1, #from + 1) == from .. '/' and #filename > #from + 1
          and (not best or #from > #best) then
        best = from
      end
    end
    if best then return join(root, filename:sub(#best + 2)) end
  end
  return vim.fn.fnamemodify(filename, ':p')
end

-- The symlink-resolved form of `path`; for a file that no longer exists,
-- its resolved directory joined with its name (nil if that is gone too)
local function resolved_path(path)
  local p = vim.uv.fs_realpath(path)
  if p then return p end
  local dir = vim.uv.fs_realpath(vim.fn.fnamemodify(path, ':h'))
  return dir and join(dir, vim.fn.fnamemodify(path, ':t')) or nil
end

-- The record `c` as it is written to the journal at `loc`: in a
-- per-project dir (loc.per_project, one root per dir), a file under the
-- project root is named relative to it (no './', forward slashes), so the
-- review survives the repo being moved (and adopted, see store/adopt.lua);
-- any other file keeps its absolute name. Returns a shallow copy when it
-- changes the name; `c` itself is never changed.
function M.relativize(c, loc)
  if not (loc and loc.per_project and loc.root) or type(c.filename) ~= 'string' then return c end
  local abs = vim.fn.fnamemodify(c.filename, ':p')
  local p = resolved_path(abs)
  if not p then return c end
  local root = (loc.root:gsub('/+$', ''))
  if p:sub(1, #root + 1) ~= root .. '/' or #p == #root + 1 then return c end
  local out = {}
  for k, v in pairs(c) do out[k] = v end
  out.filename = p:sub(#root + 2)
  return out
end

-- Keep only the fields of a comment record, giving it an id if it has none
-- (comments saved before ids existed). Returns nil for a record that has no
-- file or no valid line number.
-- A relative filename (as record.relativize writes it) is resolved against
-- `root`, the project root of the review it was read from, never the cwd;
-- an absolute one is kept as it is (only made canonical by fnamemodify),
-- unless it is under one of `rebases` (see resolve_filename).
function M.normalize(item, root, rebases)
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

  local id = M.has_id(item) and item.id or M.new_id()
  local context = type(item.context) == 'table' and item.context or nil
  -- inf and NaN (1e999 in JSON) can't be written back: vim.json.encode
  -- refuses them
  if has_nonfinite(extra) or has_nonfinite(context) then
    extra, context = drop_nonfinite(extra), drop_nonfinite(context)
    -- Warned about once per record
    notify.once('nonfinite:' .. id, string.format('dropped infinite or NaN numbers from comment %s', id),
      vim.log.levels.WARN)
  end

  return {
    id = id,
    filename = M.resolve_filename(filename, root, rebases),
    kind = kind and kind:lower() or 'note',
    body = body or '',
    response = response,
    lnum = lnum,
    end_lnum = end_lnum,
    context = context,
    anchor = M.parse_anchor(item.anchor),
    created_at = finite(item.created_at) or os.time(),
    extra = next(extra) ~= nil and extra or nil,
  }
end

-- Where a comment is now, { sha, lnum, end_lnum, state } (see track.lua), or
-- nil for a record not read through the store (no id or anchor)
function M.pos(c)
  if type(c.id) ~= 'string' or type(c.filename) ~= 'string' or type(c.anchor) ~= 'table' then
    return nil
  end
  return track.pos(c)
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

-- A comment as displayed: "[KIND] body", or "[KIND:L1-5] body" for a range.
-- `lnum`, `end_lnum`: its range when the caller already has it (else
-- M.range(c))
function M.headline(c, lnum, end_lnum)
  local label = c.kind:upper()
  if not lnum then lnum, end_lnum = M.range(c) end
  if end_lnum > lnum then
    label = string.format('%s:L%d-%d', label, lnum, end_lnum)
  end
  return '[' .. label .. '] ' .. c.body
end

return M
