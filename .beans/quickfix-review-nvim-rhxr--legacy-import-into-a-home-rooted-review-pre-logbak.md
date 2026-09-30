---
# quickfix-review-nvim-rhxr
title: Legacy import into a HOME-rooted review; .pre-log.bak clobbered
status: todo
type: bug
created_at: 2026-09-30T01:29:01Z
updated_at: 2026-09-30T01:29:01Z
---

**Symptom** (legacy import, lua/quickfix-review/store/migrate.lua):
1. When the storage dir is shared (`loc.shared`, ~:267-269) the whole legacy file is imported into the one review; when the project root is `$HOME` (non-git cwd) the `is_under` filter admits nearly everything.
2. The project `comments.json` → `.pre-log.bak` rename (~:90-113, `fs_rename` ~:109) has no existence check, so a second migration overwrites an earlier backup.
**Expected**: (1) no silent whole-file import into a `$HOME`-rooted review; (2) never clobber a backup.

## The edit

- (1) If `loc.root` equals `vim.env.HOME` (or `/`), skip the legacy import and warn once (notify.once) naming `:ReviewAdopt`/the legacy file. Shared mode keeps importing everything (it is every project's review by design) — just document it in README.
- (2) Before the rename, if the `.bak` exists, rename to `<name>.pre-log.<unix ms>.bak` instead.

## Checklist

- [ ] Test: cwd = fake HOME (set `vim.env.HOME` to a temp dir, not a git repo) with a legacy file holding records under it → nothing imported, one warning.
- [ ] Test: existing `.pre-log.bak` is kept; the new backup gets a timestamped name.
- [ ] `scripts/test.sh` passes.

## Do not

- Do not touch the real HOME in tests; set `vim.env.HOME` to a temp dir.
- Do not run test files directly with nvim; only `scripts/test.sh` is hermetic.
