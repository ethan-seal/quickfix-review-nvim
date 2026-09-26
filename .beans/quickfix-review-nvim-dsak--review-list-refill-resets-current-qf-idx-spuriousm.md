---
# quickfix-review-nvim-dsak
title: Review list refill resets current qf idx (spurious/missed auto-show)
status: todo
type: bug
priority: normal
created_at: 2026-09-26T07:20:29Z
updated_at: 2026-09-26T07:20:29Z
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
