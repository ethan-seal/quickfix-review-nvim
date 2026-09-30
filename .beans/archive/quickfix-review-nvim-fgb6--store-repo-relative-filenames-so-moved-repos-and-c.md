---
# quickfix-review-nvim-fgb6
title: Store repo-relative filenames so moved repos and clones keep their review
status: completed
type: feature
priority: normal
created_at: 2026-09-29T20:45:42Z
updated_at: 2026-09-30T00:23:41Z
blocked_by:
    - quickfix-review-nvim-b8r8
---

**Background.** Reviews are keyed by the realpath of the project root (`project_root`/`resolve` in the store location module, formerly store.lua:339-403, dir `<name>-<hash>`), and every record stores an absolute `filename` (`normalize`, formerly store.lua:135-195). Moving or renaming the repo, or opening a clone or another worktree, silently shows an empty review. The old comments are orphaned in another dir. Opus and Sonnet flagged this (2026-09-29).

**Decision: records store repo-relative paths when the file is inside the project root. Absolute paths remain for files outside it.** On load, relative paths resolve against the current project root. This is a log format change, so it goes with a version bump and a migration.

## Decide first: how a moved repo finds its old review dir

**Default: keep the realpath-hash dir key, and add a `:ReviewAdopt <old-dir>` command that copies or links an orphaned review into the current project's dir.** The alternative, keying the dir on the git root commit id, finds clones automatically, but it merges unrelated worktrees' reviews and fails for non-git dirs. Record the choice: ____

## The edit

1. `normalize`: when `filename` is under `store.root()`, store it relative (`./`-free, forward slashes). Otherwise keep it absolute.
2. The reader resolves relative filenames against `store.root()`. Absolute ones pass through unchanged (so old logs read as before).
3. New events write the relative form. Existing logs are not rewritten; rotation checkpoints naturally re-emit relative records.
4. Implement the Decide-first choice.
5. Update README storage notes.

## Checklist

- [ ] Test: add a comment, `mv` the project dir, adopt the old review, and the comment shows at the same file and line.
- [ ] Test: a log with absolute filenames written before this change still loads unchanged.
- [ ] Test: a file outside the root keeps an absolute path.
- [ ] `scripts/test.sh` passes in full.

## Do not

- Do not resolve relative paths against cwd. Always use the project root (Fable 2026-09-29: store.lua:184 resolves against cwd today, which is wrong when cwd != root).
- Do not rewrite existing log lines in place.
