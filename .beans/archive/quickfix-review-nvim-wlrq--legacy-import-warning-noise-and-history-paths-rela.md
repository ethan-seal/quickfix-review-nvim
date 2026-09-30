---
# quickfix-review-nvim-wlrq
title: Legacy import warning noise and history paths relative to root
status: completed
type: bug
priority: normal
created_at: 2026-09-30T00:23:41Z
updated_at: 2026-09-30T01:17:54Z
---

**Symptom**: two small fgb6 leftovers.
1. The legacy import's "not importing N comment(s)" warning (lua/quickfix-review/store/migrate.lua ~:262-268) counts invalid records across the whole legacy file and fires before the empty-import early return, so a project that imports nothing warns once per session until its first change (was once in total).
2. `:ReviewHistory` (lua/quickfix-review/history.lua ~:57-61, `where(r)`) applies `fnamemodify(':.')` to the raw logged filename, so repo-relative names show relative to the root, not the cwd, when cwd != root.
**Expected**: (1) warn only about this project's dropped records, and only when something would be imported; (2) history resolves the filename against the project root (record.resolve_filename) before making it cwd-relative.

## Checklist

- [ ] Test: legacy file with invalid records only in another repo → no warning for this project.
- [ ] Test: cwd = a subdir of the root, history row shows the path relative to cwd.
- [ ] `scripts/test.sh` passes.

## Do not

- Do not run test files directly with nvim; only `scripts/test.sh` is hermetic.
