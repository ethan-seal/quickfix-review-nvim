-- Capture commit + diff snippet at comment-creation time so reviews remain
-- meaningful even if the commit is later rebased away or garbage-collected.
local M = {}

local snapshots = require('quickfix-review.snapshots')
local utils = require('quickfix-review.utils')

local GIT_TIMEOUT_MS = 2000
local SNIPPET_PAD = 3

-- stdout lines of a finished git, or nil on non-zero exit or timeout
local function git_lines(result)
  if not result or result.code ~= 0 or not result.stdout then return nil end
  local out = vim.split(result.stdout, '\n', { plain = true })
  if out[#out] == '' then table.remove(out) end
  return out
end

-- Run git in `dir` (argv form: no shell quoting, no shell rc). Returns stdout
-- lines, or nil on non-zero exit, timeout, or failure to spawn. `env` is
-- merged into the inherited environment. With `on_done`, git runs in the
-- background and on_done(lines or nil) is called on the main loop once it
-- exits (straight away when it can't be spawned); nothing is returned.
local function git(dir, args, env, on_done)
  local cmd = { 'git', '-C', dir }
  vim.list_extend(cmd, args)
  local opts = { text = true, timeout = GIT_TIMEOUT_MS, env = env }
  if on_done then
    local ok = pcall(vim.system, cmd, opts, function(result)
      vim.schedule(function() on_done(git_lines(result)) end)
    end)
    if not ok then vim.schedule(function() on_done(nil) end) end
    return
  end
  local ok, result = pcall(function() return vim.system(cmd, opts):wait() end)
  if not ok then return nil end
  return git_lines(result)
end

local function parse_hunks(diff_lines)
  local hunks, current = {}, nil
  for _, line in ipairs(diff_lines) do
    if line:sub(1, 2) == '@@' then
      local s, c = line:match('^@@ %-%d+,?%d* %+(%d+),?(%d*) @@')
      if s then
        local count = (c == '' or c == nil) and 1 or tonumber(c)
        current = { new_start = tonumber(s), new_count = count, lines = { line } }
        table.insert(hunks, current)
      end
    elseif current then
      local first = line:sub(1, 1)
      if first == '+' or first == '-' or first == ' ' or first == '\\' then
        table.insert(current.lines, line)
      end
    end
  end
  return hunks
end

local function find_hunk_for_line(hunks, lnum)
  for _, h in ipairs(hunks) do
    local last = h.new_start + (h.new_count or 1) - 1
    if lnum >= h.new_start and lnum <= last then return h end
  end
  return nil
end

M._parse_hunks = parse_hunks
M._find_hunk_for_line = find_hunk_for_line

-- The lines of the hunk covering `lnum` in a diff, or nil
local function hunk_for(diff, lnum)
  if not diff or #diff == 0 then return nil end
  local h = find_hunk_for_line(parse_hunks(diff), lnum)
  return h and h.lines or nil
end

-- Literal pathspecs so a path with glob characters (app/[id]/page.tsx)
-- matches only itself, not siblings like app/d/page.tsx. Set by env rather
-- than ':(literal)', which a user's GIT_LITERAL_PATHSPECS=1 would take as
-- part of the file name.
local function diff_args(rel, base)
  return { 'diff', '--no-color', '--unified=3', base, '--', rel }, { GIT_LITERAL_PATHSPECS = '1' }
end

local function diff_hunk(toplevel, rel, lnum, base)
  local args, env = diff_args(rel, base)
  return hunk_for(git(toplevel, args, env), lnum)
end

-- As diff_hunk, in the background: on_done(lines or nil) on the main loop
local function diff_hunk_async(toplevel, rel, lnum, base, on_done)
  local args, env = diff_args(rel, base)
  git(toplevel, args, env, function(diff) on_done(hunk_for(diff, lnum)) end)
end

-- Snippet from the commenting buffer, so it always matches the commented
-- lines even when the buffer has unsaved edits.
local function buffer_snippet(bufnr, start_line, end_line)
  if not vim.api.nvim_buf_is_valid(bufnr) then return { '<unable to read buffer>' } end
  local from = math.max(1, start_line - SNIPPET_PAD)
  local to = math.min(end_line + SNIPPET_PAD, vim.api.nvim_buf_line_count(bufnr))
  local snippet = {}
  if from <= to then
    local lines = vim.api.nvim_buf_get_lines(bufnr, from - 1, to, false)
    for i, line in ipairs(lines) do
      table.insert(snippet, string.format('%4d  %s', from + i - 1, line))
    end
  end
  if #snippet == 0 then table.insert(snippet, '<no content>') end
  return snippet
end

-- Path of `abs` relative to `toplevel`, comparing real paths (git reports a
-- symlink-resolved toplevel). nil when the file is not under it.
local function repo_relative(toplevel, abs)
  local dir = vim.fn.fnamemodify(abs, ':h')
  local real_dir = vim.uv.fs_realpath(dir) or dir
  local real = real_dir .. '/' .. vim.fn.fnamemodify(abs, ':t')
  local prefix = toplevel:gsub('/$', '') .. '/'
  if real:sub(1, #prefix) ~= prefix then return nil end
  return real:sub(#prefix + 1)
end

-- What capture needs before git runs: the file's repo (toplevel, nil
-- outside git), its path in it when a diff snippet is wanted (rel, nil
-- otherwise), and the context without git (the buffer snippet)
local function prepare(file, start_line, end_line, bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local buffer_modified = vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].modified or false

  local abs = vim.fn.fnamemodify(file, ':p')
  local toplevel = utils.git_toplevel(abs)

  -- The diff is against the file on disk; with unsaved edits, or in a
  -- diffview/fugitive buffer showing another revision, its line numbers
  -- would not match the commented buffer lines.
  local rel
  if toplevel and not buffer_modified and not utils.is_special_buffer(bufnr) then
    rel = repo_relative(toplevel, abs)
  end

  local base = {
    snippet = buffer_snippet(bufnr, start_line, end_line),
    snippet_source = 'buffer',
  }
  if buffer_modified then base.buffer_modified = true end
  return toplevel, rel, base
end

-- `base` with what git found: the HEAD lines (head, or nil) and the diff
-- snippet (or nil)
local function with_git(base, head, snippet)
  local ctx = vim.deepcopy(base)
  local commit = head and head[1] ~= '' and head[1] or nil
  ctx.commit = commit
  ctx.commit_short = commit and commit:sub(1, 8) or nil
  if snippet then ctx.snippet, ctx.snippet_source = snippet, 'diff' end
  return ctx
end

-- Capture git context for `file` (absolute or cwd-relative) lines
-- start_line..end_line. `bufnr` is the buffer the comment is made from
-- (default: current). git runs in the file's own repo, never nvim's cwd;
-- any git failure leaves the commit fields nil and uses the buffer snippet.
function M.capture(file, start_line, end_line, bufnr)
  local toplevel, rel, base = prepare(file, start_line, end_line, bufnr)
  if not toplevel then return base end
  local head = git(toplevel, { 'rev-parse', 'HEAD' })
  local snippet
  if rel then
    snippet = diff_hunk(toplevel, rel, start_line, 'HEAD~1')
           or diff_hunk(toplevel, rel, start_line, 'HEAD')
  end
  return with_git(base, head, snippet)
end

-- As capture, without waiting for git: returns the context without git
-- (the buffer snippet) now, and runs git in the background (only the file's
-- toplevel, cached per file, is asked for synchronously). Once git is done,
-- on_git(ctx) is called on the main loop with the full context, only when
-- git found a commit or a diff snippet; it may never be called (outside
-- git, or when git fails). The background part uses only the file path,
-- never the buffer, which may be gone by then.
function M.capture_async(file, start_line, end_line, bufnr, on_git)
  local toplevel, rel, base = prepare(file, start_line, end_line, bufnr)
  if not toplevel then return base end
  local function finish(head, snippet)
    local ctx = with_git(base, head, snippet)
    if ctx.commit or snippet then on_git(ctx) end
  end
  git(toplevel, { 'rev-parse', 'HEAD' }, nil, function(head)
    if not rel then return finish(head, nil) end
    diff_hunk_async(toplevel, rel, start_line, 'HEAD~1', function(snippet)
      if snippet then return finish(head, snippet) end
      diff_hunk_async(toplevel, rel, start_line, 'HEAD', function(s) finish(head, s) end)
    end)
  end)
  return base
end

-- Lines first..last of `all` (clamped to it), each without a trailing CR,
-- as in a snapshot's canonical form
local function slice(all, first, last)
  local out = {}
  for i = math.max(1, first), math.min(#all, last) do
    table.insert(out, (all[i]:gsub('\r+$', '')))
  end
  return out
end

-- The anchor of a comment on lines start_line..end_line of `bufnr` (default:
-- current): a snapshot of the buffer's content as it is now (unsaved edits
-- included; for a diff buffer, the revision the reviewer saw) and the lines
-- relative to it, with the commented lines (at most ANCHOR_MAX_LINES) and up
-- to ANCHOR_PAD lines either side for a fallback search. If the snapshot
-- can't be saved this warns and the anchor has no sha. `pre`, when given, is
-- { lines, sha }: the buffer's content already read and saved as a snapshot
-- by the caller (anchoring several comments to one content hashes it once).
local ANCHOR_MAX_LINES = 50
local ANCHOR_PAD = 2

function M.anchor(start_line, end_line, bufnr, pre)
  local all, sha
  if pre then
    all, sha = pre.lines, pre.sha
  else
    bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
    all = vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_lines(bufnr, 0, -1, false) or {}

    local err
    sha, err = snapshots.put(all)
    if not sha then
      vim.notify('quickfix-review: snapshot not saved, the comment is anchored by its lines only: '
        .. tostring(err), vim.log.levels.WARN)
    end
  end

  return {
    sha = sha,
    lnum = start_line,
    end_lnum = end_line,
    lines = slice(all, start_line, math.min(end_line, start_line + ANCHOR_MAX_LINES - 1)),
    before = slice(all, start_line - ANCHOR_PAD, start_line - 1),
    after = slice(all, end_line + 1, end_line + ANCHOR_PAD),
  }
end

return M
