---
# quickfix-review-nvim-6t6e
title: 'Adopt: remap pre-fgb6 absolute filenames via a rebase event'
status: todo
type: feature
created_at: 2026-09-30T00:23:41Z
updated_at: 2026-09-30T00:23:41Z
---

**Background.** fgb6 made new records repo-relative and added `:ReviewAdopt` (lua/quickfix-review/store/adopt.lua). Records logged before fgb6 hold absolute filenames under the *old* root (record.lua:117-119 passes absolute names through), so after `mv` + `:ReviewAdopt` those comments still point at the old location. Segments must never be rewritten (docs/journal.md).

**Decision: adopt appends a `rebase` event `{op="rebase", from_root=<old realpath root>}` to the adopted journal; the reader maps an absolute filename under any recorded `from_root` (strictly under `from_root .. '/'`) to the same relative path under the current root.** Resolution happens on read (record.resolve_filename), like fgb6's relative paths; the event is permanent so replay is deterministic. Old code ignores the unknown op (check reduce.lua's unknown-op handling returns 'unknown op' without error).

## The edit

1. adopt.lua: after copying segments, append the `rebase` event (old root from the source dir's recorded root — find where location stores/derives it; if not recorded, take it from the `<name>-<hash>` dir by requiring the user to pass it or from the records' common prefix — pick the most reliable and document it).
2. reduce.lua: handle `rebase` by adding `from_root` to `state.rebases` (persisted in checkpoints → bump `STATE_VERSION`).
3. record.resolve_filename / view: apply rebases before the absolute pass-through.
4. Also fix: a journal holding only an empty import event counts as empty for adopt's refusal check (reviews created before fgb6's empty-import fix).

## Checklist

- [ ] Test: comment written with an absolute path (pre-fgb6 shape, hand-written segment), `mv` project, adopt → comment shows at the same file and line under the new root.
- [ ] Test: absolute path outside the old root is unchanged after adopt.
- [ ] Test: a dir whose journal holds only an empty import is accepted by adopt.
- [ ] Test: checkpoint from before the STATE_VERSION bump is ignored and rebuilt.
- [ ] `scripts/test.sh` passes (baseline at fgb6 commit: 523/523).

## Do not

- Do not rewrite existing segments.
- Do not run test files directly with nvim; only `scripts/test.sh` is hermetic.
