---
# quickfix-review-nvim-46kf
title: Make test suite hermetic
status: todo
type: task
priority: high
created_at: 2026-09-26T04:57:33Z
updated_at: 2026-09-26T04:57:33Z
---

The documented test command (`nvim --headless -c 'lua dofile("test/run.lua")' -c 'qall'`) loads the user's init.lua and installed plugins. With a real config the screen-string test at test/test_signs.lua:329 (screenstring call ~line 356) fails; with `--clean` the suite is 50/50. Every autonomous bean run will see a red suite until this is fixed, so this goes first.

## Decision
- Tests always run with `nvim --headless --clean` (no user config, no installed copy of this plugin). Keep test/run.lua's rtp prepend of cwd.
- Add a one-line entry point `scripts/test.sh` (or `make test`) running exactly: `nvim --headless --clean -c 'lua dofile("test/run.lua")' -c 'qall'` and propagating the exit code.
- Update test/README.md and any per-file commands to use `--clean`.
- Make the screen-string test robust: prefer asserting extmark/sign priority and placement via `nvim_buf_get_extmarks(..., {details=true})`; keep a screen assertion only if it passes reliably under `--clean`.

## Done when
- [ ] `scripts/test.sh` exists, exits non-zero on failure
- [ ] Suite passes 100% under `--clean`, run 3x in a row
- [ ] test/README.md documents the command
- [ ] test_signs.lua:329 no longer depends on UI rendering (or is proven stable under --clean)
