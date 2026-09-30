---
# quickfix-review-nvim-xyos
title: 'Tests: stop deleting tracked test_file.txt; refuse non-hermetic runs'
status: completed
type: bug
priority: normal
created_at: 2026-09-29T23:55:42Z
updated_at: 2026-09-30T01:27:12Z
---

**Symptom**: (1) every `scripts/test.sh` run deletes the tracked `test_file.txt` in the repo root (test/init.lua:204 `os.remove('test_file.txt')`; create_test_file at :207 writes it in cwd), so every run leaves a dirty tree. (2) Running a test file directly (e.g. `nvim --headless -c 'luafile test/test_migrate.lua'`) is not hermetic: XDG_DATA_HOME is only redirected by scripts/test.sh, so a direct run creates a review in the real `~/.local/share/nvim/quickfix-review/` and imports the real legacy `quickfix-review.json` (happened 2026-09-29 during bean 8arp; cleaned up by hand).
**Root cause**: `test_file.txt` was swept into commit 846f24d by a `git add -A`; tests use the repo root as their working directory; nothing stops a non-hermetic run.
**Expected**: test runs leave `git status` clean and can never touch real user data.

## The edit

1. `git rm --cached test_file.txt`, add `test_file.txt` to `.gitignore`.
2. test/init.lua: after prepending the repo to runtimepath (it uses `getcwd()`, so do it first), `vim.cmd.cd(<fresh tempdir>)` so `test_file.txt` and any other relative writes land in a temp dir. Check the tests that assert relative display names (`test_file.txt:5` in test_persistence.lua, test_comments.lua) still pass — they should, since display is relative to cwd.
3. test/init.lua (or test/run.lua): refuse to run unless `vim.env.XDG_DATA_HOME` is set and is not the user's real data home — e.g. scripts/test.sh exports `QFR_TEST_HERMETIC=1` and init.lua errors with a message pointing at scripts/test.sh when it is missing. Also let scripts/test.sh take optional test file names so a single file can be run hermetically (`scripts/test.sh test/test_migrate.lua`), if test/run.lua can support that cheaply.

## Checklist

- [ ] `scripts/test.sh; git status --short` → clean (no test_file.txt deletion).
- [ ] `nvim --headless --clean -c 'luafile test/test_migrate.lua' -c qa` without the env var → errors immediately, `ls ~/.local/share/nvim/quickfix-review/` unchanged (compare before/after).
- [ ] `scripts/test.sh` passes in full (baseline at b78a889: 511/511).

## Do not

- Do not delete or touch anything under the real `~/.local/share/nvim/` while testing the guard — snapshot `ls -la` before and after instead.
