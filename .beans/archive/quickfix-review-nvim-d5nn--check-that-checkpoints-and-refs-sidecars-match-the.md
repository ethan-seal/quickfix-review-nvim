---
# quickfix-review-nvim-d5nn
title: Check that checkpoints and .refs sidecars match the segment bytes they were built from
status: completed
type: feature
priority: normal
created_at: 2026-11-07T21:31:54Z
updated_at: 2026-11-07T22:44:00Z
blocking:
    - quickfix-review-nvim-8w27
---

**Background.** `checkpoint.load` (lua/quickfix-review/store/checkpoint.lua:61-96) accepts a checkpoint when v, state_v and journal_id match, and the offset is within the segment and at a line start. It never checks the bytes before the offset. GC reads each sealed segment's `.refs` sidecar (`read_refs`, store/maintenance.lua:90) and trusts it without checking that it matches the segment's current bytes. Both are fine while the journal only grows by appends. They fail once a segment can be replaced with different bytes that keep the same header, which happens on a git checkout or merge of an in-repo journal (quickfix-review-nvim-8w27). In that case `journal.replay` (store/journal.lua:154-161) starts from the wrong state and shows the wrong comments, with no error. A stale `.refs` lets GC delete snapshots that the new bytes reference, once `GC_GRACE` (maintenance.lua:44) has passed.

**Decision: every derived file records the hash of the bytes it was built from. Load treats a mismatch as invalid (a checkpoint) or missing (a `.refs`).** Both paths already handle that case: a full replay from the previous valid checkpoint, and `rebuild(n)` (maintenance.lua:140).

## The edit

1. `checkpoint.encode` (checkpoint.lua) adds two fields:
   - `prefix_sha`: sha256 of segment `seg` over bytes `[0, offset)`
   - `sealed`: `{ {size, sha}, ... }`, one entry per segment `1 .. seg-1`, each over its whole file

   Every encode call site already has the segment bytes, or reads them under the lock.
2. `checkpoint.load` rejects the checkpoint when `prefix_sha` or `sealed` is missing (`'no content hash'`). It also rejects it when an earlier segment's size differs (check the size first, it is cheap), or when a hash differs (`'content changed'`). A checkpoint from before this change is rejected, so it costs one full replay and then gets rebuilt. No migration.
3. The `.refs` sidecar format goes from a bare JSON list to `{ "sha": <sha256 of the sealed segment>, "refs": [...] }`, written by `segment.write_refs` (segment.lua:144) and by `rebuild` (maintenance.lua:148). `read_refs` returns false (missing) for the old list format or when the hash differs from the segment's current hash. The existing rebuild path then rewrites it under the lock.
4. Docs: docs/journal.md "Checkpoints" (:96) and the load rule (:129) describe the content check. Update the header comment in checkpoint.lua:1-12 too.

## Checklist

- [ ] Same-header replacement: write a journal, force a checkpoint at offset X (low `checkpoint_every`), then replace `000001.jsonl` with different events after the same header so that it is longer than X and has a line start at X. Replay shows only the new file's comments. Run the test without the fix and confirm it fails there.
- [ ] Earlier segment changed: a checkpoint at segment 2 is rejected after `000001.jsonl` is replaced with a file of the same size but different bytes.
- [ ] An old-format checkpoint (without `prefix_sha`) is ignored, and replay matches a full replay.
- [ ] `.refs`: seal segment 1, then replace it with bytes that reference a different snapshot hash, then make that snapshot older than `GC_GRACE`. GC rewrites `000001.refs` and keeps that snapshot.
- [ ] An old list-format `.refs` is rebuilt into the new format on the next GC.
- [ ] Existing journal and maintenance tests pass unchanged: `scripts/test.sh`.

## Do not

- Do not skip the check when inode and size are unchanged. `git checkout` can leave a file with a different inode but the same size, and a freed inode can be reused right away.
- Do not hash only the line that ends at the offset. After a union merge, a sibling branch's file can hold the same line at the same offset with different bytes before it.
- Do not bump `STATE_VERSION` for this. The reduced state does not change, and the missing fields are enough to reject old checkpoints.
