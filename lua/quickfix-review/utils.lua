-- Utility functions for quickfix-review.nvim
local M = {}
local config = require('quickfix-review.config')

-- Namespace for extmarks (lazy initialized)
local ns_id = nil

-- Get or create the namespace ID
function M.get_ns_id()
  if not ns_id then
    ns_id = vim.api.nvim_create_namespace('quickfix_review')
  end
  return ns_id
end

-- Store sign configuration for extmark use
M.sign_config = {}

-- Get comment types from configuration, in a fixed order (see config.type_order)
function M.get_comment_types()
  return config.type_order(config.options.comment_types)
end

-- Get configuration for a specific comment type
function M.get_comment_type_config(type_name)
  return config.options.comment_types[type_name:lower()]
end

-- Priority map for sign stacking (lower than git signs which typically use 6-10)
-- Generated dynamically based on comment types
function M.get_sign_priority(type_name)
  -- Base priority based on type importance
  local type_config = M.get_comment_type_config(type_name)
  if not type_config then return 50 end
  
  -- Map highlight groups to priorities
  local priority_map = {
    DiagnosticError = 5,
    DiagnosticWarn = 4,
    DiagnosticInfo = 3,
    DiagnosticHint = 2
  }
  
  local base_priority = priority_map[type_config.highlight] or 3
  
  -- Continuation signs get lower priority
  if type_name:find('_continuation$') then
    return 1
  end
  
  return base_priority
end

-- Record the sign configuration used to place extmark signs
function M.init_signs(opts)
  for type_name, sign_def in pairs(opts.signs or {}) do
    M.sign_config[type_name] = sign_def
  end
end

-- Resolved (symlink-free) paths; only hits are cached, so a file created
-- later in the session is still resolved once it exists
local realpath_cache = {}

local function realpath(path)
  local cached = realpath_cache[path]
  if cached then return cached end
  local resolved = vim.uv.fs_realpath(path)
  if resolved then
    realpath_cache[path] = resolved
    return resolved
  end
  return path
end

-- Check if two file paths refer to the same file (symlinks resolved)
function M.files_match(file1, file2)
  if file1 == file2 then return true end
  local abs1 = realpath(vim.fn.fnamemodify(file1, ':p'))
  local abs2 = realpath(vim.fn.fnamemodify(file2, ':p'))
  return abs1 == abs2
end

M.realpath = realpath

