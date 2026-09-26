---
# quickfix-review-nvim-aazu
title: Multi-instance tail sync for the event log
status: completed
type: task
priority: normal
created_at: 2026-09-26T04:57:59Z
updated_at: 2026-09-26T07:26:28Z
parent: quickfix-review-nvim-oyi9
blocked_by:
    - quickfix-review-nvim-0scv
---

Multi-instance sync for the append-only log (parent epic). Replaces the old mtime-based reload.

- On `FocusGained`, `BufEnter`, `CursorHold` and before any mutation: stat log.jsonl; if size > our offset, read the tail (log.read from offset) and apply events; refresh the qf view and signs only if state changed.
- If the header log_id changed (rotation by another instance) → rebuild from the new log (checkpoint + tail).
- Autocmds in the QuickfixReview augroup.

## Done when
- [ ] Two headless instances: A adds, B's next BufEnter shows it without explicit reload
- [ ] A deletes, B's `dd` on the same comment is a no-op (update/delete of deleted id ignored), no error
- [ ] No state change → no qf list rebuild (qf list id/changedtick unchanged)
