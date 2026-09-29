---
# quickfix-review-nvim-f7n4
title: Extract jump detection and the review float into a jump.lua state machine
status: completed
type: task
priority: normal
created_at: 2026-09-29T20:45:35Z
updated_at: 2026-09-29T21:16:16Z
---

**Background.** lua/quickfix-review/init.lua infers whether a cursor move was a quickfix jump (to show the float and handle E925) from about nine loose module locals: `last_seen` (init.lua:399), `own_jump` (438), `float_state` (537), `hold_next_move` (540), `jump_finishing` (554), plus `pending_jump` and friends. They are set and cleared from separate autocmds. The last several bug beans (e.g. quickfix-review-nvim-y4k3: float closed by CursorMoved after finish_jump, `]r` misdetected as a qf jump) were all interleavings of these flags. All three reviewers (2026-09-29) flagged it.

**Decision: move jump detection and the review float into `lua/quickfix-review/jump.lua`, as one explicit state machine.** It has a single `state` field (e.g. `idle | own_jump | finishing | holding`) and a transition function. Every autocmd calls `jump.on_event(name, args)` instead of reading and writing flags.

## The edit

1. List every read and write of the jump/float flags in init.lua (`grep -n "own_jump\|jump_finishing\|hold_next_move\|last_seen\|pending_jump\|float_state" lua/quickfix-review/init.lua`). Write the state/transition table as a comment at the top of jump.lua first, derived from the current behaviour.
2. Implement jump.lua with the state, transitions, and the float open/close. init.lua's autocmds and `]r`/`[r`/qf-navigation handlers call into it.
3. Keep behaviour identical: existing tests in test/test_qf_window.lua and test/test_comments.lua are the spec.

## Checklist

- [ ] `grep -c "own_jump\|jump_finishing\|hold_next_move\|pending_jump" lua/quickfix-review/init.lua` is 0.
- [ ] jump.lua has a state/transition table comment, and each transition in it has a matching test (add any that are missing, especially the y4k3 and `]r` regressions).
- [ ] `scripts/test.sh` passes in full.
- [ ] init.lua shrinks by at least the moved code (record before/after `wc -l`).

## Do not

- Do not change user-visible float/jump behaviour. If the table exposes a case that looks wrong, file a bean rather than changing it here.
- Do not use `vim.schedule` to paper over an ordering problem. Encode the ordering as a state.
