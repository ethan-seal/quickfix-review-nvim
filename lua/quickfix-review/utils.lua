-- Utility functions for quickfix-review.nvim
local M = {}
local config = require('quickfix-review.config')

-- What utils needs from the layers above it (it is a leaf, so it cannot
-- require them): { range, is_outdated, hash }, set by store.lua when it loads
-- (see bind_store)
local hooks = {}

-- Set the store functions refresh_buffer_signs and range_in use: range and
-- is_outdated (store.range, store.is_outdated) and hash (snapshots.hash)
function M.bind_store(h)
  hooks = h
end

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

-- The resolved form of `path`, and whether it resolved (else `path` itself)
local function resolve(path)
  local cached = realpath_cache[path]
  if cached then return cached, true end
  local resolved = vim.uv.fs_realpath(path)
  if resolved then
    realpath_cache[path] = resolved
    return resolved, true
  end
  return path, false
end

local function realpath(path)
  return (resolve(path))
end

-- The absolute, symlink-resolved form of `p`: two paths name the same file
-- when their keys are equal (see files_match)
function M.path_key(p)
  return (resolve(vim.fn.fnamemodify(p, ':p')))
end

-- path_key(p), and whether it resolved (false when the file or a directory
-- on its path is missing, so the key may change once it exists)
function M.resolved_key(p)
  return resolve(vim.fn.fnamemodify(p, ':p'))
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
-- Positions come from `positions` when given (track.positions(file), read
-- once for the whole file), else from store.range per comment (the tracking
-- extmarks, see track.lua); a diff buffer never reads `positions`. Only this
-- sign namespace is cleared. A line with an outdated comment gets the
-- QuickfixReviewOutdated highlight.
function M.refresh_buffer_signs(bufnr, file, comments, positions)
  if bufnr <= 0 or vim.fn.bufexists(bufnr) ~= 1 then return end

  -- Clear existing signs
  vim.api.nvim_buf_clear_namespace(bufnr, M.get_ns_id(), 0, -1)

  -- Collect all comments for this file
  -- Track: line -> { count = N, types = {type1, type2, ...}, is_continuation = bool }
  local line_info = {}

  local special = M.is_special_buffer(bufnr)
  if special then positions = nil end
  for _, item in ipairs(comments) do
    local start_line, end_line, outdated
    -- A comment in `positions` is on this file (it lists only those)
    local p = positions and positions[item.id]
    if p then
      -- As store.range reads a pos
      start_line = p.lnum or item.lnum
      end_line = p.end_lnum or start_line
      outdated = p.state == 'outdated'
    elseif M.files_match(item.filename, file) then
      start_line, end_line = M.range_in(item, bufnr)
      -- A diff buffer shows a comment only where it holds the comment's
      -- snapshot, so it is never outdated there
      outdated = start_line and not special and hooks.is_outdated(item)
    end
    if start_line then
      local comment_type = item.kind

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

-- Whether a `git rev-parse` gave a definitive answer: a root (0), "not a git
-- repo" (128, git's fatal exit), or no git installed at all (the spawn fails
-- with ENOENT: there is no repo git could name). A timeout, a signal, any
-- other spawn error or any other exit is transient and must not be cached.
-- `result` is the finished process when `ok`, else the spawn error.
local function definitive(ok, result)
  if not ok then
    -- nvim prefixes the message with its location, so it is not anchored
    return type(result) == 'string' and result:find('ENOENT', 1, true) ~= nil
  end
  return result ~= nil and (result.signal or 0) == 0
    and (result.code == 0 or result.code == 128)
end

local uv = vim.uv or vim.loop
-- How long git is left alone in a dir after it gave no definitive answer
local RETRY_NS = 5e9
-- Per dir git is run in: the hrtime before which it is not asked again
local retry_after = {}

-- Test hook: how long git is left alone after a transient failure (a window
-- open now is kept no longer than that either)
function M._set_retry_ns(ns)
  RETRY_NS = ns
  local limit = uv.hrtime() + ns
  for dir, at in pairs(retry_after) do
    retry_after[dir] = math.min(at, limit)
  end
