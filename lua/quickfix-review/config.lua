-- Configuration and defaults for quickfix-review.nvim
local M = {}

-- Default comment types
M.default_comment_types = {
  issue = { sign = '⚠', highlight = 'DiagnosticError', description = 'Problems to fix' },
  suggestion = { sign = '💭', highlight = 'DiagnosticWarn', description = 'Improvements' },
  note = { sign = '📝', highlight = 'DiagnosticInfo', description = 'Observations' },
  praise = { sign = '✨', highlight = 'DiagnosticHint', description = 'Positive feedback' },
  question = { sign = '?', highlight = 'DiagnosticInfo', description = 'Clarification needed' },
  insight = { sign = '💡', highlight = 'DiagnosticHint', description = 'Useful observations' }
}

-- Default keymaps for default comment types
M.default_type_keymaps = {
  add_issue = '<leader>ci',
  add_suggestion = '<leader>cs',
  add_note = '<leader>cn',
  add_praise = '<leader>cp',
  add_question = '<leader>cq',
  add_insight = '<leader>ck',
}

-- Default configuration
M.defaults = {
  -- Per-project storage directory: a string (used as-is, for every project)
  -- or function(root) -> string. nil = stdpath('data')/quickfix-review/
  -- <basename(root)>-<first 12 hex of sha256(root)>. The review lives in
  -- comments.json inside it.
  storage_dir = nil,

  -- Deprecated: a single storage file shared by every project. When set,
  -- storage_dir is ignored and nothing is imported.
  storage_file = nil,

  -- Default export filename (nil = clipboard only, set to 'quickfix-review.md' to also save to file)
  export_file = nil,

  -- Deprecated, does nothing: comments follow the file when it changes on
  -- disk (see track.lua). Setting it to true shows a one-time notice.
  prompt_on_file_change = false,

  -- Open the comment float when :cnext/:cprev/:cc/:cfirst/:clast lands on
  -- an entry of the review quickfix list
  auto_show = true,

  -- Comment types: if provided, replaces defaults entirely
  -- Use additional_comment_types to add to defaults instead
  comment_types = nil,

  -- Additional comment types: merged with defaults (or with comment_types if provided)
  additional_comment_types = nil,

  -- Sign definitions (generated from comment_types, but can be overridden)
  signs = {},

  -- Export format strings
  export = {
    header = '# Code Review\n\n',
    type_legend = '',  -- Generated dynamically from comment_types
    -- Each item: index, TYPE, file:line (or file:start-end), comment text
    item_format = '%d. **[%s]** `%s` - %s',
  },

  -- Keymaps (set to false to disable a keymap)
  -- Keymaps for comment types (add_<type>) are generated based on available types
  keymaps = {
    -- Comment type cycling
    add_comment_cycle = '<leader>ca',  -- Add comment with current cycle type
    cycle_next = '+',                  -- Cycle to next type
    cycle_previous = '-',              -- Cycle to previous type

    delete_comment = '<leader>cd',
    export = '<leader>ce',
    clear = '<leader>cc',
    summary = '<leader>cS',
    save = '<leader>cw',
    load = '<leader>cr',
    open_list = '<leader>co',
    next_comment = ']r',
    prev_comment = '[r',
    goto_real_file = '<leader>cg',
    view = '<leader>cv',
    edit = '<leader>cm',  -- Edit (modify) the comment on the current line
    reanchor = false,  -- Accept an outdated comment's new position (:ReviewReanchor)
  },
}

-- The old default storage_file, one global file for every project. Read (never
-- written) once per project to import that project's comments. Evaluated on
-- each call so a changed XDG_DATA_HOME is honoured.
function M.legacy_storage_file()
  return vim.fn.stdpath('data') .. '/quickfix-review.json'
end

-- Order of the default comment types, used wherever types are listed
M.default_type_order = { 'issue', 'suggestion', 'note', 'praise', 'question', 'insight' }

-- The names in `types` (a name -> config table) in a fixed order: the default
-- types in their usual order, then any others sorted by name
function M.type_order(types)
  local ordered, seen = {}, {}
  for _, name in ipairs(M.default_type_order) do
    if types[name] ~= nil then
      table.insert(ordered, name)
      seen[name] = true
    end
  end
  local extra = {}
  for name, _ in pairs(types) do
    if not seen[name] then table.insert(extra, name) end
  end
  table.sort(extra)
  vim.list_extend(ordered, extra)
  return ordered
end

-- Fill in the options derived from comment_types (the types themselves, their
-- keymaps, signs and export legend), respecting what the user set explicitly
local function derive(user_opts)
  -- Determine final comment_types:
  -- 1. If user provides comment_types, use it (replaces defaults)
  -- 2. Otherwise use default_comment_types
  -- 3. Merge additional_comment_types on top
  local base_types
  local user_types = user_opts.comment_types
  if user_types ~= nil and (type(user_types) ~= 'table' or vim.tbl_isempty(user_types)) then
    vim.notify('quickfix-review: comment_types must be a non-empty table; using the default types',
      vim.log.levels.WARN)
    user_types = nil
  end
  if user_types then
    base_types = vim.deepcopy(user_types)
  else
    base_types = vim.deepcopy(M.default_comment_types)
  end

  if type(user_opts.additional_comment_types) == 'table' then
    base_types = vim.tbl_deep_extend('force', base_types, user_opts.additional_comment_types)
  end

  M.options.comment_types = base_types

  -- Generate keymaps for available comment types
  -- Start with user-provided keymaps, then add defaults for existing types
  for type_name, _ in pairs(M.options.comment_types) do
    local keymap_key = 'add_' .. type_name
    -- Only set default keymap if user didn't provide one and it's a default type
    if M.options.keymaps[keymap_key] == nil and M.default_type_keymaps[keymap_key] then
      M.options.keymaps[keymap_key] = M.default_type_keymaps[keymap_key]
    end
  end

  -- Generate signs from comment_types if not explicitly overridden
  if not user_opts.signs or vim.tbl_isempty(user_opts.signs) then
    M.options.signs = {}

    -- Generate main signs and continuation signs from comment_types
    for type_name, type_config in pairs(M.options.comment_types) do
      -- Main sign
      M.options.signs[type_name] = {
        text = type_config.sign,
        texthl = type_config.highlight
      }

      -- Continuation sign
      local cont_key = type_name .. '_continuation'
      M.options.signs[cont_key] = {
        text = '│',
        texthl = type_config.highlight
      }
    end
  end

  -- Generate type legend for export, unless the user set one (even '')
  if not (type(user_opts.export) == 'table' and user_opts.export.type_legend ~= nil) then
    local type_descriptions = {}
    for _, type_name in ipairs(M.type_order(M.options.comment_types)) do
      local type_config = M.options.comment_types[type_name]
      table.insert(type_descriptions, type_name:upper() .. ' (' .. (type_config.description or '') .. ')')
    end
    M.options.export.type_legend = 'Comment types: ' .. table.concat(type_descriptions, ', ') .. '\n'
  end
end

-- Current options. Filled with the defaults at load, so commands work before
-- setup() is called; setup() replaces them.
M.options = vim.deepcopy(M.defaults)
derive({})

-- Setup configuration by merging user options with defaults
function M.setup(opts)
  local user_opts = opts or {}

  M.options = vim.tbl_deep_extend('force', {}, M.defaults, user_opts)
  derive(user_opts)

  return M
end

return M
