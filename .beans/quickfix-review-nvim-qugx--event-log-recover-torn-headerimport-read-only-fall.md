---
# quickfix-review-nvim-qugx
title: 'Event log: recover torn header/import, read-only fallback, stale-lock race'
status: todo
type: bug
priority: normal
created_at: 2026-09-26T06:33:01Z
updated_at: 2026-09-26T06:33:01Z
---

Follow-ups from 0scv review:
- A short write of the header+import (or header+first event) append is never retried: torn import → empty review + "reappeared" warning; torn header → every read/mutation fails "not a quickfix-review log" until log.jsonl is removed by hand. On sync, treat a log with no complete header line, or with no decodable import while a comments.json whose sha matches nothing sits beside it and the log has no other events, as unmigrated: move the torn log aside (log.jsonl.torn-<unix>) and retry the migration.
- Unwritable storage dir holding comments.json and no log: the review is now refused entirely (before: loaded read-only). Fall back to loading comments.json read-only (writes refused with a clear ERROR), no migration.
- Stale-lock break is racy (two processes can both judge stale; one can remove the other's fresh lock). Break by renaming lock → lock.stale-<pid>-<rand> then removing it, and re-check ownership (pid file content) after acquiring.
- Tail read doesn't recheck header log_id; cheap check: re-read the first line on tail and full-replay if log_id differs.

## Done when
- [ ] Test: log.jsonl containing only a torn header + comments.json → next load migrates, comments present, torn log kept aside
- [ ] Test: read-only dir with comments.json → comments listed, add refused with ERROR
- [ ] Test: log replaced by a different log of >= size → state matches the new log
