---
# quickfix-review-nvim-oyi9
title: Append-only event log for comment storage
status: todo
type: epic
priority: high
created_at: 2026-09-26T04:39:13Z
updated_at: 2026-09-26T04:57:50Z
---

Epic: make comment storage append-only so no save/update/delete can lose data; the current state is a rebuildable cache of the log. User requirement: "data is never lost; if we overwrite something, we can recover".

Built on: quickfix-review-nvim-n9cc (stable ids, vim.json), hffh (schema v2 = event payload), l3ui (per-project dir), hh4t (atomic_write for the cache).

## Log format — `<storage_dir>/log.jsonl`
- First line of every log file: `{"op":"header","log_id":"<16 hex>","v":1}`.
- One JSON object per line, every record terminated by `\n`, never pretty-printed.
- Ops (each has `eid` = instance nonce (vim.uv.random, per nvim process) .. "-" .. counter, and `ts` unix ms — ts is informational only, ORDER IS FILE ORDER):
  - `add {comment}` — full v2 comment
  - `update {id, set={field=value}, unset=[field...], prev={field=oldvalue}}` — prev makes history/undo local
  - `delete {id, comment}` — full comment at time of deletion
  - `clear {comments=[...]}` — full comments
  - `restore {id, comment}`
  - `import {source_sha256, comments=[...]}` — migration

## Reducer rules
- add of an id that is live or deleted → ignored (warn once); makes re-appends idempotent.
- update/delete of an unknown or deleted id → ignored (no resurrection).
- restore → comment becomes live with the logged content (if already live: ignored).
- Deleted comments are kept in a `trash` map in the reduced state (for restore).

## Writing
- Append via `vim.uv.fs_open(path, 'a', 420)`, ONE `fs_write` of the whole line, check bytes written == #line, `fs_fsync`, `fs_close`. Never hold the fd between events. (Not io.open: stdio buffering splits long lines into several write(2) calls that can interleave across processes.)
- Lock around append (and rotation/migration): `mkdir <dir>/lock` with a `pid` file inside; stale if pid not alive or older than 10s; retry up to 1s, then error without writing.
- After a short write, append `\n` before the next record.

## Reading
- Skip ANY line that fails to decode (not just the last), warn with line number.
- Tail reads stop at the last `\n`; never advance the offset over trailing bytes without a newline (another instance's in-flight write).

## Cache — `<storage_dir>/state.json`
`{log_id, offset, state={comments, trash}}`, written with atomic_write on VimLeavePre and every 50 events — never required for correctness. Rebuild by full replay if missing/corrupt, log_id differs, or log size < offset.

Children split this into implementable pieces.
