---
# quickfix-review-nvim-gg4b
title: 'v2 fallback mode: history walks rotated logs again; re-test rewrite check'
status: completed
type: bug
priority: normal
created_at: 2026-09-29T22:54:22Z
updated_at: 2026-09-30T00:40:16Z
---

**Symptom**: when v2→v3 migration fails verification, the review runs in v2 fallback mode. In that mode `:ReviewHistory` reads only `log.jsonl`, so history from before the last v2 rotation is missing. Pre-un0y code also walked the rotated `log.<ms>.jsonl` files.
**Root cause**: lua/quickfix-review/history_view.lua:27-32 dropped the rotated-log walk.
**Expected**: in fallback mode, history covers the rotated logs (oldest first) and then `log.jsonl`, as it did before 1bdc598.

## The edit

In history_view's v2-fallback branch, list the rotated logs with `maintenance.list_rotated` (or its current equivalent) and read them in order before `log.jsonl`. Also add back a test for the v2-mode in-place rewrite check at store/journal.lua:263-268 (different log_id, and an offset mid-line); its test_sync tests were removed in un0y.

## Checklist

- [ ] Test: fallback fixture with 2 rotated logs + log.jsonl → history lists events from all three.
- [ ] Test: v2 fallback, log replaced with another log_id → reloaded from the start.
- [ ] `scripts/test.sh` passes; restore `test_file.txt` afterwards.
