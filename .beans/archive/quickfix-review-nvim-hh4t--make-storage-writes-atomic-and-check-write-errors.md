---
# quickfix-review-nvim-hh4t
title: Make storage writes atomic and check write errors
status: completed
type: bug
priority: high
created_at: 2026-09-26T04:31:20Z
updated_at: 2026-09-26T05:13:26Z
blocked_by:
    - quickfix-review-nvim-46kf
---

storage.save (storage.lua:12-18) opens the target with "w" (truncate) and never checks f:write / f:close. Crash or disk-full leaves invalid JSON; sync() then refuses every mutation. A second nvim that reads between truncate and write sees an empty file, caches {}, and — when both land in the same mtime tick (likely with coarse Linux timestamps) — its next save wipes the file.

Kept even though the append-only log (oyi9) is planned: its state.json cache reuses this helper.

## Decision
- Add `storage.atomic_write(path, str) -> ok, err`: write to `path .. '.tmp.' .. vim.uv.os_getpid()` (per-process temp so two instances never share it), check write AND close results (buffered IO reports disk-full at close), fsync, then `vim.uv.fs_rename(tmp, path)`. On any failure remove the tmp and return the error.
- storage.save uses it; store must not update its synced mtime/state when the write failed, and must surface the error via vim.notify(ERROR) including the path.
- On unparseable JSON at load: notify once with the path, and say the file will not be modified until fixed (current behaviour of refusing mutations stays).

## Done when
- [ ] atomic_write implemented and used by save
- [ ] Test: save into a read-only directory → original file byte-identical, error notified, in-memory state not marked synced
- [ ] Test: no `.tmp.*` files left behind after a successful or failed save
