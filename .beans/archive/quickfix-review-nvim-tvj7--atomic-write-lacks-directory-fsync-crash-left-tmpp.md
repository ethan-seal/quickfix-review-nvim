---
# quickfix-review-nvim-tvj7
title: atomic_write lacks directory fsync; crash-left .tmp.<pid> files never swept
status: completed
type: bug
priority: normal
created_at: 2026-09-30T01:29:01Z
updated_at: 2026-09-30T04:26:46Z
---

**Symptom**: (1) `storage.atomic_write` (lua/quickfix-review/storage.lua ~:12-49; callers snapshots.lua ~:119, export.lua ~:123) fsyncs the file but not the directory after `fs_rename` (~:44), so a crash can lose a just-written snapshot. (2) Crash-left `*.tmp.<pid>` files from `atomic_write`, `segment.durable_write` (segment.lua ~:74) and segment creation are never collected (only `checkpoint.gc` sweeps its own dir).
**Expected**: renames are durable; stale temp files are swept.

## The edit

- storage.lua `atomic_write`: call `segment.fsync_dir(dirname(target))` after the rename (watch for require cycles — 6m4v; if storage cannot require store.segment, move `fsync_dir` to utils or storage and have segment use it).
- store/maintenance.lua: in the daily GC pass (gc.stamp-gated), remove `*.tmp.<pid>` files in the review dir, `events/` and the snapshots dir whose pid is dead (`log.pid_alive`) and whose mtime is > 1 h old.

## Checklist

- [x] Test: a `.tmp.<dead pid>` file older than 1 h in events/ and snapshots/ is removed by `maintenance` with `opts.force`; one with this process's pid is kept.
- [x] `grep -n fsync_dir lua/quickfix-review/storage.lua` → a hit.
- [x] `scripts/test.sh` passes.

## Do not

- Do not remove a tmp file whose pid is alive (another Neovim may be mid-write).
- Do not run test files directly with nvim; only `scripts/test.sh` is hermetic.
