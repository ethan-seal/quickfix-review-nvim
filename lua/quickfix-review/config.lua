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

  -- The review journal's active segment (events/NNNNNN.jsonl) is sealed
  -- once it grows past this many bytes, and the next one started. Segments
  -- are kept forever (they are the review, and its :ReviewHistory).
  -- log_max_bytes is its deprecated name.
  segment_max_bytes = 4 * 1024 * 1024,

  -- A checkpoint (a disposable cache of the replayed journal, so a load
  -- reads only the tail past it) is written once this many events were
  -- read past the newest one (or 256 KiB of them)
  checkpoint_every = 500,

  -- How many valid checkpoints are kept; older ones are deleted
  checkpoint_keep = 2,

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

-- Longest character prefix of text that is at most 2 display cells wide
local function fit_sign_text(text)
  local fitted = ''
  for i = 1, vim.fn.strchars(text) do
    local candidate = vim.fn.strcharpart(text, 0, i)
    if vim.fn.strdisplaywidth(candidate) > 2 then break end
    fitted = candidate
  end
  return fitted
end

-- The name -> config entries of a user's comment type table (comment_types
-- or additional_comment_types, named by `option` in warnings). A list entry
-- ('bug') or `name = true` is a type with the default config of that name, or
-- a generic one; `name = false` is kept as false (the caller decides what it
-- means); anything else is dropped with a warning.
local function type_entries(types, option)
  local entries = {}
  local function bare(name)
    local default = M.default_comment_types[name:lower()]
    if default then return vim.deepcopy(default) end
    return { sign = name:sub(1, 1):upper(), highlight = 'DiagnosticInfo', description = '' }
  end
  local keys = vim.tbl_keys(types)
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  for _, key in ipairs(keys) do
    local def = types[key]
    if type(key) == 'number' and type(def) == 'string' and def ~= '' then
      if entries[def] == nil then entries[def] = bare(def) end
    elseif type(key) == 'string' and key ~= '' and def == true then
      entries[key] = bare(key)
    elseif type(key) == 'string' and key ~= '' and (def == false or type(def) == 'table') then
      entries[key] = def
    else
      vim.notify(string.format(
        "quickfix-review: %s entry %s = %s is not a type name or a type config table; ignoring it",
        option, vim.inspect(key), vim.inspect(def)), vim.log.levels.WARN)
    end
  end
  return entries
end

