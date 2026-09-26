---
# quickfix-review-nvim-0scv
title: Event log core, reducer, cache and migration
status: completed
type: task
priority: high
created_at: 2026-09-26T04:57:59Z
updated_at: 2026-09-26T06:33:01Z
parent: quickfix-review-nvim-oyi9
blocked_by:
    - quickfix-review-nvim-hffh
    - quickfix-review-nvim-l3ui
    - quickfix-review-nvim-hh4t
---

Implement the core of the append-only log described in the parent epic (read it: format, reducer rules, writing, reading, cache sections are the spec).

Scope:
- New module `lua/quickfix-review/log.lua`: header creation, `append(event)`, tolerant `read(from_offset) -> events, new_offset`, lock helper.
- Reducer `lua/quickfix-review/reduce.lua` (pure): `apply(state, event) -> state` implementing the epic's rules, incl. trash.
- store.lua mutations (add/remove/clear/update) append events instead of rewriting comments.json; in-memory state = reducer output. state.json cache with log_id/offset per epic.
- Migration (in this bean because without it existing data disappears): if log.jsonl is absent and comments.json exists → under the lock write header + one `import` event with all comments and `source_sha256` of comments.json, fsync, then rename comments.json → comments.json.pre-log.bak. On load, if an import with the same source_sha256 is already in the log, skip (idempotent after a crash between append and rename).
- Keep sync-on-mutation behaviour: before appending, read the log tail so the reducer sees other instances' events (full multi-instance tail sync on idle is the next bean).

## Done when
- [ ] Unit tests for reducer rules (add dup, update after delete, restore, clear → trash)
- [ ] Torn line in the MIDDLE of the log is skipped; records after it load
- [ ] Trailing bytes without newline are not consumed; offset stays before them
- [ ] Record > 8 KB appended concurrently from two headless nvim processes (vim.system) 50x each → 100 valid records
- [ ] Delete state.json → identical state after rebuild
- [ ] Migration: crash simulated between import append and rename → reload doesn't duplicate comments; .pre-log.bak present after success
- [ ] Full existing suite still passes
