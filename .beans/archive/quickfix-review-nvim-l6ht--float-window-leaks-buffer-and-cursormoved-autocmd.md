---
# quickfix-review-nvim-l6ht
title: Float window leaks buffer and CursorMoved autocmd per view
status: completed
type: bug
priority: normal
created_at: 2026-09-26T04:31:20Z
updated_at: 2026-09-26T07:10:37Z
blocked_by:
    - quickfix-review-nvim-nep3
---

view_comment (init.lua:272-334) creates a scratch buffer each time with default `bufhidden=hide`, so every view leaks a buffer permanently (measured: 3 views → +3 buffers). It also doesn't close a previous float first, so floats stack until the next cursor move; the CursorMoved close autocmd is `once=true`, so those do clean up on the next move (measured +3 then 0) but are ungrouped.

view_comment also only matches `item.lnum == line` (init.lua:277), while signs, delete_comment and export treat the whole `lnum..end_lnum` range as the comment: cursor on L6 of an L5-7 comment prints "No comment on this line" (verified).

## Decision
- `vim.bo[buf].bufhidden = 'wipe'`.
- Keep the current float's win id in module state; close it (if valid) before opening a new one.
- Close autocmds go in the `QuickfixReviewFloat` augroup (from the augroup bean); clear the group on WinClosed of the float.
- Match with the same overlap test as delete: `item.lnum <= line and (item.end_lnum or item.lnum) >= line`. If several comments overlap, show all of them in the one float, in lnum order.

## Done when
- [ ] Test: 3 consecutive views → buffer count and float count back to baseline after closing
- [ ] Test: cursor on middle line of a range comment opens its float
- [ ] Test: two overlapping comments → one float containing both



Note (from nep3): `QuickfixReviewFloat` is created with `clear = false`; each float's close autocmd deletes itself by id (init.lua ~331-339). Build on per-float removal, not a group clear.