end

-- Run `git rev-parse --show-toplevel` in `dir`. After a transient failure
-- git is not spawned there again until the retry window has passed (a
-- missing or always-slow git would otherwise cost a spawn, or a 1 s
-- timeout, on every call).
-- Returns: root (or false), transient (true when git gave no definitive answer)
local function rev_parse_toplevel(dir)
  local after = retry_after[dir]
  if after and uv.hrtime() < after then return false, true end

  local root = false
  local ok, result = pcall(function()
    return vim.system({ 'git', '-C', dir, 'rev-parse', '--show-toplevel' }, { text = true, timeout = 1000 }):wait()
  end)
  if ok and result and result.code == 0 and result.stdout then
    local trimmed = vim.trim(result.stdout)
    if trimmed ~= '' then root = trimmed end
  end
  if not definitive(ok, result) then
    retry_after[dir] = uv.hrtime() + RETRY_NS
    return false, true
  end
  retry_after[dir] = nil
  return root, false
end

-- Return the git toplevel containing `dir` (a file path uses its directory),
-- or nil outside git (or with no git installed). Definitive answers are
-- cached per argument for the session; a failed or timed-out git is not, and
-- is asked again once the retry window has passed (see rev_parse_toplevel).
-- While the path's directory does not exist yet, git is asked about its
-- nearest existing ancestor and the answer is not cached (the directory may be
-- created later, possibly as a repo of its own).
-- Returns: root (or nil), transient (true when git gave no definitive answer)
function M.git_toplevel(dir)
  if not dir or dir == '' then return nil, false end
  local cached = toplevel_cache[dir]
  if cached ~= nil then return cached or nil, false end

  local query = dir
  if vim.fn.isdirectory(query) == 0 then
    query = vim.fn.fnamemodify(query, ':h')
  end
  local missing = vim.fn.isdirectory(query) == 0
  while vim.fn.isdirectory(query) == 0 do
    local up = vim.fn.fnamemodify(query, ':h')
    if up == query then break end
    query = up
  end

  local root, transient = rev_parse_toplevel(query)
  if transient then return nil, true end
  if not missing then toplevel_cache[dir] = root end
  return root or nil, false
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

-- work tree per git dir; false marks "could not resolve" so misses are cached
-- too (but not when git failed transiently: that is asked again next time)
local worktree_cache = {}

-- The work tree a git dir belongs to. Diff plugins name buffers after the git
-- dir, which for a linked worktree (.git/worktrees/<n>) or a submodule
-- (.git/modules/<n>) is not inside the work tree.
local function worktree_of(gitdir)
  local cached = worktree_cache[gitdir]
  if cached ~= nil then return cached or nil end

  local tree = false
  local transient = false
  local prefix = gitdir:match('^(.-)/%.git$')
  if prefix then
    -- The main repo's own .git: its parent (resolved as before)
    -- (an empty prefix resolves against the cwd, which is not cached here)
    if prefix ~= '' then
      if vim.fn.isdirectory(prefix) == 0 then
        -- The repo is gone: git_toplevel would walk up to an enclosing repo
        -- and map the file there. Use the prefix itself, uncached (the
        -- directory may reappear)
        return prefix
      end
      local top, failed = M.git_toplevel(prefix)
      tree, transient = top or prefix, failed
    end
  elseif vim.fn.filereadable(gitdir .. '/gitdir') == 1 then
    -- Linked worktree: <gitdir>/gitdir holds the path of <worktree>/.git,
    -- relative to <gitdir> when made with worktree.useRelativePaths
    local ok, lines = pcall(vim.fn.readfile, gitdir .. '/gitdir', '', 1)
    local p = ok and lines[1] and vim.trim(lines[1]) or ''
    if p ~= '' then
      if p:sub(1, 1) ~= '/' then p = vim.fn.simplify(gitdir .. '/' .. p) end
      tree = vim.fn.fnamemodify(p, ':h')
    end
  elseif vim.fn.isdirectory(gitdir) == 1 then
    -- Submodule (core.worktree set in its git dir)
    tree, transient = rev_parse_toplevel(gitdir)
  end
  if not tree then
    -- Last resort: the directory holding the first .git
    tree = gitdir:match('^(.-)/%.git/') or false
  end

  if not transient then worktree_cache[gitdir] = tree end
  return tree or nil
