---
# quickfix-review-nvim-8a67
title: 'Rotation edge cases: re-rotation loop, crash-window duplicate history'
status: completed
type: bug
priority: low
created_at: 2026-09-26T10:58:50Z
updated_at: 2026-09-26T11:09:10Z
---

Follow-ups from l13q review (one rollup; don't spawn further follow-ups):
- Once the checkpoint alone exceeds log_max_bytes, every mutation rotates again (a rotated file per change). Only rotate when the log is larger than max(log_max_bytes, 2 * size of the checkpoint just written) or similar hysteresis.
- Crash between fs_link(log -> log.<ms>.jsonl) and rename(tmp -> log) leaves the rotated name as a hard link to the live inode plus a stray .rotating-<pid>; a later rotation links the same inode again and :ReviewHistory shows its events twice. On startup/rotation, remove stray .rotating-* files and skip rotated files whose inode equals the live log's (or dedupe history by inode/log_id).
- Cross-version: older plugin versions treat 'checkpoint' as unknown op and show an empty review. Consider having the reducer/reader refuse (with an ERROR to upgrade) logs whose header v is newer than it understands, and bump VERSION now so future readers can gate on it.

## Done when
- [ ] Test: tiny log_max_bytes with a checkpoint above it → N mutations do not create N rotated files
- [ ] Test: rotated file hard-linked to live log → history shows each event once
- [ ] Test: stray .rotating-* is cleaned up
