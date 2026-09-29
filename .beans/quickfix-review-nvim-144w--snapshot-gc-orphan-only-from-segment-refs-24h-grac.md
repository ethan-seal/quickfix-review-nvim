---
# quickfix-review-nvim-144w
title: 'Snapshot GC: orphan-only from segment .refs, 24h grace, daily'
status: todo
type: task
created_at: 2026-09-29T21:06:50Z
updated_at: 2026-09-29T21:06:50Z
blocked_by:
    - quickfix-review-nvim-un0y
---

**Background.** Snapshot GC (store/maintenance.lua) regex-scans every log's bytes for hashes at each Neovim start and misses `.torn-*` logs (torn handling is in store/migrate.lua). With permanent events (journal v3) every referenced snapshot must be kept forever.

**Decision: orphan-only GC from `.refs` sidecars + the newest checkpoint's `refs` + the tail; 24 h grace; at most daily via `gc.stamp`.**

**Reasoning: [docs/journal.md](../docs/journal.md#snapshots).**

## The edit

- Journal: sealing already writes `N.refs`; add lazy rebuild — a sealed segment without `.refs` is parsed (JSON, not regex) and its `.refs` written under the lock.
- Checkpoint writer includes `refs` for the active segment up to its offset.
- maintenance.lua: live set = ∪ `.refs` ∪ newest checkpoint `refs` ∪ hashes in the tail; delete a snapshot only if absent from the live set and mtime older than 24 h; skip unless `gc.stamp` mtime is older than 24 h, then touch it. Keep the current shared-dir handling (union across reviews sharing the dir).
- Delete the byte-scan code and `.torn-*` special cases.

## Checklist

- [ ] Test: snapshot referenced only by an event in sealed segment 1 survives GC.
- [ ] Test: unreferenced snapshot aged 25 h is deleted; aged 1 h is kept.
- [ ] Test: deleting every `.refs` then running GC rebuilds them and deletes nothing referenced.
- [ ] Test: second GC within 24 h is a no-op (stamp gate).
- [ ] Test: shared dir with two reviews — a snapshot referenced only by review B survives GC run from review A.
- [ ] `scripts/test.sh` passes; restore `test_file.txt` before committing.

## Do not

- Do not trust a missing `.refs` as "no refs" — rebuild it first.
- Do not drop the grace period; a snapshot is written before its event is appended.
