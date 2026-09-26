---
# quickfix-review-nvim-j2ye
title: :ReviewTrash, :ReviewRestore, :ReviewHistory
status: todo
type: feature
priority: normal
created_at: 2026-09-26T04:57:59Z
updated_at: 2026-09-26T04:57:59Z
parent: quickfix-review-nvim-oyi9
blocked_by:
    - quickfix-review-nvim-0scv
---

Recovery commands on top of the append-only log (parent epic). Keep it small: history listing + restore. No per-instance undo (undefined once two instances interleave).

- `:ReviewTrash` — opens a scratch list (or quickfix list with a distinct title) of deleted/cleared comments from `state.trash`, newest first: time, kind, file:line, first line of body, id.
- `:ReviewRestore [id]` — restore the given id; without an argument, restore the most recently deleted comment (or all comments of the most recent `clear` if that was the last removal — ask to confirm with the count). Appends `restore` events. Completion over trash ids.
- `:ReviewHistory [id]` — show the event history (from the log) for one comment or the last 50 events: time, op, kind, file:line, changed fields from `update.set/prev`.
- Document all three in README + help; regenerate doc/tags.

## Done when
- [ ] delete then `:ReviewRestore` → comment back with same id and content, signs shown
- [ ] `:ReviewClear` (confirmed) then `:ReviewRestore` → all back
- [ ] restore of an id that is live → message, no event
- [ ] history shows add/update/delete for one comment in order
