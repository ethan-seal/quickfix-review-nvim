---
# quickfix-review-nvim-m9rq
title: Content-addressed snapshot store
status: todo
type: task
priority: high
created_at: 2026-09-26T04:57:59Z
updated_at: 2026-09-26T04:57:59Z
parent: quickfix-review-nvim-8oi5
blocked_by:
    - quickfix-review-nvim-l3ui
---

Snapshot store for line tracking (parent epic 8oi5 — read its Model and Hash canonicalisation sections).

New module `lua/quickfix-review/snapshots.lua`:
- `snapshots.hash(lines) -> sha` (canonicalisation per epic).
- `snapshots.put(lines) -> sha`: path `<storage_dir>/snapshots/<sha>`; if it exists, touch mtime (`vim.uv.fs_utime`) and return; else write tmp + fs_rename (storage.atomic_write).
- `snapshots.get(sha) -> lines|nil`: read, verify the hash matches (corrupt → nil + warn), LRU cache of 8 entries in memory.
- `storage_dir` from l3ui.

## Done when
- [ ] put/get round-trip; identical content → one file; CRLF and missing-final-newline canonicalise to the same sha as LF content
- [ ] corrupt snapshot file → get returns nil
- [ ] no tmp files left behind
