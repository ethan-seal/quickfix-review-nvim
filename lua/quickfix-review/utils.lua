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
  M.init_highlights()
end

-- Define the plugin's highlight groups (default links, so a user's own
-- definition wins). Called again on ColorScheme, which clears them.
function M.init_highlights()
  -- The sign highlight of a comment whose code changed since it was made
  vim.api.nvim_set_hl(0, M.OUTDATED_HL, { link = 'DiagnosticWarn', default = true })
end

-- Highlight group for the signs of outdated comments
M.OUTDATED_HL = 'QuickfixReviewOutdated'

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

-- The absolute, symlink-resolved form of `p`: two paths name the same file
-- when their keys are equal (see files_match)
function M.path_key(p)
  return realpath(vim.fn.fnamemodify(p, ':p'))
end

-- Check if two file paths refer to the same file (symlinks resolved)
function M.files_match(file1, file2)
  return file1 == file2 or M.path_key(file1) == M.path_key(file2)
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
-- This clears and re-renders all signs, consolidating overlapping start/end lines.
-- Positions come from store.range (the tracking extmarks, see track.lua);
-- only this sign namespace is cleared. A line with an outdated comment gets
-- the QuickfixReviewOutdated highlight.
function M.refresh_buffer_signs(bufnr, file, comments)
  if bufnr <= 0 or vim.fn.bufexists(bufnr) ~= 1 then return end

  -- Clear existing signs
  vim.api.nvim_buf_clear_namespace(bufnr, M.get_ns_id(), 0, -1)

  -- Collect all comments for this file
  -- Track: line -> { count = N, types = {type1, type2, ...}, is_continuation = bool }
  local line_info = {}

  -- Required here: store requires utils
  local store = require('quickfix-review.store')
  local special = M.is_special_buffer(bufnr)
  for _, item in ipairs(comments) do
    local start_line, end_line
    if M.files_match(item.filename, file) then
      start_line, end_line = M.range_in(item, bufnr)
    end
    if start_line then
      local comment_type = item.kind
      -- A diff buffer shows a comment only where it holds the comment's
      -- snapshot, so it is never outdated there
      local outdated = not special and store.is_outdated(item)

      -- Track start line
      if not line_info[start_line] then
        line_info[start_line] = { count = 0, types = {}, is_continuation = false }
      end
      line_info[start_line].count = line_info[start_line].count + 1
      line_info[start_line].outdated = line_info[start_line].outdated or outdated
      table.insert(line_info[start_line].types, comment_type)

      -- Track end line (if different from start)
      if end_line ~= start_line then
        if not line_info[end_line] then
          line_info[end_line] = { count = 0, types = {}, is_continuation = false }
        end
        line_info[end_line].count = line_info[end_line].count + 1
        line_info[end_line].outdated = line_info[end_line].outdated or outdated
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
          line_info[line].outdated = line_info[line].outdated or outdated
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
              make_extmark_opts(cont_cfg.text, info.outdated and M.OUTDATED_HL or cont_cfg.texthl, cont_priority))
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
          -- Sign text is at most 2 cells, so clamp large counts
          sign_text = info.count > 9 and '9+' or tostring(info.count)
        else
          -- Single comment - show symbol
          sign_text = sign_cfg.text
        end

        vim.api.nvim_buf_set_extmark(bufnr, M.get_ns_id(), line - 1, 0,
          make_extmark_opts(sign_text, info.outdated and M.OUTDATED_HL or sign_cfg.texthl, best_priority))
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
    return vim.system({ 'git', '-C', query, 'rev-parse', '--show-toplevel' }, { text = true, timeout = 1000 }):wait()
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

-- work tree per git dir; false marks "could not resolve" so misses are cached too
local worktree_cache = {}

