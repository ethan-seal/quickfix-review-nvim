---
# quickfix-review-nvim-qugx
title: 'Event log: recover torn header/import, read-only fallback, stale-lock race'
status: todo
type: bug
priority: normal
created_at: 2026-09-26T06:33:01Z
updated_at: 2026-09-26T08:29:28Z
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



Note (j2ye): reduce.lua copies ev.ts into state.removed unchecked and init.lua show_trash does ts/1000 → error on a non-numeric ts from a hand-edited/foreign log line. Guard with type(ts)=="number" (as history.lua does). Also :ReviewHistory re-reads the whole log and re-warns about every bad line on each call — warn once per (log_id, line).



Note (9ljx): partial-success appends. If fs_fsync/fs_close fails after a complete write, or a short write still lands whole event lines (log.lua ~84-87), sync() applies the landed events but mutate() returns nil (store.lua ~707-709). The user then sees 'not added'/'no comment was deleted' although the change applied. Fix: log.append should report which bytes/lines landed, and mutate should return success when the event is durable in the log, or else word the failure messages as 'may be incomplete'.



Note (pkbq):
- An inf or NaN in an unknown top-level field (kept in extra) or inside context still passes normalize, and vim.json.encode then refuses the record in serialise. Sanitise non-finite numbers recursively in extra and context, or drop them with a WARN (store.lua ~132-144).
- storage.backup_once is now dead code, and test/init.lua still cleans up .pre-repair.bak. Remove both.