-- Whether `path` is `root` or inside it (symlinks resolved on both sides; a
-- path that no longer exists is compared in its absolute form). /repo does
-- not contain /repo2.
function M.is_under(path, root)
  local abs = vim.fn.fnamemodify(path, ':p')
  local p = vim.uv.fs_realpath(abs)
  if not p then
    -- A deleted file: resolve its directory instead, if that still exists
    local dir = vim.uv.fs_realpath(vim.fn.fnamemodify(abs, ':h'))
    p = dir and (dir .. '/' .. vim.fn.fnamemodify(abs, ':t')) or abs
  end
  local r = (realpath(vim.fn.fnamemodify(root, ':p')):gsub('/+$', ''))
  if r == '' then return true end
  return p == r or p:sub(1, #r + 1) == r .. '/'
end

-- Build extmark options helper
local function make_extmark_opts(text, hl_group, prio)
  return {
    sign_text = text,
    sign_hl_group = hl_group,
    priority = prio,
  }
end

-- Refresh all signs for a buffer, showing count when multiple comments overlap
-- This clears and re-renders all signs, consolidating overlapping start/end lines
function M.refresh_buffer_signs(bufnr, file, comments)
  if bufnr <= 0 or vim.fn.bufexists(bufnr) ~= 1 then return end

  -- Clear existing signs
  vim.api.nvim_buf_clear_namespace(bufnr, M.get_ns_id(), 0, -1)

  -- Collect all comments for this file
  -- Track: line -> { count = N, types = {type1, type2, ...}, is_continuation = bool }
  local line_info = {}

  for _, item in ipairs(comments) do
    if M.files_match(item.filename, file) then
      local comment_type = item.kind
      local start_line = item.lnum
      local end_line = item.end_lnum or item.lnum

      -- Track start line
      if not line_info[start_line] then
        line_info[start_line] = { count = 0, types = {}, is_continuation = false }
      end
      line_info[start_line].count = line_info[start_line].count + 1
      table.insert(line_info[start_line].types, comment_type)

      -- Track end line (if different from start)
      if end_line ~= start_line then
        if not line_info[end_line] then
          line_info[end_line] = { count = 0, types = {}, is_continuation = false }
        end
        line_info[end_line].count = line_info[end_line].count + 1
        table.insert(line_info[end_line].types, comment_type)

        -- Track continuation lines (middle lines)
        for line = start_line + 1, end_line - 1 do
          if not line_info[line] then
            line_info[line] = { count = 0, types = {}, is_continuation = true }
          end
          -- Only mark as continuation if not already a start/end line
          if line_info[line].count == 0 then
            line_info[line].is_continuation = true
          end
          table.insert(line_info[line].types, comment_type)
        end
      end
    end
  end

  -- Place signs based on collected info
  local buf_line_count = vim.api.nvim_buf_line_count(bufnr)
  for line, info in pairs(line_info) do
    if line < 1 or line > buf_line_count then goto continue end
    if info.is_continuation and info.count == 0 then
      -- Pure continuation line - show continuation sign for each type
      local seen_types = {}
      for _, comment_type in ipairs(info.types) do
        local type_key = comment_type:lower()
        if not seen_types[type_key] then
          seen_types[type_key] = true
          local cont_cfg = M.sign_config[type_key .. '_continuation']
          if cont_cfg then
            local cont_priority = M.get_sign_priority(type_key .. '_continuation') or 30
            vim.api.nvim_buf_set_extmark(bufnr, M.get_ns_id(), line - 1, 0,
              make_extmark_opts(cont_cfg.text, cont_cfg.texthl, cont_priority))
          end
        end
      end
    elseif info.count > 0 then
      -- Start or end line - show count or symbol
      -- Use highest priority type for the highlight
      local best_type = info.types[1]:lower()
      local best_priority = M.get_sign_priority(best_type) or 0
      for _, t in ipairs(info.types) do
        local p = M.get_sign_priority(t:lower()) or 0
        if p > best_priority then
          best_priority = p
          best_type = t:lower()
        end
      end

      local sign_cfg = M.sign_config[best_type]
      if sign_cfg then
        local sign_text
        if info.count > 1 then
          -- Multiple comments - show count
          sign_text = tostring(info.count)
        else
          -- Single comment - show symbol
          sign_text = sign_cfg.text
        end

        vim.api.nvim_buf_set_extmark(bufnr, M.get_ns_id(), line - 1, 0,
          make_extmark_opts(sign_text, sign_cfg.texthl, best_priority))
      end
    end
    ::continue::
  end
end

-- git toplevel per directory; false marks "not in a git repo" so misses are cached too
local toplevel_cache = {}

-- Return the git toplevel containing `dir` (a file path uses its directory),
-- or nil outside git. Results are cached per argument for the session.
function M.git_toplevel(dir)
  if not dir or dir == '' then return nil end
  local cached = toplevel_cache[dir]
  if cached ~= nil then return cached or nil end

  local query = dir
  if vim.fn.isdirectory(query) == 0 then
    query = vim.fn.fnamemodify(query, ':h')
  end

  local root = false
  local ok, result = pcall(function()
    return vim.system({ 'git', '-C', query, 'rev-parse', '--show-toplevel' }, { text = true }):wait(1000)
  end)
  if ok and result and result.code == 0 and result.stdout then
    local trimmed = vim.trim(result.stdout)
    if trimmed ~= '' then root = trimmed end
  end

  toplevel_cache[dir] = root
  return root or nil
end

-- Resolve `rel` against the repo containing `root` (or cwd when root is nil)
local function resolve_repo_path(root, rel)
  local base
  if root and root ~= '' then
    base = M.git_toplevel(root) or root
  else
    local cwd = vim.fn.getcwd()
    base = M.git_toplevel(cwd) or cwd
  end
  return base .. '/' .. rel
end

-- Extract real file path from special diff buffers. Regular buffers (and names
-- matching no known scheme) return the buffer name unchanged.
function M.get_real_filepath(bufnr)
  local bufname = vim.api.nvim_buf_get_name(bufnr or 0)

  -- diffview:///repo/.git/<rev>/file.txt (also tolerates .git//<rev>/)
  local root, rel = bufname:match('^diffview://(.-)/%.git/+[^/]+/(.+)$')
  if rel then
    return resolve_repo_path(root, rel)
  end

  -- fugitive:///repo/.git//<rev>/file.txt
  root, rel = bufname:match('^fugitive://(.-)/%.git//[^/]+/(.+)$')
  if rel then
    return resolve_repo_path(root, rel)
  end

  -- codediff buffers carry a repo-relative path with no repo root
  local codediff_match = bufname:match('codediff://+(.+)')
  if codediff_match then
    local clean_path = codediff_match:match('//:[^/]+/(.*)')
      or codediff_match:match('/+([^/].*)')
    if clean_path then
      return resolve_repo_path(nil, clean_path)
    end
  end

  return bufname
end

-- Check if a buffer (default: current) is a diff/special buffer
function M.is_special_buffer(bufnr)
  local bufname = vim.api.nvim_buf_get_name(bufnr or 0)
  return bufname:match('^diffview://')
      or bufname:match('^fugitive://')
      or bufname:match('^codediff://')
end

return M
