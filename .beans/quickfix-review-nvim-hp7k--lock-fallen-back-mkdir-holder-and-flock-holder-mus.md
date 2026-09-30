---
# quickfix-review-nvim-hp7k
title: 'Lock: fallen-back mkdir holder and flock holder must exclude each other; don''t memoise ENOLCK'
status: todo
type: bug
created_at: 2026-09-30T00:48:04Z
updated_at: 2026-09-30T00:48:04Z
---

**Symptom**: after iv2p, a Neovim whose flock fails with a non-contention errno falls back to the mkdir lock (`loc.lock`) only, while a peer whose flock works takes only `loc.flock` in plain `M.with_lock` (lua/quickfix-review/store/lock.lua, `M.with_lock`). The two do not exclude each other; only `with_both` callers also take `loc.lock`. A single transient ENOLCK also makes the fallback permanent for the session (`flock_unsupported[path] = true`).
**Expected**: a process that fell back and a process on flock exclude each other for every mutation.

**Decision: on the flock path, `with_lock` also waits on a *live* `loc.lock`** (take `with_mkdir(loc.lock)` inside the flock, as `with_both` does, or at least wait while a live-pid `loc.lock` exists). Do not memoise ENOLCK (retry flock on the next call); keep memoising EOPNOTSUPP/ENOSYS/EINVAL.

## The edit

- lock.lua `M.with_lock`, flock path: after `clear_dead_v2_lock(loc.lock)`, if `loc.lock` exists and its pid is alive and not ours, wait on it via the mkdir loop (or simply take `with_mkdir(loc.lock, fn)` inside the flock, making `with_lock` and `with_both` the same on the flock path — measure the extra mkdir cost per mutation first and pick the cheaper correct one).
- `flock_unsupported`: set only for errnos other than ENOLCK.
- docs/journal.md#locking: replace the documented limitation with the new rule.

## Checklist

- [ ] Test (fake ffi): process A path falls back (holds `loc.lock` with a live pid — use a sleeper's pid written into the dir); a flock `with_lock` on the same loc waits and times out rather than running fn concurrently.
- [ ] Test: ENOLCK falls back for that call but the next call tries flock again (fake flock call count increments).
- [ ] Existing test_lock.lua tests still pass; scripts/test.sh passes; restore test_file.txt.

## Do not

- Do not run test files directly with nvim; only scripts/test.sh is hermetic.
- Do not remove a `loc.lock` whose pid is alive.
