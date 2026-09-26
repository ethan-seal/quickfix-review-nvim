---
# quickfix-review-nvim-sxwk
title: 'Performance: refresh and relocation cost with many comments/buffers'
status: todo
type: bug
priority: normal
created_at: 2026-09-26T12:22:52Z
updated_at: 2026-09-26T12:22:52Z
---

From review cycle 2 (details, timings: /tmp/claude-1001/-home-ethans-Programming-quickfix-review-nvim/cfc4ea53-3598-4975-b59b-e35c5f93f346/scratchpad/review2/fable-arch.md, /tmp/claude-1001/-home-ethans-Programming-quickfix-review-nvim/cfc4ea53-3598-4975-b59b-e35c5f93f346/scratchpad/review2/opus-edge.md).
- track.lua:271-283 + store.lua:240-256 + utils.lua:127-145 (medium): store.refresh() is O(comments x loaded buffers) with three pos()/buf_for scans per comment — 704 ms per refresh at 300 comments / 101 buffers, paid on every logged change. Build a filename->bufnr map once per refresh; call pos() once per comment.
- track.lua:189-202 (medium): relocation diffs the whole file once per comment with no cache per (anchor sha, content sha); 200 comments on a 20k-line file freeze reload/save/unloaded-file export ~3 s each. Cache the vim.diff hunks per (snapshot sha, current content hash) and map all comments sharing an anchor sha through one diff.
- track.lua:363-379 (low): from_mark's invalid-extmark path re-runs vim.diff against the snapshot on every pos() call while a commented range stays deleted. Cache the result per (buffer changedtick, comment id).
- track.lua:219,286-294 (low): track.contents[buf] is never cleared on BufWipeout (leak). Clear it in the BufWipeout handler with utils.forget_buffer.

## Done when
- [ ] Test/bench: 300 comments over 100 buffers → refresh under ~50 ms (assert a generous bound or count pos() calls)
- [ ] Test: N comments sharing one anchor sha → vim.diff called once per relocate pass (stub/count)
- [ ] Test: BufWipeout clears track.contents
