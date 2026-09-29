---
# quickfix-review-nvim-un0y
title: 'Journal v3: permanent event segments, disposable checkpoints with GC, v2 migration'
status: todo
type: feature
created_at: 2026-09-29T21:06:50Z
updated_at: 2026-09-29T21:06:50Z
blocked_by:
    - quickfix-review-nvim-5ajb
---

**Background.** v2 storage is `log.jsonl` + rotated `log.<ms>.jsonl` whose first line is a full-state `checkpoint` event, plus a separate `state.json` cache (store/journal.lua, store/sync.lua, store/maintenance.lua, log.lua). Rotation copies the whole state each time and `rotate_limit` grows to 2× the head; history code steps around checkpoint events.

**Decision: permanent numbered event segments (`events/NNNNNN.jsonl`, never rewritten), disposable checkpoints in `checkpoints/`, keep-newest-2 checkpoint GC, and a zero-copy v2→v3 migration with a tombstone `log.jsonl`.** `state.json`, rotation, `log_retention_days` and `.rotating-*` stray handling are deleted.

**Reasoning: [docs/journal.md](../docs/journal.md).** Layout, sealing order, checkpoint validity, GC rules and migration steps are specified there; implement them as written.

## The edit

1. **Unknown #1 first.** Add a test that runs the *current* `mutate_at` against a `log.jsonl` whose header is `{"op":"header","v":3,...}` and asserts it refuses and does not recreate the log. If it does not refuse, stop and report — the tombstone design needs changing.
2. **Narrow the journal interface first** (b8r8 review, unfixed): store/migrate.lua and store/sync.lua reach into journal state via `reset`, `reduced`, `set_readonly`, `synced`, `set_reappeared_key`, `clear_refusal`, `unsaved`. Replace with entry points such as `journal.load_import(loc, comments, key)`; `reduced()`/`synced()` stop returning live mutable tables.
3. `store/journal.lua` + `store/sync.lua`: segment reader/appender, `(seg, offset)` sync position, sealing at `segment_max_bytes` (default 4 MiB) in the doc's order (refs → O_EXCL next segment → checkpoint).
4. New `store/checkpoint.lua`: write (encode outside lock; tmp → fsync → rename → dir fsync under lock), validity check, load-newest-valid, GC.
5. `reduce.lua`: `STATE_VERSION` constant; v2-segment rule (leading checkpoint applies only in segment 1).
6. `store/migrate.lua`: v2→v3 per the doc's seven steps, including verify-or-abort and crash recovery of a half-built `events/`.
7. `config.lua`: `segment_max_bytes`, `checkpoint_every` (500), `checkpoint_keep` (2); `log_max_bytes` aliased with a deprecation note; `log_retention_days` warns once and is ignored.
8. History: read segments in order; remove `checkpoint_knows` special cases except the v2 segment-1 base.
9. README: storage layout, "storage dir must be local", manual downgrade command.

## Checklist

- [ ] `grep -nE "journal\.(reset|reduced|synced|set_readonly|unsaved)\(" lua/quickfix-review/store/migrate.lua lua/quickfix-review/store/sync.lua` → no hits.
- [ ] Unknown #1 test written and passing against the pre-change code (record result in Evidence).
- [ ] Migration test: v2 fixture with 2 rotated logs + active log → `events/000001..3.jsonl` hard links (same inode as originals), replayed state equals v2 state, `log.jsonl` is the tombstone, `state.json` gone.
- [ ] Migration crash test: abort after step 3 → next load discards `events/` and redoes migration; v2 bytes unchanged (sha256 before/after).
- [ ] Migration verify-mismatch test: forced mismatch → v2 stays authoritative, one warning.
- [ ] Sealing test: crossing `segment_max_bytes` creates segment N+1 with header only, `N.refs`, and a checkpoint at (N+1, header end); no event file renamed (inodes unchanged).
- [ ] Checkpoint GC test: after 5 checkpoint writes exactly 2 remain; a planted `.tmp.<pid>`, a corrupt JSON, a wrong-`journal_id` and a past-EOF checkpoint are all deleted.
- [ ] Load test: delete all checkpoints → full replay gives identical state; bump `STATE_VERSION` → old checkpoints ignored and rebuilt.
- [ ] `scripts/test.sh` passes; restore `test_file.txt` before committing.

## Do not

- Do not rename, rewrite or truncate any file in `events/`, ever — including during migration (hard-link, don't move).
- Do not write the tombstone before verification passes; after it lands, old instances can no longer write.
- Do not persist indexes in checkpoints.
- Do not delete checkpoints anywhere except checkpoint GC under the lock.
