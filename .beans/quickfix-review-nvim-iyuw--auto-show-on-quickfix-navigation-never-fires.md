---
# quickfix-review-nvim-iyuw
title: Auto-show on quickfix navigation never fires
status: todo
type: bug
priority: high
created_at: 2026-09-26T04:31:20Z
updated_at: 2026-09-26T04:57:49Z
blocked_by:
    - quickfix-review-nvim-nep3
    - quickfix-review-nvim-l6ht
---

Auto-showing the comment float when navigating the review quickfix list never works: the handler is on QuickFixCmdPost (init.lua:543-548), which fires only for list-building commands (:make, :grep, :cexpr), not for :cnext/:cprev/:cc/:cfirst/:clast. Verified headless.

A second trap: view_comment closes its float on the next CursorMoved. Navigation itself moves the cursor, so a float opened synchronously during navigation is closed immediately (jump_comment at init.lua:267-268 already suffers from this: windows 2 → 1 once the main loop runs). BufWinEnter alone is not enough either — it doesn't fire when :cnext stays in the same buffer.

## Decision
- Remove the QuickFixCmdPost handler.
- Track the review list's current index: on `CursorMoved` and `BufEnter` in normal (non-qf) windows, when `store.is_current_view()` is true, read `vim.fn.getqflist({ id = <review qf id>, idx = 0 }).idx`; if it differs from the last seen idx AND the cursor is on that item's file/lnum, open the float via `vim.schedule(view_comment)`.
- The float's close-on-CursorMoved autocmd must be created only after the float is open and the cursor has settled (inside the scheduled callback), in the `QuickfixReviewFloat` group; apply the same fix to jump_comment.
- Respect the existing config toggle for auto-show if one exists; otherwise add `auto_show = true` to config defaults and document it.

## Done when
- [ ] Test (headless): open review list, `:cc 1`, `:cnext` → exactly one float open showing comment 2 after the event loop runs (`vim.wait`)
- [ ] Test: `]r` (jump_comment) leaves the float open
- [ ] Test: navigating a non-review quickfix list (e.g. setqflist of grep results) opens no float
