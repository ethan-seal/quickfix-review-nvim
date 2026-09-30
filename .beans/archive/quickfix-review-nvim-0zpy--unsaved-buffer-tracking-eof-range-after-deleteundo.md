---
# quickfix-review-nvim-0zpy
title: 'Unsaved-buffer tracking: EOF range after delete+undo; in-place edits stay current'
status: completed
type: bug
priority: normal
created_at: 2026-09-30T01:29:01Z
updated_at: 2026-09-30T02:02:46Z
---

**Symptom** (unsaved buffers, lua/quickfix-review/track.lua `from_mark` ~:490-523):
1. A range ending on the last line is not restored after deleting it and undoing: `place()` (~:458-461) sets `end_row = end_lnum` with `strict=false`, which clamps; nothing re-extends the mark after undo.
2. An in-place edit inside the range (span unchanged, mark valid) stays 'current' until the next save: `from_mark` compares line numbers only, never content.
**Expected**: (1) after `dd…u` at EOF the comment covers its original range again; (2) an edited range reads 'outdated' before saving, for records with a sha (same rule as 7dv8/24qg).

## The edit

- (1) In `from_mark`, for a range that reached EOF when placed, if the mark's end row no longer matches the expected span and the buffer content at the original lines matches `anchor.lines` again, re-run `place()`.
- (2) In `from_mark`, when the record has `sha` and the mark is valid with unchanged span, compare the buffer lines in the mark's range with `anchor.lines` (cheap: only the range, not the whole buffer); a mismatch gives 'outdated'. Cache per changedtick so it is not recomputed per call.

## Checklist

- [ ] Test (test_relocate.lua style, use `rewrite()` / undolevels trick): 3-line buffer, comment on 2-3, `2,3d` then `u` → range 2-3, state 'current'.
- [ ] Test: comment with sha on line 2, `ciw` inside line 2 without saving → 'outdated'; `u` → 'current'.
- [ ] Test: comment without sha unaffected.
- [ ] `scripts/test.sh` passes.

## Do not

- Do not hash the whole buffer on every positions() call.
- Do not run test files directly with nvim; only `scripts/test.sh` is hermetic.

## Outcome

Symptom (1) already behaved correctly (extmark undo restores the mark; 7dv8's d.invalid path does not mutate it); only regression tests were added. Symptom (2) fixed via `edited_in_place` in track.lua plus a list refresh on save in buffer_sync.lua. Known limit: edits past `ANCHOR_MAX_LINES` (50) of a range stay current until save.
