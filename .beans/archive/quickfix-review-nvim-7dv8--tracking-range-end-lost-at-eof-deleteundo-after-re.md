---
# quickfix-review-nvim-7dv8
title: 'Tracking: range end lost at EOF (delete+undo after reload; last-line delete reads ''shifted'')'
status: completed
type: bug
priority: normal
created_at: 2026-09-29T22:11:02Z
updated_at: 2026-09-29T23:37:18Z
---

**Symptom**: comment ranges touching the last line of a file lose their end.
1. File reloaded from a shorter version (write 2 lines, then 10), comment on 9-10, `9G2dd`, `u` → comment is 9-9 'shifted' instead of 9-10 current. Pending test: test/test_relocate.lua ~:154-184.
2. 4-line file, comment on 3-4: `4Gdd` (delete only the range's last line) or `3Gcjxx` (change both lines) → 3-3 'shifted' instead of 'outdated'. Same at HEAD before z2v4; untested.

**Root cause**: likely the extmark end encoding — `place` in lua/quickfix-review/track.lua sets `end_row`/`end_col` at (end_lnum, col 0), and `from_mark` clamps the end. Unconfirmed.

**Expected**: (1) undo restores 9-10; (2) status 'outdated'.

## The edit

- Confirm the cause with a probe printing the tracking extmark's `{row, col, end_row, end_col}` before/after each step.
- Encode the end so it survives EOF deletion+undo and distinguishes "last line deleted" from "range moved" (e.g. end at (end_lnum-1, #line) with `end_right_gravity`, or compare the tracked text against the anchor snapshot before calling it 'shifted').

## Checklist

- [ ] Un-pend the test_relocate.lua EOF test; it passes.
- [ ] New test: plain (no reload) 4-line file, comment 3-4, `3G2dd` then `u` → 3-4 current.
- [ ] New tests: `4Gdd` and `3Gcjxx` on a 3-4 comment in a 4-line file → 'outdated'.
- [ ] `scripts/test.sh` passes with 0 pending; restore `test_file.txt` before committing.

## Do not

- Do not add a second position cache; track.lua's per-path cache is the single source (z2v4).
