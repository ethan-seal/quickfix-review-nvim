-- Capture commit + diff snippet at comment-creation time so reviews remain
-- meaningful even if the commit is later rebased away or garbage-collected.
local M = {}

local function git(args)
  local out = vim.fn.systemlist('git ' .. args)
  return out, vim.v.shell_error
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

local function diff_hunk(file, lnum, base)
  local cmd = 'diff --no-color --unified=3 ' .. base .. ' -- ' .. vim.fn.shellescape(file)
  local diff, code = git(cmd)
  if code ~= 0 or #diff == 0 then return nil end
  local h = find_hunk_for_line(parse_hunks(diff), lnum)
  return h and h.lines or nil
end

local function file_snippet(file, start_line, end_line)
  local pad = 3
  local from = math.max(1, start_line - pad)
  local to = end_line + pad
  local ok, lines = pcall(vim.fn.readfile, file)
  if not ok then return { '<unable to read file>' } end
  local snippet = {}
  for i = from, math.min(to, #lines) do
    table.insert(snippet, string.format('%4d  %s', i, lines[i]))
  end
  if #snippet == 0 then table.insert(snippet, '<no content>') end
  return snippet
end

function M.capture(file, start_line, end_line)
  local commit_out, code = git('rev-parse HEAD')
  local commit = (code == 0) and commit_out[1] or nil

  local snippet = diff_hunk(file, start_line, 'HEAD~1')
                or diff_hunk(file, start_line, 'HEAD')
                or file_snippet(file, start_line, end_line)

  return {
    commit = commit,
    commit_short = commit and commit:sub(1, 8) or nil,
    snippet = snippet,
  }
end

return M
