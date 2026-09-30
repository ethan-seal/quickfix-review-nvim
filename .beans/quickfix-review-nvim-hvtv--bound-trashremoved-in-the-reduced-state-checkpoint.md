---
# quickfix-review-nvim-hvtv
title: Bound trash/removed in the reduced state (checkpoint size grows with every deletion)
status: todo
type: bug
created_at: 2026-09-30T01:29:01Z
updated_at: 2026-09-30T01:29:01Z
---

**Symptom**: `state.trash` and `state.removed` (lua/quickfix-review/reduce.lua, `trash()` ~:94-110) grow with every deleted comment forever, and `reduce.persisted` writes all of both into every checkpoint (written every 500 events / seal / VimLeavePre), so checkpoint write+load cost grows with total deletions. `unremove` is an O(n) scan of `removed`.
**Expected**: state size is bounded by live comments plus a bounded tail of deletions. Raw events stay forever (docs/journal.md); only the reduced state is bounded.

**Decision: prune in the reducer, deterministically.** After `trash()` appends to `removed`, if `#removed > TRASH_KEEP` (a module constant, e.g. 1000 — NOT a user config, or replay and checkpoints would disagree across configs), drop the oldest `removed` entries and their `trash[id]`. A `restore` event carries its own `comment`, so restoring a pruned id still works on replay. Bump `reduce.STATE_VERSION` so old unpruned checkpoints are rebuilt.

## Decide first: who reads `trash`/`removed`?

grep every reader (undo-delete / restore UI, history, `:ReviewRestore`-like commands). **Default: pruning is fine** if they only need recent deletions; if a UI lists all deletions, make it read from the journal (history) for entries older than the kept tail. Record: ____

## Checklist

- [ ] Test: 1 500 add+delete events → `#state.removed == TRASH_KEEP`, oldest ids absent from `trash`; replay-from-scratch equals checkpoint+tail (existing equivalence helpers in test_sealing/test_migrate).
- [ ] Test: restore of a pruned id (restore event with comment) makes it live.
- [ ] docs/journal.md: note the bound where the state shape is described.
- [ ] `scripts/test.sh` passes.

## Do not

- Do not make the bound configurable or time-based (non-deterministic replay).
- Do not run test files directly with nvim; only `scripts/test.sh` is hermetic.
