-- :ReviewAdd commands generated from the configured comment types.
-- Kept apart from init.lua so plugin/ can create them without loading the
-- store at startup; the callbacks require the plugin lazily.
local M = {}

-- The command range as add_comment/delete_comment take it: {line1, line2}
-- when one was given, nil for the current line
function M.range_of(o)
  return o.range > 0 and { o.line1, o.line2 } or nil
end

-- The CamelCase command suffix of a type key (needs_work -> NeedsWork), or
-- nil when the key cannot name a command. Lookups lowercase the type
-- (utils.get_comment_type_config), so only lowercase keys are usable anyway.
local function camel(name)
  if not name:match('^%l[%l%d_]*$') then return nil end
  local parts = {}
  for segment in name:gmatch('[^_]+') do
    table.insert(parts, segment:sub(1, 1):upper() .. segment:sub(2))
  end
  return table.concat(parts)
end

local function add(type_name, o)
  require('quickfix-review').add_comment(type_name:upper(), M.range_of(o))
end

-- (Re)create :ReviewAdd {type} and :ReviewAdd<Type> for every configured
-- comment type. Safe to call repeatedly: nvim_create_user_command replaces.
function M.create()
  -- Required here, not at load time, so a reloaded config module is seen
  local utils = require('quickfix-review.utils')
  local types = utils.get_comment_types()

  local wanted = {}
  for _, t in ipairs(types) do
    local suffix = camel(t)
    if not suffix then
      vim.notify(string.format(
        'quickfix-review: comment type %q has no :ReviewAdd command (use lowercase letters, digits and _); use :ReviewAdd %s',
        t, t), vim.log.levels.WARN)
    else
      local name = 'ReviewAdd' .. suffix
      if wanted[name] then
        vim.notify(string.format(
          'quickfix-review: comment type %q would also be :%s; no command made for it', t, name),
          vim.log.levels.WARN)
      else
        wanted[name] = true
        vim.api.nvim_create_user_command(name, function(o) add(t, o) end, {
          range = true,
          desc = 'Add a ' .. t:upper() .. ' comment (range or current line)',
        })
      end
    end
  end

  vim.api.nvim_create_user_command('ReviewAdd', function(o) add(o.args, o) end, {
    nargs = 1,
    range = true,
    complete = function(lead)
      lead = lead:lower()
      return vim.tbl_filter(function(t) return vim.startswith(t, lead) end,
        require('quickfix-review.utils').get_comment_types())
    end,
    desc = 'Add a comment of {type} (range or current line)',
  })

  -- Delete commands of types no longer configured (so a comment_types that
  -- replaces the defaults drops :ReviewAddIssue etc.). The old set is read
  -- back from Neovim rather than tracked here, because plugin/ may be
  -- re-sourced and this module reloaded between calls. This also removes a
  -- user's own :ReviewAdd<X> command, which we accept.
  for name in pairs(vim.api.nvim_get_commands({})) do
    if name:match('^ReviewAdd%u') and not wanted[name] then
      pcall(vim.api.nvim_del_user_command, name)
    end
  end
end

return M