end

-- Resolve `rel` inside the work tree of `gitdir`
local function resolve_gitdir_path(gitdir, rel)
  local tree = worktree_of(gitdir)
  if tree then return tree .. '/' .. rel end
  return resolve_repo_path(nil, rel)
end

-- Undo %XX percent-encoding (as fugitive applies to its buffer names)
local function pct_decode(s)
  return (s:gsub('%%(%x%x)', function(h) return string.char(tonumber(h, 16)) end))
end

-- Extract real file path from special diff buffers. Regular buffers (and names
-- matching no known scheme) return the buffer name unchanged.
function M.get_real_filepath(bufnr)
  local bufname = vim.api.nvim_buf_get_name(bufnr or 0)

  -- diffview:///repo/.git/<rev>/file.txt (also tolerates .git//<rev>/); the
  -- git dir may be a linked worktree's (.git/worktrees/<n>) or a submodule's
  -- (.git/modules/<n>), in any sequence (a submodule of a linked worktree is
  -- .git/worktrees/<wt>/modules/<n>)
  local gitdir, rest = bufname:match('^diffview://(.-/%.git)/+(.+)$')
  if rest then
    while true do
      local seg, tail = rest:match('^(worktrees/[^/]+)/+(.+)$')
      if not seg then seg, tail = rest:match('^(modules/[^/]+)/+(.+)$') end
      if not seg then break end
      gitdir, rest = gitdir .. '/' .. seg, tail
    end
    local rel = rest:match('^[^/]+/+(.+)$')
    if rel then
      return resolve_gitdir_path(gitdir, rel)
    end
  end

  -- fugitive:///repo/.git//<rev>/file.txt (the git dir, then //); fugitive
  -- percent-encodes %, #, ? and control characters in both parts
  local gd, rel = bufname:match('^fugitive://(.-)//[^/]+/(.+)$')
  if rel then
    gd, rel = pct_decode(gd), pct_decode(rel)
    if gd:find('/%.git$') or gd:find('/%.git/') then
      return resolve_gitdir_path(gd, rel)
    end
  end

  -- gitsigns://<gitdir>//<rev>:<path>, where <rev> is :0..:3 (index stages)
  -- or a commit; the path-less form (gitsigns://<gitdir>//:0) is left as is
  local sgd, srel = bufname:match('^gitsigns://(.-)//:?[^:]+:(.+)$')
  if srel then
    return resolve_gitdir_path(sgd, srel)
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
-- revision (fugitive, diffview, gitsigns): its anchor's lines when that buffer holds
-- exactly the anchor's snapshot, else nil (the comment is not shown there).
-- Returns: lnum, end_lnum, or nil
function M.range_in(item, bufnr)
  if not M.is_special_buffer(bufnr) then return hooks.range(item) end
  local a = item.anchor or item
  if not a.sha or not vim.api.nvim_buf_is_loaded(bufnr) then return nil end
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  local cached = special_sha[bufnr]
  if not cached or cached.tick ~= tick or cached.name ~= name then
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    cached = { name = name, tick = tick, sha = hooks.hash(lines) }
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
      or path:match('^gitsigns://') ~= nil
end

-- Check if a buffer (default: current) is a diff/special buffer
function M.is_special_buffer(bufnr)
  local bufname = vim.api.nvim_buf_get_name(bufnr or 0)
  return bufname:match('^diffview://')
      or bufname:match('^fugitive://')
      or bufname:match('^codediff://')
      or bufname:match('^gitsigns://')
end

return M
