-- The headless entry point for tools outside Neovim (review exporters,
-- agents answering a review): scripts/qfr.lua runs main() under
-- `nvim --clean -l`. Every read and write goes through the store, so the
-- review is the current project's (from the cwd), found and locked the same
-- way an interactive Neovim finds and locks it.
--
--   export              print the review's comments as a JSON array
--   respond <id> <text> set the response of comment <id>
--   clear               remove every comment
--
-- Only the result goes to stdout; every message (including the store's
-- vim.notify, e.g. the one-time import notice) goes to stderr, so stdout
-- can be parsed. setup() is never called: the store works with the default
-- config, so a storage_dir set in a user config is not seen here.
local M = {}

local USAGE = table.concat({
  'usage: nvim --clean -l scripts/qfr.lua <command> [args]',
  '  export              print the current project\'s comments as JSON',
  '  respond <id> <text> set the response of comment <id>',
  '  clear               remove every comment',
}, '\n')

local function err(msg)
  io.stderr:write(tostring(msg), '\n')
end

-- Send vim.notify and print to stderr, keeping stdout for the result
-- Returns: a function restoring them
local function quiet_stdout()
  local notify, print = vim.notify, _G.print
  vim.notify = function(msg) err(msg) end
  _G.print = function(...)
    local parts = {}
    for i = 1, select('#', ...) do parts[i] = tostring((select(i, ...))) end
    err(table.concat(parts, '\t'))
  end
  return function() vim.notify, _G.print = notify, print end
end

local function export()
  -- store.all() drops the sync result: a review that can't be read would
  -- look empty, so sync first and fail on an error
  local ok, e = require('quickfix-review.store.sync').sync()
  if not ok then
    err('quickfix-review: could not read the review: ' .. tostring(e))
    return 1
  end
  local store = require('quickfix-review.store')
  local out = {}
  for _, c in ipairs(store.all()) do
    local lnum, end_lnum = store.range(c)
    table.insert(out, {
      id = c.id,
      filename = c.filename,
      kind = c.kind,
      body = c.body,
      response = c.response,
      lnum = lnum,
      end_lnum = end_lnum,
    })
  end
  -- vim.json.encode({}) is '{}': an empty review must still be an array
  io.stdout:write(#out == 0 and '[]' or vim.json.encode(out), '\n')
  return 0
end

local function respond(id, text)
  local res, reason = require('quickfix-review.store').respond(id, text)
  if res == 'responded' or res == 'unchanged' then return 0 end
  if res == 'missing' then
    err('quickfix-review: no comment with id ' .. id)
  else
    err('quickfix-review: could not set the response' .. (reason and (': ' .. tostring(reason)) or ''))
  end
  return 1
end

local function clear()
  if require('quickfix-review.store').clear() then return 0 end
  err('quickfix-review: could not clear the review')
  return 1
end

-- Run the command in `args` (argv after the script)
-- Returns: the exit code: 0 on success, 1 on failure, 2 on a usage error
function M.main(args)
  local restore = quiet_stdout()
  args = args or {}
  local cmd = args[1]
  local ok, code = pcall(function()
    if cmd == 'export' and #args == 1 then return export() end
    if cmd == 'clear' and #args == 1 then return clear() end
    if cmd == 'respond' and #args == 3 and args[2] ~= '' and args[3] ~= '' then
      return respond(args[2], args[3])
    end
    err(USAGE)
    return 2
  end)
  restore()
  if not ok then
    err('quickfix-review: ' .. tostring(code))
    return 1
  end
  return code
end

return M
