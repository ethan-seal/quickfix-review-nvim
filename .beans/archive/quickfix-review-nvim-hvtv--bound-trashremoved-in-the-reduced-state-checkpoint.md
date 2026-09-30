---
# quickfix-review-nvim-hvtv
title: Bound trash/removed in the reduced state (checkpoint size grows with every deletion)
status: completed
type: bug
priority: normal
created_at: 2026-09-30T01:29:01Z
updated_at: 2026-09-30T03:59:19Z
---

**Symptom**: `state.trash` and `state.removed` (lua/quickfix-review/reduce.lua, `trash()` ~:94-110) grow with every deleted comment forever, and `reduce.persisted` writes all of both into every checkpoint (written every 500 events / seal / VimLeavePre), so checkpoint write+load cost grows with total deletions. `unremove` is an O(n) scan of `removed`.
**Expected**: state size is bounded by live comments plus a bounded tail of deletions. Raw events stay forever (docs/journal.md); only the reduced state is bounded.

**Decision: prune in the reducer, deterministically.** After `trash()` appends to `removed`, if `#removed > TRASH_KEEP` (a module constant, e.g. 1000 — NOT a user config, or replay and checkpoints would disagree across configs), drop the oldest `removed` entries and their `trash[id]`. A `restore` event carries its own `comment`, so restoring a pruned id still works on replay. Bump `reduce.STATE_VERSION` so old unpruned checkpoints are rebuilt.

## Decide first: who reads `trash`/`removed`?

grep every reader (undo-delete / restore UI, history, `:ReviewRestore`-like commands). **Default: pruning is fine** if they only need recent deletions; if a UI lists all deletions, make it read from the journal (history) for entries older than the kept tail. Record: the readers are `:ReviewTrash` (store.trash_list), `:ReviewRestore [id]` (store.restore, last_removal), trash-id completion for :ReviewRestore/:ReviewHistory, adopt.lua, migrate.lua's known-id set, and the add/import dedupe in reduce.lua. All of them need only recent deletions, so pruning is fine. Older deletions stay in the journal and :ReviewHistory, but they can no longer be listed or restored from the UI. An add or import of a pruned id is no longer a duplicate (documented). The newest removal's eid group is never pruned, so undo of the last delete or clear stays complete. Exception: migrate.lua's legacy re-import known set really needs all deletions (follow-up bean filed).

## Checklist

- [x] Test: 1 500 add+delete events → `#state.removed == TRASH_KEEP`, oldest ids absent from `trash`; replay-from-scratch equals checkpoint+tail (existing equivalence helpers in test_sealing/test_migrate).
- [x] Test: restore of a pruned id (restore event with comment) makes it live.
- [x] docs/journal.md: note the bound where the state shape is described.
- [x] `scripts/test.sh` passes.

## Do not

- Do not make the bound configurable or time-based (non-deterministic replay).
- Do not run test files directly with nvim; only `scripts/test.sh` is hermetic.