-- Fill in the options derived from comment_types (the types themselves, their
-- keymaps, signs and export legend), respecting what the user set explicitly
local function derive(user_opts)
  -- keymaps = false disables every plugin map; any other non-table is an
  -- error. Checked first: everything below indexes M.options.keymaps.
  local all_keymaps_off = false
  if M.options.keymaps == false then
    all_keymaps_off = true
    M.options.keymaps = {}
    for key, _ in pairs(M.defaults.keymaps) do M.options.keymaps[key] = false end
    for key, _ in pairs(M.default_type_keymaps) do M.options.keymaps[key] = false end
  elseif type(M.options.keymaps) ~= 'table' then
    vim.notify('quickfix-review: keymaps must be a table or false; using the default keymaps',
      vim.log.levels.WARN)
    M.options.keymaps = vim.deepcopy(M.defaults.keymaps)
  end
  -- export has no "disabled" meaning: a non-table falls back to the default
  if type(M.options.export) ~= 'table' then
    vim.notify('quickfix-review: export must be a table; using the default export format',
      vim.log.levels.WARN)
    M.options.export = vim.deepcopy(M.defaults.export)
  end

  -- Determine final comment_types:
  -- 1. If user provides comment_types, use it (replaces defaults)
  -- 2. Otherwise use default_comment_types
  -- 3. Merge additional_comment_types on top
  local base_types
  local user_types = user_opts.comment_types
  if type(user_types) == 'table' then
    -- false in comment_types just leaves the type out
    local entries = type_entries(user_types, 'comment_types')
    user_types = {}
    for name, def in pairs(entries) do
      if def ~= false then user_types[name] = def end
    end
  end
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

  local additional = user_opts.additional_comment_types
  if additional ~= nil and type(additional) ~= 'table' then
    vim.notify('quickfix-review: additional_comment_types must be a table; ignoring it',
      vim.log.levels.WARN)
  elseif additional ~= nil then
    -- false removes a type; a table is merged into the type's config
    for name, def in pairs(type_entries(additional, 'additional_comment_types')) do
      if def == false then
        -- type names are lowercase, so Praise = false removes praise too
        base_types[name] = nil
        base_types[name:lower()] = nil
      elseif type(base_types[name]) == 'table' then
        base_types[name] = vim.tbl_deep_extend('force', base_types[name], def)
      else
        base_types[name] = vim.deepcopy(def)
      end
    end
  end

  if vim.tbl_isempty(base_types) then
    vim.notify('quickfix-review: no comment types left after additional_comment_types; using the default types',
      vim.log.levels.WARN)
    base_types = vim.deepcopy(M.default_comment_types)
  end

  -- Type names are stored and looked up lowercased (store, storage, signs),
  -- so a key with an uppercase letter is renamed to its lowercase form, along
  -- with its add_<type> keymap and signs. On a collision the key that was
  -- already lowercase wins, else the first in sorted order.
  local user_signs = type(M.options.signs) == 'table' and M.options.signs or nil
  local names = vim.tbl_keys(base_types)
  table.sort(names, function(a, b) return tostring(a) < tostring(b) end)
  local lowered = {}
  for _, name in ipairs(names) do
    if type(name) == 'string' and name == name:lower() then lowered[name] = base_types[name] end
  end
  for _, name in ipairs(names) do
    local lower = type(name) == 'string' and name:lower() or name
    if lower ~= name then
      if lowered[lower] ~= nil then
        vim.notify(string.format(
          "quickfix-review: comment type '%s' is the same as '%s' (types are lowercase); ignoring '%s'",
          name, lower, name), vim.log.levels.WARN)
      else
        vim.notify(string.format("quickfix-review: comment type '%s' is stored as '%s'", name, lower),
          vim.log.levels.WARN)
        lowered[lower] = base_types[name]
        local keymaps = M.options.keymaps
        if keymaps['add_' .. lower] == nil then
          keymaps['add_' .. lower] = keymaps['add_' .. name]
        end
        keymaps['add_' .. name] = nil
        if user_signs then
          for _, suffix in ipairs({ '', '_continuation' }) do
            if user_signs[lower .. suffix] == nil then
              user_signs[lower .. suffix] = user_signs[name .. suffix]
            end
            user_signs[name .. suffix] = nil
          end
        end
      end
    end
  end
  base_types = lowered

  M.options.comment_types = base_types

  -- With keymaps = false, add_<type> of custom types is off too
  if all_keymaps_off then
    for type_name, _ in pairs(base_types) do M.options.keymaps['add_' .. type_name] = false end
  end

  -- Journal options (docs/journal.md). log_max_bytes (v2's rotation size)
  -- is the deprecated name of segment_max_bytes; log_retention_days is gone
  -- (segments are never deleted), and ignored.
  if user_opts.log_max_bytes ~= nil then
    require('quickfix-review.notify').once('deprecated-log_max_bytes',
      'log_max_bytes is deprecated: use segment_max_bytes', vim.log.levels.WARN)
    if user_opts.segment_max_bytes == nil then M.options.segment_max_bytes = user_opts.log_max_bytes end
    M.options.log_max_bytes = nil
  end
  if user_opts.log_retention_days ~= nil then
    require('quickfix-review.notify').once('deprecated-log_retention_days',
      'log_retention_days is ignored: journal segments are the review and are never deleted',
      vim.log.levels.WARN)
    M.options.log_retention_days = nil
  end
  -- A bad value falls back to the default
  for _, name in ipairs({ 'segment_max_bytes', 'checkpoint_every', 'checkpoint_keep' }) do
    local v = M.options[name]
    if not (type(v) == 'number' and v > 0) then
      vim.notify('quickfix-review: ' .. name .. ' must be a positive number; using the default',
        vim.log.levels.WARN)
      M.options[name] = M.defaults[name]
    end
  end

  -- Generate keymaps for available comment types
  -- Start with user-provided keymaps, then add defaults for existing types
  for type_name, _ in pairs(M.options.comment_types) do
    local keymap_key = 'add_' .. type_name
    -- Only set default keymap if user didn't provide one and it's a default type
    if M.options.keymaps[keymap_key] == nil and M.default_type_keymaps[keymap_key] then
      M.options.keymaps[keymap_key] = M.default_type_keymaps[keymap_key]
    end
  end

  -- A keymap is a non-empty lhs string or false; anything else (true, '',
  -- a number) would make vim.keymap.set throw, so warn and leave it unmapped
  for _, key in ipairs(vim.tbl_keys(M.options.keymaps)) do
    local lhs = M.options.keymaps[key]
    if lhs ~= false and not (type(lhs) == 'string' and lhs ~= '') then
      vim.notify(string.format(
        "quickfix-review: keymaps.%s must be a key sequence (a non-empty string) or false; not mapping it",
        tostring(key)), vim.log.levels.WARN)
      M.options.keymaps[key] = false
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

  -- Sign text must fit in 2 cells or placing the sign throws. Replace the
  -- entry rather than mutating it: it may be the user's own table.
  for key, def in pairs(M.options.signs) do
    if type(def) == 'table' and type(def.text) == 'string' and vim.fn.strdisplaywidth(def.text) > 2 then
      vim.notify(string.format("quickfix-review: sign '%s' for %s is wider than 2 cells; truncating",
        def.text, key), vim.log.levels.WARN)
      M.options.signs[key] = vim.tbl_extend('force', def, { text = fit_sign_text(def.text) })
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
