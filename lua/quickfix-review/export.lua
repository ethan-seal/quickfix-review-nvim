-- Export functionality for quickfix-review.nvim
local M = {}

local storage = require('quickfix-review.storage')
local store = require('quickfix-review.store')

-- Each item is formatted with: index, TYPE, file:line (or file:start-end), text
M.default_item_format = '%d. **[%s]** `%s` - %s'

-- Code fence language for a captured snippet: 'diff' for a diff hunk (and
-- legacy contexts with no snippet_source); for buffer lines, the filetype
-- guessed from the filename, or '' (a plain fence) when unknown
local function snippet_fence_lang(ctx, filename)
  if ctx.snippet_source ~= 'buffer' then return 'diff' end
  local ok, ft = pcall(vim.filetype.match, { filename = filename })
  return ok and ft or ''
end

-- A code fence longer than the longest backtick run in `lines` (at least
-- three), so no content line can close it early (CommonMark)
local function fence_for(lines)
  local longest = 0
  for _, l in ipairs(lines) do
    for run in l:gmatch('`+') do
      if #run > longest then longest = #run end
    end
  end
  return string.rep('`', math.max(3, longest + 1))
end

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
    -- A multi-line body/response: continuation lines are indented under the
    -- list item rather than breaking out of it
    local item_lines = vim.split(line_str, '\n', { plain = true })
    table.insert(lines, item_lines[1])
    for k = 2, #item_lines do
      table.insert(lines, item_lines[k] == '' and '' or '   ' .. item_lines[k])
    end

    -- Append captured context (commit + diff snippet) if present
    local ctx = item.context
    if type(ctx) == 'table' then
      if ctx.commit_short then
        table.insert(lines, string.format('   - commit: `%s`', ctx.commit_short))
      end
      if type(ctx.snippet) == 'table' and #ctx.snippet > 0 then
        if ctx.buffer_modified then
          table.insert(lines, '   - (unsaved buffer)')
        end
        table.insert(lines, '')
        local fence = fence_for(ctx.snippet)
        table.insert(lines, '   ' .. fence .. snippet_fence_lang(ctx, item.filename))
        for _, l in ipairs(ctx.snippet) do
          table.insert(lines, '   ' .. l)
        end
        table.insert(lines, '   ' .. fence)
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

  -- Copy to the clipboard; without a clipboard provider setreg('+') stores
  -- nothing, so fall back to the unnamed register and say so
  local has_clip = vim.fn.has('clipboard') == 1
  vim.fn.setreg(has_clip and '+' or '"', content)
  local target = has_clip and 'clipboard' or 'the unnamed register (no clipboard provider)'

  -- Try to write to file
  if filename then
    local ok, err = storage.atomic_write(filename, content)
    if not ok then
      return false, 'Review copied to ' .. target .. ', but could not write ' .. filename .. ': ' .. (err or 'unknown error')
    end
    if has_clip then
      return true, string.format('Review exported to clipboard and %s', filename)
    end
    return true, string.format('Review exported to %s and the unnamed register (no clipboard provider)', filename)
  end

  return true, 'Review copied to ' .. target
end

return M
