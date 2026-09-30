---
# quickfix-review-nvim-pq74
title: Adding a comment blocks on up to 3 sync git calls; debounce sync autocmds
status: completed
type: bug
priority: normal
created_at: 2026-09-30T01:29:01Z
updated_at: 2026-09-30T04:10:35Z
---

**Symptom**: adding a comment blocks on up to three synchronous git calls: `context.capture` (lua/quickfix-review/context.lua ~:14-18, ~:110, ~:127-128) runs `rev-parse HEAD` then `git diff HEAD~1` and, on failure, `git diff HEAD`, each `vim.system(...):wait()` with a 2 s timeout (up to 6 s). Also `store.all()` (stat + header read) runs on every BufEnter/CursorHold/FocusGained (init.lua ~:465-490).
**Expected**: adding a comment never blocks on git for more than a trivial time; sync autocmds are debounced.

## The edit

- context.lua: run the git calls asynchronously (`vim.system` with a callback) and attach the captured context to the record with an `update` event when they finish; or, if the record must carry context at add time, collapse to one `git diff HEAD~1` with the `HEAD` fallback only on the specific "unknown revision" error, and cut the timeout to 500 ms. **Default: async + update event.** Record: async. The add event keeps the no-git buffer-snippet context. rev-parse HEAD, then diff HEAD~1, then diff HEAD (only when HEAD~1 has no hunk for the line) run through vim.system callbacks. When they finish, store.set_context logs one update setting `context`, pinned to the add-time review key. It is skipped if the add failed, the review key changed, the comment is gone, or git found nothing. git_toplevel stays synchronous (cached per file path), so the first comment on an uncached file can still wait up to 1 s. The BufEnter/CursorHold sync is skipped when the last debounced sync was under 200 ms ago, no other sync has run since, and the review key is the same. FocusGained stays immediate.
- init.lua: debounce the BufEnter/CursorHold/FocusGained sync (e.g. skip if the last sync was < 200 ms ago), keeping FocusGained immediate if a test depends on it.

## Checklist

- [x] Test: with a stub git that sleeps 1 s, `add_comment` returns in < 100 ms and the context appears on the record afterwards.
- [x] Test: two BufEnter events 50 ms apart → one journal stat.
- [x] `scripts/test.sh` passes.

## Do not

- Do not write the add event without the context and then forget the update if the review was switched in between (guard with the review key).
- Do not run test files directly with nvim; only `scripts/test.sh` is hermetic.
