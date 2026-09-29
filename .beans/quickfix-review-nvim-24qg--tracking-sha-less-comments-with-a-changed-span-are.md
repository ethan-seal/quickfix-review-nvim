---
# quickfix-review-nvim-24qg
title: 'Tracking: sha-less comments with a changed span are no longer re-anchored on save'
status: todo
type: bug
created_at: 2026-09-29T23:37:18Z
updated_at: 2026-09-29T23:37:18Z
---

**Symptom**: since 7dv8, a comment with no anchor sha (legacy, or its snapshot could not be saved) whose extmark span changes in-session (a line inserted or deleted inside the range) reads 'outdated'. buffer_sync (lua/quickfix-review/buffer_sync.lua:118) skips 'outdated' comments on save, so the comment is not re-anchored. After a reload, relocate puts it back at its stale stored lines as 'current' (track.lua:213). Before 7dv8 it read 'shifted' and was re-anchored.
**Root cause**: the span check in `from_mark` (track.lua:487-492) returns 'outdated' without considering that a sha-less comment has nothing to be outdated against.
**Expected**: a sha-less comment follows its extmark on save, as before 7dv8: it is re-anchored at the mark's current rows.

## The edit

In `from_mark`, apply the span-change → 'outdated' rule only when the comment has an anchor sha. For a sha-less comment keep the pre-7dv8 result ('shifted' with the mark's rows).

## Checklist

- [ ] Test: sha-less comment on 4-5 of a 10-line file, `5GoX`… or `4GddP`-style edit that changes the span, save → stored range follows the mark; reload → same range.
- [ ] Existing 7dv8 tests (`4Gdd`, `3Gcjxx`, `3G2dd`+`u` on 3-4 at EOF) still pass.
- [ ] `scripts/test.sh` passes; restore `test_file.txt` afterwards.

## Do not

- Do not add a second position cache; track.lua must not require store/init/view (6m4v).
