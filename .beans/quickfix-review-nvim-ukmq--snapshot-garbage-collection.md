---
# quickfix-review-nvim-ukmq
title: Snapshot garbage collection
status: todo
type: task
priority: low
created_at: 2026-09-26T04:57:59Z
updated_at: 2026-09-26T06:43:25Z
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



Note (m9rq): snapshots live in store.snapshots_dir() (<storage_dir>/snapshots, or <storage_file>.snapshots in legacy mode). put() treats a same-size existing file as valid and only touches mtime — while here, compare sha256 when sizes match so a corrupt same-size snapshot gets rewritten. Buffer lines containing NUL round-trip split (hash is still consistent).



Note (2kae): NUL bytes in buffer lines (nvim_buf_get_lines returns them as 
) make canonical() produce extra lines, so anchor lnum no longer indexes the snapshot. Encode NUL losslessly in snapshots (or split on 
 only at join boundaries) and test.
