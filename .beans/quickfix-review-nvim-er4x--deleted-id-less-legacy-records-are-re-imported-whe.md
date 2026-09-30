---
# quickfix-review-nvim-er4x
title: Deleted id-less legacy records are re-imported when the legacy file changes
status: todo
type: bug
priority: low
created_at: 2026-09-30T05:05:59Z
updated_at: 2026-09-30T05:05:59Z
---

**Symptom**: in `import_legacy` (lua/quickfix-review/store/migrate.lua, the `known_loc` set next to `known = lr.ids`), a legacy record with no id is matched by filename, lnum and body against the **live** `state.comments` only. So if the user deletes a comment that came from an id-less legacy record, it is imported again the next time the legacy file changes. This bug predates ssz3, which fixed the same problem for records that have ids.
**Expected**: an id-less legacy record that was imported once and then deleted is never imported again.

**Decision: build `known_loc` from the raw events, as ssz3 did for ids.** While `journal.replay` fills `ids`, also collect the filename/lnum/body key of every comment carried by an import/add/restore event and by a checkpoint's state (comments and trash). Normalize with `record.normalize(c, loc.root)` so the keys match the ones built from `file_list`.

## Checklist

- [ ] Test: a legacy file with an id-less record → imported. Delete that comment, change the legacy file (add another record), sync → only the new record is imported.
- [ ] `scripts/test.sh` passes.

## Do not

- Do not run test files directly with nvim; only `scripts/test.sh` is hermetic.
