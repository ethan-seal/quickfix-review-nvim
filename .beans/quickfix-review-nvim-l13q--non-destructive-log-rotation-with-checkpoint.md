---
# quickfix-review-nvim-l13q
title: Non-destructive log rotation with checkpoint
status: todo
type: task
priority: low
created_at: 2026-09-26T04:57:59Z
updated_at: 2026-09-26T04:57:59Z
parent: quickfix-review-nvim-oyi9
blocked_by:
    - quickfix-review-nvim-aazu
    - quickfix-review-nvim-j2ye
---

Non-destructive log rotation (parent epic). The log grows slowly (a line per mutation, plus line-tracking write-backs), so this is low priority.

- When log.jsonl exceeds `log_max_bytes` (default 5 MB): under the lock, replay the on-disk log (NOT this instance's memory) to build a checkpoint, rename log.jsonl → `log.<unix-ms>.jsonl`, create a new log with header + `checkpoint {state={comments, trash}}` event.
- Old logs are kept forever by default. Option `log_retention_days` (default nil = keep); when set, delete rotated logs older than that at startup — trash survives because it is in the checkpoint.
- Readers that see a new log_id rebuild from the checkpoint (o2 handles detection).
- :ReviewHistory reads rotated logs too (newest first) when looking for older events.

## Done when
- [ ] Rotation while another headless instance appends → no lost or duplicated events
- [ ] After rotation, state identical; trash restorable
- [ ] retention deletes only rotated files older than N days
