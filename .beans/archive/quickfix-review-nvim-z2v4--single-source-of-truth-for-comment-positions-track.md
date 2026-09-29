---
# quickfix-review-nvim-z2v4
title: 'Single source of truth for comment positions: track.positions()'
status: completed
type: task
priority: normal
created_at: 2026-09-29T20:45:42Z
updated_at: 2026-09-29T22:10:44Z
blocked_by:
    - quickfix-review-nvim-b8r8
    - quickfix-review-nvim-ugnc
---

**Background.** A comment's position lives in five places, each with its own invalidation: the store records (`comments` in store.lua and `M.pos` at store.lua:203), the per-buffer `views` cache and `c.pos` mutated on shared view objects (track.lua), `track.marks` extmarks, sign extmarks (signs.lua after the init split), and quickfix rows (the store view module). Most tracking and display bugs in the history (stale from_disk, sign/float desync, `]r` confusion) were two of these disagreeing. All three reviewers (2026-09-29) flagged it.

**Decision: track.lua is the single source of truth for live positions.** It exposes `track.positions(bufnr_or_path) -> { [comment_id] = {lnum, end_lnum, status} }`, computed once per buffer changedtick and file stat. Signs, the quickfix view, the float and export all read that map. None of them cache positions themselves, and no one mutates `c.pos` on a shared object.

## The edit

1. Inventory every writer of `c.pos`, `views`, and position caches (`grep -n "\.pos\b\|views\[" lua/quickfix-review/*.lua lua/quickfix-review/**/*.lua`). Record it in the commit body.
2. Add `track.positions()` with one cache keyed on `(path_key, changedtick or stat)`. Make store's `M.pos`/`M.range`/`M.is_outdated` delegate to it.
3. Convert signs, the qf view and the float to read `track.positions()`. Delete their private position caches.
4. Views returned to callers are fresh tables or frozen. No caller can mutate shared position state.
5. Index comments by `path_key` so a buffer's position lookup is O(comments in that file), not O(all comments). This is reviewer finding F's hot-path part.

## Checklist

- [ ] `c.pos` is never assigned outside track.lua (grep shows zero writers elsewhere).
- [ ] Regression test: edit a commented buffer, then check the sign line, qf row lnum and float anchor all equal `track.positions()` in the same tick.
- [ ] Regression test: delete a range ending at EOF, then undo, and the comment range is restored (Sonnet 2026-09-29 found 3-4 becomes 3-3 'shifted').
- [ ] `scripts/test.sh` passes in full.

## Do not

- Do not change the anchor/snapshot persistence format.
- Do not add a new cache to fix a stale read. Invalidate the one cache.
