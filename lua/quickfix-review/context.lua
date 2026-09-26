-- Capture commit + diff snippet at comment-creation time so reviews remain
-- meaningful even if the commit is later rebased away or garbage-collected.
local M = {}

local utils = require('quickfix-review.utils')

local GIT_TIMEOUT_MS = 2000
local SNIPPET_PAD = 3

-- Run git in `dir` (argv form: no shell quoting, no shell rc). Returns stdout
-- lines, or nil on non-zero exit, timeout, or failure to spawn.
local function git(dir, args)
  local cmd = { 'git', '-C', dir }
  vim.list_extend(cmd, args)
  local ok, result = pcall(function()
    return vim.system(cmd, { text = true, timeout = GIT_TIMEOUT_MS }):wait()
  end)
  if not ok or not result or result.code ~= 0 or not result.stdout then return nil end
  local out = vim.split(result.stdout, '\n', { plain = true })
  if out[#out] == '' then table.remove(out) end
  return out
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

local function diff_hunk(toplevel, rel, lnum, base)
  local diff = git(toplevel, { 'diff', '--no-color', '--unified=3', base, '--', rel })
  if not diff or #diff == 0 then return nil end
  local h = find_hunk_for_line(parse_hunks(diff), lnum)
  return h and h.lines or nil
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

-- Capture git context for `file` (absolute or cwd-relative) lines
-- start_line..end_line. `bufnr` is the buffer the comment is made from
-- (default: current). git runs in the file's own repo, never nvim's cwd;
-- any git failure leaves the commit fields nil and uses the buffer snippet.
function M.capture(file, start_line, end_line, bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local buffer_modified = vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].modified or false

  local abs = vim.fn.fnamemodify(file, ':p')
  local toplevel = utils.git_toplevel(abs)

  local commit, snippet
  if toplevel then
    local head = git(toplevel, { 'rev-parse', 'HEAD' })
    commit = head and head[1] ~= '' and head[1] or nil

    -- The diff is against the file on disk; with unsaved edits its line
    -- numbers would not match the commented buffer lines.
    local rel = repo_relative(toplevel, abs)
    if rel and not buffer_modified then
      snippet = diff_hunk(toplevel, rel, start_line, 'HEAD~1')
             or diff_hunk(toplevel, rel, start_line, 'HEAD')
    end
  end

  local ctx = {
    commit = commit,
    commit_short = commit and commit:sub(1, 8) or nil,
    snippet = snippet or buffer_snippet(bufnr, start_line, end_line),
    snippet_source = snippet and 'diff' or 'buffer',
  }
  if buffer_modified then ctx.buffer_modified = true end
  return ctx
end

return M
