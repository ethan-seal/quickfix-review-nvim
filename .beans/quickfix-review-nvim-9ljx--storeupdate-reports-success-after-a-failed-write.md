---
# quickfix-review-nvim-9ljx
title: store.update reports success after a failed write
status: todo
type: bug
priority: normal
created_at: 2026-09-26T05:40:56Z
updated_at: 2026-09-26T06:33:01Z
---

When `storage.save` fails (disk full, read-only dir), `store.update` (store.lua ~164-196) sends the ERROR notify and re-syncs, but still returns `fn`'s result. So `store.add` returns true and add_comment prints "ISSUE added" right after the error; `remove_if` returns a count although nothing was removed. Visible in test_persistence "a failed save leaves the file intact" output.

## Decision
- `update()` returns nil when the write fails (same as the refused/unreadable case); callers already handle nil (vj7e): add_comment warns instead of printing "added", delete paths report the failure.
- Also fix the misleading bad-`item_format` WARN in export.lua (~37-43): it prints the pcall error after "using the default:"; say "invalid item_format (<err>); using the default <fmt>".

## Done when
- [ ] Test: add into a read-only storage dir → no "added" message, add returns false, count unchanged
- [ ] Test: delete with failing write → reports failure, comment still listed
- [ ] Test: bad item_format WARN text contains the default format string



Note (0scv, event log): store.lua was rewritten — mutations now append events to log.jsonl under a lock (log.lua) and the in-memory state is the reducer output. Re-verify this bean against the new code: an append failure (lock timeout, short write, read-only dir) must make add return false / delete report failure, with no "added" message.
