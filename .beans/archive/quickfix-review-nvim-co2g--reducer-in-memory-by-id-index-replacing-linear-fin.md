---
# quickfix-review-nvim-co2g
title: 'Reducer: in-memory by_id index replacing linear find'
status: completed
type: task
priority: normal
created_at: 2026-09-29T21:06:50Z
updated_at: 2026-09-29T21:49:10Z
blocking:
    - quickfix-review-nvim-un0y
---

**Background.** reduce.lua looks up comments with a linear `find` over `state.comments` / `state.trash` on every event, so replay is O(n²) in comment count.

**Decision: an in-memory `by_id` index maintained by the reducer, rebuilt from state on load, never serialised.** z2v4 adds `by_path` alongside it.

**Reasoning: [docs/journal.md](../docs/journal.md#indexes).**

## The edit

- reduce.lua: `state.index = { by_id = {} }` built in `new_state`/on checkpoint apply; every op that inserts/moves/removes a comment updates `by_id` (value: `{list = "comments"|"trash", item = <record>}`); `find` becomes a table lookup.
- Anything that serialises state (checkpoint writer, state cache) excludes `index`.

## Checklist

- [ ] Test: replay of a 5 000-add fixture is under 200 ms (record baseline before the change).
- [ ] Test: after each op type (add, edit, move, trash, restore, remove, checkpoint), `by_id` equals an index rebuilt from scratch.
- [ ] Encoded state contains no `index` key.
- [ ] `scripts/test.sh` passes; restore `test_file.txt` before committing.

## Do not

- Do not store positions/extmarks in the index; those belong to track.lua (z2v4).
