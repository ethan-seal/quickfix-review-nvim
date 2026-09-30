---
# quickfix-review-nvim-pq74
title: Adding a comment blocks on up to 3 sync git calls; debounce sync autocmds
status: todo
type: bug
created_at: 2026-09-30T01:29:01Z
updated_at: 2026-09-30T01:29:01Z
---

**Symptom**: adding a comment blocks on up to three synchronous git calls: `context.capture` (lua/quickfix-review/context.lua ~:14-18, ~:110, ~:127-128) runs `rev-parse HEAD` then `git diff HEAD~1` and, on failure, `git diff HEAD`, each `vim.system(...):wait()` with a 2 s timeout (up to 6 s). Also `store.all()` (stat + header read) runs on every BufEnter/CursorHold/FocusGained (init.lua ~:465-490).
**Expected**: adding a comment never blocks on git for more than a trivial time; sync autocmds are debounced.

## The edit

- context.lua: run the git calls asynchronously (`vim.system` with a callback) and attach the captured context to the record with an `update` event when they finish; or, if the record must carry context at add time, collapse to one `git diff HEAD~1` with the `HEAD` fallback only on the specific "unknown revision" error, and cut the timeout to 500 ms. **Default: async + update event.** Record: ____
- init.lua: debounce the BufEnter/CursorHold/FocusGained sync (e.g. skip if the last sync was < 200 ms ago), keeping FocusGained immediate if a test depends on it.

## Checklist

- [ ] Test: with a stub git that sleeps 1 s, `add_comment` returns in < 100 ms and the context appears on the record afterwards.
- [ ] Test: two BufEnter events 50 ms apart → one journal stat.
- [ ] `scripts/test.sh` passes.

## Do not

- Do not write the add event without the context and then forget the update if the review was switched in between (guard with the review key).
- Do not run test files directly with nvim; only `scripts/test.sh` is hermetic.
