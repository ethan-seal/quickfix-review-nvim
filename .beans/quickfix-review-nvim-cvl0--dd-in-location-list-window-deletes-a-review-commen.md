---
# quickfix-review-nvim-cvl0
title: dd in location-list window deletes a review comment
status: todo
type: bug
priority: high
created_at: 2026-09-26T04:31:20Z
updated_at: 2026-09-26T04:57:49Z
blocked_by:
    - quickfix-review-nvim-nep3
---

The `FileType qf` autocmd (init.lua:583-610) applies to location-list windows too, and delete_comment_from_qf (init.lua:505-518) only checks `store.is_current_view()` (global quickfix stack). Pressing `dd` on row N of any `:lopen` window deletes review comment #N — verified headless (count 1 → 0). The same hook forces wrap/number/relativenumber and binds `dd`, `<leader>cd` and a hardcoded `<leader>cr` in every qf window (grep, LSP references).

Also: `FileType qf` fires again on every refill of the window (setqflist, :colder), so maps set while the review list was showing stay behind after grep/LSP replaces it.

## Decision
- Runtime guard (what actually protects data): delete_comment_from_qf returns early with a message unless `vim.fn.win_gettype() == 'quickfix'` AND `store.is_current_view()`. (Verified: win_gettype returns "loclist" for location lists.)
- Set the buffer-local maps and window options only when the qf window shows the review list; when a refill shows another list, remove the maps (`pcall(vim.keymap.del, 'n', lhs, {buffer=buf})`) and leave options alone.
- Remove the hardcoded `<leader>cr` map in the qf hook entirely (stale; the global `keymaps.load` map already exists).

## Done when
- [ ] Test: loclist window + `dd` → review comment count unchanged
- [ ] Test: review list shown, then replaced via setqflist with other items → `dd` no longer mapped in that qf buffer
- [ ] Test: review list `dd` still deletes the right comment
