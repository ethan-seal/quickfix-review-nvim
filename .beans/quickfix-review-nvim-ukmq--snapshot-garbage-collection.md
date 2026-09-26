---
# quickfix-review-nvim-ukmq
title: Snapshot garbage collection
status: todo
type: task
priority: low
created_at: 2026-09-26T04:57:59Z
updated_at: 2026-09-26T04:57:59Z
parent: quickfix-review-nvim-8oi5
blocked_by:
    - quickfix-review-nvim-uv21
    - quickfix-review-nvim-j2ye
---

Snapshot garbage collection (parent epic 8oi5).

- A snapshot is live if referenced by any live comment's anchor/pos, any trash entry, or any event in retained log files (current + rotated).
- GC runs at startup (deferred via vim.defer_fn, 5s) and after rotation. Delete only unreferenced files whose mtime is older than 24h (grace period for another instance that wrote a snapshot but hasn't appended its event yet — snapshots.put touches mtime on reuse). Take the log lock while scanning + deleting.

## Done when
- [ ] Unreferenced old snapshot deleted; unreferenced fresh (<24h) kept; referenced-by-trash kept
- [ ] Two instances: B writes snapshot, A runs GC before B appends → snapshot survives
