---
# quickfix-review-nvim-wo1v
title: 'Tests: single-file runs fail (test_relocate needs setup from an earlier file)'
status: todo
type: bug
created_at: 2026-09-30T01:45:02Z
updated_at: 2026-09-30T01:45:02Z
---

**Symptom**: `scripts/test.sh test/test_relocate.lua` fails 3 tests with "E492: Not an editor command: ReviewReanchor" on a clean tree; the full `scripts/test.sh` run passes. Some test files rely on setup (plugin commands registered by `require('quickfix-review').setup()` or plugin/ loading) done by an earlier file in `test/run.lua`'s `default_files` order.
**Expected**: every test file passes when run alone via `scripts/test.sh test/<file>`.

## The edit

- Find the missing setup (grep where `ReviewReanchor` is created; check whether test/init.lua or run.lua sources `plugin/` or calls setup) and do it in test/init.lua (or at the top of each dependent file), not by relying on file order.

## Checklist

- [ ] `for f in test/test_*.lua; do scripts/test.sh $f >/dev/null || echo FAIL $f; done` → no FAIL lines.
- [ ] Full `scripts/test.sh` still passes with the same count.

## Do not

- Do not run test files directly with nvim; only `scripts/test.sh` is hermetic.