-- The work tree a git dir belongs to. Diff plugins name buffers after the git
-- dir, which for a linked worktree (.git/worktrees/<n>) or a submodule
-- (.git/modules/<n>) is not inside the work tree.
local function worktree_of(gitdir)
  local cached = worktree_cache[gitdir]
  if cached ~= nil then return cached or nil end

  local tree = false
  local prefix = gitdir:match('^(.-)/%.git$')
  if prefix then
    -- The main repo's own .git: its parent (resolved as before)
    -- (an empty prefix resolves against the cwd, which is not cached here)
    tree = prefix ~= '' and (M.git_toplevel(prefix) or prefix) or false
  elseif vim.fn.filereadable(gitdir .. '/gitdir') == 1 then
    -- Linked worktree: <gitdir>/gitdir holds the path of <worktree>/.git
    local ok, lines = pcall(vim.fn.readfile, gitdir .. '/gitdir', '', 1)
    if ok and lines[1] and vim.trim(lines[1]) ~= '' then
      tree = vim.fn.fnamemodify(vim.trim(lines[1]), ':h')
    end
  elseif vim.fn.isdirectory(gitdir) == 1 then
    -- Submodule (core.worktree set in its git dir)
    local ok, result = pcall(function()
      return vim.system({ 'git', '-C', gitdir, 'rev-parse', '--show-toplevel' }, { text = true, timeout = 1000 }):wait()
    end)
    if ok and result and result.code == 0 and result.stdout then
      local trimmed = vim.trim(result.stdout)
      if trimmed ~= '' then tree = trimmed end
    end
  end
  if not tree then
    -- Last resort: the directory holding the first .git
    tree = gitdir:match('^(.-)/%.git/') or false
  end

  worktree_cache[gitdir] = tree
  return tree or nil
end

-- Resolve `rel` inside the work tree of `gitdir`
local function resolve_gitdir_path(gitdir, rel)
  local tree = worktree_of(gitdir)
  if tree then return tree .. '/' .. rel end
  return resolve_repo_path(nil, rel)
end

-- Extract real file path from special diff buffers. Regular buffers (and names
-- matching no known scheme) return the buffer name unchanged.
function M.get_real_filepath(bufnr)
  local bufname = vim.api.nvim_buf_get_name(bufnr or 0)

  -- diffview:///repo/.git/<rev>/file.txt (also tolerates .git//<rev>/); the
  -- git dir may be a linked worktree's (.git/worktrees/<n>) or a submodule's
  -- (.git/modules/<n>, possibly nested)
  local gitdir, rest = bufname:match('^diffview://(.-/%.git)/+(.+)$')
  if rest then
    local seg, tail = rest:match('^(worktrees/[^/]+)/+(.+)$')
    if seg then
      gitdir, rest = gitdir .. '/' .. seg, tail
    else
      seg, tail = rest:match('^(modules/[^/]+)/+(.+)$')
      while seg do
        gitdir, rest = gitdir .. '/' .. seg, tail
        seg, tail = rest:match('^(modules/[^/]+)/+(.+)$')
      end
    end
    local rel = rest:match('^[^/]+/+(.+)$')
    if rel then
      return resolve_gitdir_path(gitdir, rel)
    end
  end

  -- fugitive:///repo/.git//<rev>/file.txt (the git dir, then //)
  local gd, rel = bufname:match('^fugitive://(.-)//[^/]+/(.+)$')
  if rel and gd:find('/%.git') then
    return resolve_gitdir_path(gd, rel)
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

-- Per diff buffer: { name, tick, sha } of its content at changedtick `tick`
local special_sha = {}

-- Drop what is cached for buffer `bufnr` (on BufWipeout)
function M.forget_buffer(bufnr)
  special_sha[bufnr] = nil
end

-- The lines comment `item` covers in buffer `bufnr`. In a file's own buffer:
-- store.range (where its anchor's lines are now). In a diff buffer showing a
-- revision (fugitive, diffview): its anchor's lines when that buffer holds
-- exactly the anchor's snapshot, else nil (the comment is not shown there).
-- Returns: lnum, end_lnum, or nil
function M.range_in(item, bufnr)
  -- Required here: store requires utils
  local store = require('quickfix-review.store')
  if not M.is_special_buffer(bufnr) then return store.range(item) end
  local a = item.anchor or item
  if not a.sha or not vim.api.nvim_buf_is_loaded(bufnr) then return nil end
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  local cached = special_sha[bufnr]
  if not cached or cached.tick ~= tick or cached.name ~= name then
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    cached = { name = name, tick = tick, sha = require('quickfix-review.snapshots').hash(lines) }
    special_sha[bufnr] = cached
  end
  if cached.sha ~= a.sha then return nil end
  local lnum = a.lnum or item.lnum
  return lnum, a.end_lnum or lnum
end

-- True when `path` (from get_real_filepath) still carries a diff plugin's
-- scheme, i.e. the buffer name did not map to a file
function M.is_unresolved(path)
  return path:match('^diffview://') ~= nil
      or path:match('^fugitive://') ~= nil
      or path:match('^codediff://') ~= nil
end

-- Check if a buffer (default: current) is a diff/special buffer
function M.is_special_buffer(bufnr)
  local bufname = vim.api.nvim_buf_get_name(bufnr or 0)
  return bufname:match('^diffview://')
      or bufname:match('^fugitive://')
      or bufname:match('^codediff://')
end

return M
