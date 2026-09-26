-- Export functionality for quickfix-review.nvim
local M = {}

local storage = require('quickfix-review.storage')
local store = require('quickfix-review.store')

-- Each item is formatted with: index, TYPE, file:line (or file:start-end), text
M.default_item_format = '%d. **[%s]** `%s` - %s'

-- Convert comment records (store.all()) to a markdown string
function M.to_markdown(comments, config)
  if not comments or #comments == 0 then
    return nil, 'No comments to export'
  end

  local export_config = config.export or {}
  local header = export_config.header or ''
  local type_legend = export_config.type_legend or ''
  local item_format = export_config.item_format or M.default_item_format
  local bad_format_reported = false

  local lines = { header, type_legend }

  for i, item in ipairs(comments) do
    local file = vim.fn.fnamemodify(item.filename, ':.')
    local comment_type = item.kind:upper()
    local comment_text = item.body
    if item.response then
      comment_text = comment_text .. ' | Response: ' .. item.response
    end

    -- Format line reference (handle ranges)
    local line_ref
    local lnum, end_lnum = store.range(item)
    if end_lnum ~= lnum then
      line_ref = string.format('%s:%d-%d', file, lnum, end_lnum)
    else
      line_ref = string.format('%s:%d', file, lnum)
    end
    -- Its code changed since the comment was made (see track.lua)
    if store.is_outdated(item) then line_ref = line_ref .. ' (outdated)' end

    local ok, line_str = pcall(string.format, item_format, i, comment_type, line_ref, comment_text)
    if not ok then
      if not bad_format_reported then
        bad_format_reported = true
        -- line_str holds the pcall error here, not a formatted line
        vim.notify(string.format('quickfix-review: invalid export.item_format %s (%s); it must take'
          .. ' (index, TYPE, file:line, text); using the default %s',
          vim.inspect(item_format), tostring(line_str), vim.inspect(M.default_item_format)),
          vim.log.levels.WARN)
      end
      line_str = string.format(M.default_item_format, i, comment_type, line_ref, comment_text)
    end
    table.insert(lines, line_str)

    -- Append captured context (commit + diff snippet) if present
    local ctx = item.context
    if type(ctx) == 'table' then
      if ctx.commit_short then
        table.insert(lines, string.format('   - commit: `%s`', ctx.commit_short))
      end
      if type(ctx.snippet) == 'table' and #ctx.snippet > 0 then
        table.insert(lines, '')
        table.insert(lines, '   ```diff')
        for _, l in ipairs(ctx.snippet) do
          table.insert(lines, '   ' .. l)
        end
        table.insert(lines, '   ```')
      end
    end
  end

  return table.concat(lines, '\n'), nil
end

-- Write content to clipboard and optionally to file
-- Returns: success (boolean), message (string)
function M.to_clipboard_and_file(content, filename)
  if not content then
    return false, 'No content to export'
  end

  -- Copy to clipboard
  vim.fn.setreg('+', content)

  -- Try to write to file
  if filename then
    local ok, err = storage.atomic_write(filename, content)
    if not ok then
      return false, 'Review copied to clipboard, but could not write ' .. filename .. ': ' .. (err or 'unknown error')
    end
    return true, string.format('Review exported to clipboard and %s', filename)
  end

  return true, 'Review copied to clipboard'
end

return M
