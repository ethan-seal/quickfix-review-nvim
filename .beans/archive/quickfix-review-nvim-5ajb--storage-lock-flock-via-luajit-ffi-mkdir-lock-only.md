---
# quickfix-review-nvim-5ajb
title: 'Storage lock: flock via LuaJIT FFI, mkdir lock only as fallback'
status: completed
type: task
priority: normal
created_at: 2026-09-29T21:06:50Z
updated_at: 2026-09-29T21:26:32Z
---

**Background.** The storage lock is an mkdir lock dir plus a pid file (log.lua `lock`/`stale`/`pid_alive`). x5ft made it never break a live holder, which leaves a crashed holder with a reused pid holding the lock forever. `lock_held` is one global flag, so holding one review's lock skips locking for another.

**Decision: flock(2) via LuaJIT FFI on `<review dir>/journal.lock`; mkdir lock kept only as the non-FFI/Windows fallback.**

**Reasoning: [docs/journal.md](../docs/journal.md#locking).**

## The edit

- New `lua/quickfix-review/store/lock.lua` exposing `with_lock(path, fn)`:
  - `ffi.cdef'int flock(int fd, int op);'`, open the lock file with `vim.uv.fs_open(path, "a", 420)`, `ffi.C.flock(fd, 6)` (LOCK_EX|LOCK_NB = 2|4); retry every 10 ms up to the current 1 s budget; unlock (`8`) and close in a `pcall`-guarded finally.
  - One fd per lock path per process; reentrancy guard keyed by path (replaces the global `lock_held`).
  - Fallback when `pcall(require, "ffi")` fails or `vim.fn.has("win32") == 1`: today's mkdir lock, moved here unchanged.
- Journal/maintenance call `lock.with_lock` instead of log.lua's lock.
- Delete pid file writing, `stale()`, `STALE_SECONDS`, `pid_alive`, break-lock paths and their tests; replace with the tests below.

## Checklist

- [ ] Test: a child `nvim --headless` takes the lock and is `kill -9`ed; the parent acquires within 100 ms.
- [ ] Test: holder alive → second process times out with the existing "storage busy" error.
- [ ] Test: holding review A's lock does not skip locking on review B (two `storage_file`s in one dir).
- [ ] Test: with `ffi` forced unavailable, the mkdir fallback path passes the existing lock tests.
- [ ] `grep -rn 'pid_alive\|STALE_SECONDS' lua/` → only in the fallback module.
- [ ] `scripts/test.sh` passes; restore `test_file.txt` before committing.

## Do not

- Do not open the lock file with `O_TRUNC` or write to it; its content is irrelevant and truncation races.
- Do not close the fd while any code path still counts the lock as held — closing any fd to the file releases a flock.
- Do not make the fallback the default on Linux/macOS "to be safe"; the whole point is kernel release on crash.
