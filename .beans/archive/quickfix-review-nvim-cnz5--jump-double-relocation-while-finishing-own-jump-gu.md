---
# quickfix-review-nvim-cnz5
title: 'Jump: double relocation while finishing; own_jump guard leaks into in_jump'
status: completed
type: bug
priority: normal
created_at: 2026-09-29T21:16:26Z
updated_at: 2026-09-30T00:02:55Z
---

**Symptom**: two edge cases left by the jump.lua extraction (f7n4 review, cdbac59).
1. A second relocated read while `finishing` schedules a second finish; the first finish returns to `idle` while the second is still pending, so `in_jump` and the cursor check stop seeing `finishing` in that window.
2. The own_jump guard in `M.pending` (lua/quickfix-review/jump.lua ~:116) now also applies to `in_jump` (~:130), so a DirChanged during `]r`'s own `:edit` (init.lua DirChanged autocmd) refills immediately instead of deferring. Before f7n4 the guard sat only at the relocate_buffer call site.

**Root cause**: (1) finish count not tracked in state; (2) guard moved from call site into the shared query.

**Expected**: (1) stay `finishing` until the last pending finish runs; (2) pre-f7n4 behaviour — guard only at relocate_buffer.

## The edit

- jump.lua: keep a pending-finish counter (or a finish generation id); a finish only returns to idle/holding when it is the latest.
- Move the own_jump guard out of `M.pending` back to relocate_buffer's call, or give `in_jump` its own path without it.
- Cite a test in the transition table for the `seen` row (test_qf_window.lua ~:471) and `float_opened` row (~:69, ~:484).

## Checklist

- [ ] Test: two relocations while finishing → state is `finishing` until the second finish runs; exactly one float.
- [ ] Test: DirChanged during `]r`'s `:edit` with a stale last_seen defers the refill (defer_view).
- [ ] Every row in jump.lua's transition table names a test.
- [ ] `scripts/test.sh` passes; restore `test_file.txt` before committing.

## Do not

- Do not add `vim.schedule` to fix (1); encode it in state.
