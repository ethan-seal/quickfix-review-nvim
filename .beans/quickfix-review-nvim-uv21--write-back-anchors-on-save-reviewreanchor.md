---
# quickfix-review-nvim-uv21
title: Write back anchors on save; :ReviewReanchor
status: todo
type: feature
priority: normal
created_at: 2026-09-26T04:57:59Z
updated_at: 2026-09-26T04:57:59Z
parent: quickfix-review-nvim-8oi5
blocked_by:
    - quickfix-review-nvim-hdzw
---

Write-back and re-anchoring (parent epic 8oi5).

- On BufWritePost of a real file (not BufLeave/BufEnter — unsaved edits must never rewrite stored anchors): for comments in that buffer whose state is current/shifted, read the tracking extmark positions and the canonical sha of the saved buffer content from the same buffer state; `snapshots.put`; emit ONE `update {set={anchor={sha,lnum,end_lnum,lines,before,after}, pos=...}}` per changed comment. Outdated comments are left alone (keep their original anchor).
- `:ReviewReanchor` (and keymap `keymaps.reanchor`, default none): on an outdated comment under the cursor, accept its current position — re-anchor to current content, state current. Document it.

## Done when
- [ ] Edit above a comment, :w, close and reopen nvim → comment at the shifted line, state current (no double shift)
- [ ] Unsaved edits then :q! → stored anchor unchanged
- [ ] :ReviewReanchor clears outdated
