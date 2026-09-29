-- Messages shown once per session, by key. Every message is prefixed with
-- "quickfix-review: ".
local M = {}

-- Keys whose message was shown this session
local notified = {}

-- Show `msg` at `level` unless a message with `key` was already shown
function M.once(key, msg, level)
  if notified[key] then return end
  notified[key] = true
  vim.notify('quickfix-review: ' .. msg, level)
end

-- Let the message with `key` be shown again
function M.forget(key)
  notified[key] = nil
end

return M
