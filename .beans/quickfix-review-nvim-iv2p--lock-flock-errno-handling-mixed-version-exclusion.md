---
# quickfix-review-nvim-iv2p
title: 'Lock: flock errno handling; mixed-version exclusion and stale mkdir lock dir'
status: todo
type: bug
created_at: 2026-09-29T21:26:49Z
updated_at: 2026-09-29T21:26:49Z
---

**Symptom**: two gaps left by 5ajb (d303dd7).
1. `lua/quickfix-review/store/lock.lua:35-41` treats every nonzero `flock()` return as contention. On mounts that refuse flock (ENOLCK, EOPNOTSUPP) every mutation spins 1 s, then fails with "Timed out waiting for the lock".
2. A Neovim still running pre-flock code (mkdir lock) and one running the new code (flock) do not exclude each other, so concurrent rotation during an upgrade can race. A stale mkdir lock dir from an old crash is never cleaned up.

**Expected**: (1) a clear lock error naming the errno, or fall back to the mkdir lock for that path; (2) documented in README ("restart all Neovims after updating"), stale lock dir removed once it is provably dead.

**Reasoning: [docs/journal.md](../docs/journal.md#locking).**

## Decide first: on flock errno failure, error or fall back?

**Default: fall back to the mkdir lock for that path and warn once via notify.once.** Being wrong costs a later one-line change. Record: ____

## The edit

- lock.lua: declare `errno` access (`ffi.errno()`); retry only on EWOULDBLOCK/EAGAIN (11 on Linux, 35 on macOS — use `ffi.os`); on any other errno either fall back (default) or return `false, "flock failed: <strerror>"`.
- README: under storage, "after updating the plugin, restart every running Neovim".
- On the flock path, if `loc.lock` (old mkdir lock dir) exists and its pid is dead per `log.pid_alive`, remove it while holding the flock.

## Checklist

- [ ] Test: stub `ffi.C.flock` to return -1 with errno EOPNOTSUPP → no 1 s wait (elapsed < 100 ms), behaviour per the decision.
- [ ] Test: stub EWOULDBLOCK → still retries and times out as today.
- [ ] Test: stale old lock dir with a dead pid is removed after one mutation; one with this test's own live pid is left alone.
- [ ] `scripts/test.sh` passes; restore `test_file.txt` before committing.

## Do not

- Do not remove an old lock dir whose pid is alive; an old-version Neovim may be mid-rotation.
