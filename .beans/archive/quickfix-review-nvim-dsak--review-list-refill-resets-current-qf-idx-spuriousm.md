---
# quickfix-review-nvim-dsak
title: Review list refill resets current qf idx (spurious/missed auto-show)
status: completed
type: bug
priority: normal
created_at: 2026-09-26T07:20:29Z
updated_at: 2026-09-26T08:06:29Z
---

Follow-up from iyuw review. store.lua refill `setqflist({}, 'r', {items=...})` (on add/edit/delete/relocation, store.lua ~204 and refresh_view ~704) passes no idx, so the current entry resets to 1:
- a plain cursor move onto entry 1's line then opens the float (auto_show_check sees an idx change);
- :cnext into a file whose comments relocate on read refills the list before the scheduled check → no float, and the user's position in the list is lost.

## Decision
- Preserve the current entry across refills: find the previously current item's comment id (user_data.id) in the new items and pass that idx (fallback: clamp old idx).
- Re-seed auto-show's last_seen after every refill so a refill never counts as navigation.
- Nit: when last_seen is nil / a different list id, the first BufEnter/CursorMoved counts as a change — seed last_seen when the review list is (re)created.

## Done when
- [ ] Test: idx 3, add a comment elsewhere → idx still points at the same comment
- [ ] Test: after a refill, plain cursor move onto entry 1 opens no float
- [ ] Test: :cnext into a file whose comment relocates on read → float shows that comment



=== Notes from completed beans (orchestrator) ===
- aazu made refresh_view keep the qf selection on every refill: it reselects the same comment by user_data.id, or else the same position clamped to the new length. M.show() on an existing view also keeps the selection now. The idx half of this bean is DONE, so don't redo it.
- Still open: re-seed auto-show's last_seen after programmatic refills. When the clamped idx changes (the selected comment was deleted), auto-show may still fire spuriously on the next CursorMoved. Verify that and fix it.
- aazu follow-up nits, fold in here if cheap:
  - sync with nothing new costs two fs_stat calls (log plus check_reappeared on comments.json);
  - a log rewritten in place with the exact same byte size is not detected until the next append (store.lua read_log early return).
