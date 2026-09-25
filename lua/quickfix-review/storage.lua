-- Storage functionality for quickfix-review.nvim
local M = {}

-- Save comments to file (an empty list is saved too, so clearing persists)
-- Returns: success (boolean), message (string)
function M.save(comments, filepath)
  local ok, encoded = pcall(vim.fn.json_encode, comments)
  if not ok then
    return false, 'Failed to encode comments as JSON'
  end

  local f, err = io.open(filepath, 'w')
  if not f then
    return false, 'Could not open file for writing: ' .. (err or 'unknown error')
  end

  f:write(encoded)
  f:close()

  return true, string.format('Review saved to %s (%d comments)', filepath, #comments)
end

-- Load comments from file. A missing or empty file is an empty review.
-- Returns: comments (table or nil), err (string or nil)
function M.load(filepath)
  local f = io.open(filepath, 'r')
  if not f then
    return {}, nil
  end

  local content = f:read('*all')
  f:close()

  if not content or vim.trim(content) == '' then
    return {}, nil
  end

  local ok, comments = pcall(vim.fn.json_decode, content)
  if not ok or type(comments) ~= 'table' then
    return nil, 'Failed to parse saved review at ' .. filepath .. ' (invalid JSON)'
  end

  return comments, nil
end

return M
