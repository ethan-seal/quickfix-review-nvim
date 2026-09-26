---
# quickfix-review-nvim-5dyo
title: 'Event log leftovers: lock-take race, partial remove_if wording, torn-log edge cases'
status: todo
type: bug
priority: low
created_at: 2026-09-26T10:24:03Z
updated_at: 2026-09-26T10:24:03Z
---

Follow-ups from qugx review (all narrow; one rollup, don't spawn further follow-up beans):
- log.lua take(): if the lock dir vanished (renamed by a breaker) before the pid write, return 'lost' so with_lock retries instead of a hard error.
- log.lua break_lock: before renaming, re-read the pid file and only rename if it still names the pid judged stale (narrow the remaining race further; full closure not required).
- init.lua ~718: after remove_if partial landing, caller says 'no comment was deleted' although store says 'may be incomplete' — reword (e.g. 'comments may not have been deleted') when the store signals partial.
- store.lua is_torn: pass the same seen table as read_log so bad lines are warned once on first sync.
- Read-only path: load_records dropped-records WARN mentions comments.json.pre-log.bak which isn't created there; word it for the read-only case.
- A torn first line followed by appended events is still refused ('not a quickfix-review log'); consider recovering (move aside, re-migrate, then replay decodable later events) or at least name the file and a manual fix in the error.
- History values truncated to 30 chars (qb76): long bodies differing near the end look identical; show more / a diff-ish hint for body edits.

## Done when
- [ ] Test: take() with lock dir removed before pid write retries and succeeds
- [ ] Test: first sync with a bad line and comments.json beside the log warns once
- [ ] Test: partial remove_if message doesn't claim nothing was deleted
