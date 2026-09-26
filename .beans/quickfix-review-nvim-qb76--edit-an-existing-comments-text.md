---
# quickfix-review-nvim-qb76
title: Edit an existing comment's text
status: todo
type: feature
priority: normal
created_at: 2026-09-26T04:57:59Z
updated_at: 2026-09-26T04:57:59Z
blocked_by:
    - quickfix-review-nvim-0scv
---

Users can add and delete comments but not edit them; fixing a typo means delete + re-add (losing the anchor/context).

- `:ReviewEdit` / keymap `keymaps.edit` (default `<leader>ce`): on a line with a comment (same overlap rule as view), open `vim.ui.input` prefilled with the body (multi-line bodies: a small scratch float, `:w`/`<CR>` confirms, `q` cancels). Also allow editing `kind` via cycling in the same prompt if cheap; otherwise body only.
- Works from the review qf window on the row under cursor (resolve by user_data.id).
- Emits a single `update {set={body}, prev={body}}` event (log epic), so history/restore cover edits.
- Document in README + help.

## Done when
- [ ] Test: edit body → saved, qf text updated, id/anchor unchanged
- [ ] Test: cancel → no event
- [ ] Test: editing from qf window edits the row's comment
