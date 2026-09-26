---
# quickfix-review-nvim-fg4i
title: 'Setup: validate keymap values and comment_types before tearing down state'
status: todo
type: bug
priority: normal
created_at: 2026-09-26T16:43:09Z
updated_at: 2026-09-26T16:43:09Z
---

From review cycle 3 (details/repros: /tmp/claude-1001/-home-ethans-Programming-quickfix-review-nvim/cfc4ea53-3598-4975-b59b-e35c5f93f346/scratchpad/review3/opus-ui.md).

- (medium) init.lua:864 (from setup() :1294): keymap values go straight to vim.keymap.set; reanchor=true / view='' / delete_comment=true make setup() throw after the QuickfixReview augroup was cleared → no autocmds, no commands. Validate (string non-empty or false) and warn/skip bad entries; validate before clearing state.
- (low-medium) config.lua:191: list-form comment_types={'bug','todo'} passes the non-empty check then becomes {} → +/-/<leader>ca crash on nil type. Accept list form (or reject it with a clear error).
- (low-medium) config.lua:262: additional_comment_types={praise=false} throws in setup() with the same half-initialised result. Treat false as 'remove this type' or skip it.

## Done when
- [ ] Test: setup with bad keymap values warns and leaves plugin functional
- [ ] Test: list-form comment_types works (or errors clearly without half-init)
- [ ] Test: additional_comment_types entry = false doesn't throw
- [ ] scripts/test.sh passes
