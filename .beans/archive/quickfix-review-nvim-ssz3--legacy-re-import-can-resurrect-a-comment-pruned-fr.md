---
# quickfix-review-nvim-ssz3
title: Legacy re-import can resurrect a comment pruned from the trash
status: completed
type: bug
priority: low
created_at: 2026-09-30T03:58:34Z
updated_at: 2026-09-30T05:05:49Z
---

**Symptom**: hvtv (reduce.lua `prune`, TRASH_KEEP=1000) bounds `state.trash`/`state.removed`. `migrate.lua` ~:229-243 builds the legacy re-import `known` id set from that reduced state. When a comment was deleted, then more than TRASH_KEEP later removals happened, and the legacy global comments.json changed after the import, the re-import brings the deleted comment back as live.
**Expected**: a comment deleted once is never re-imported from the legacy file.

**Decision: build `known` from the raw events** (every id that any add/import/delete event in the journal ever mentioned), not from the reduced state. The raw events are kept forever. If a scan per re-import is too costly, cache the set keyed by the segment count.

## Checklist

- [x] Test: import the legacy file, delete id X, do TRASH_KEEP+1 other deletes, touch the legacy file, sync → X stays deleted.
- [x] `scripts/test.sh` passes.

## Do not

- Do not run test files directly with nvim; only `scripts/test.sh` is hermetic.
