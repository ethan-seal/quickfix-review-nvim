---
# quickfix-review-nvim-x5ft
title: Render after releasing the storage lock; never break a live holder's lock
status: completed
type: bug
priority: high
created_at: 2026-09-29T20:45:35Z
updated_at: 2026-09-29T20:54:17Z
---

**Background.** `mutate_at` (lua/quickfix-review/store.lua:1401) runs `sync(opts)` twice (three times after a rotation) inside `locked(loc, fn)`. `sync` (store.lua:1214) calls `refresh_view()` (store.lua:275) and `on_change(comments)` (store.lua:1227, 1282), which redraw the quickfix list and every buffer's signs and float. That work happens while the cross-process lock is held. Meanwhile `log.lua` `stale()` (log.lua:219-223) breaks any lock whose dir mtime is older than `STALE_SECONDS` (10) even if the holder is alive, and `with_lock` (log.lua:283-303) busy-waits 1s on the main thread before failing. A slow render, or a holder paused by the OS or a debugger, lets a second instance break the lock mid-rotation and append to the log being rotated away, which loses the event. All three reviewers flagged this (Fable 2026-09-29 reproduced the age-based break by script).

**Decision: the lock region only reads and writes the log. Rendering happens after the lock is released.** `sync` inside `mutate_at` only updates `comments`/`synced`/`reduced` and records that a render is needed. `mutate_at` renders once after `locked()` returns.

## The edit

1. Split `sync` into a data phase and a render phase: `sync_data(opts) -> ok, changed` does everything except `refresh()`/`on_change`. `sync(opts)` = `sync_data` then render if changed (the existing behaviour for all non-locked callers). Keep the `fail()` path clearing `comments` in the data phase, with the render deferred the same way.
2. In `mutate_at`, call `sync_data` inside the lock, OR the `changed` results together, and after `locked()` returns call `refresh_view()`/`refresh_view_later()` (per `opts.defer_view`) plus `on_change(comments)` once if anything changed.
3. `stale()`: stop treating a lock as stale by age alone when its pid is readable and alive. Only use age when there is no pid (the holder crashed between its mkdir and pid write), or the pid is not alive. `pid_alive` already exists. Keep the self-pid branch.
4. Grep for other `locked(` callers (e.g. `gc`, `rotate`, `apply_retention`) and check none of them render inside the lock.

## Checklist

- [ ] Regression test: stub `on_change` to record whether the lock dir exists when it runs, do `store.add`, and assert the lock is not held during `on_change`. Observe the test fail before the edit.
- [ ] Regression test: create a lock dir with mtime 60s in the past whose pid file holds a live pid (the test's own parent/another live process). Assert `with_lock` from a different pid does NOT break it (times out instead). Assert a lock with a dead pid, or no pid and an old mtime, is still broken.
- [ ] `scripts/test.sh` passes in full.
- [ ] `grep -n "refresh_view\|on_change" lua/quickfix-review/store.lua`: no call is reachable from inside a `locked(` callback.

## Do not

- Do not drop the old-mtime + no-pid branch: that is the only recovery for a crash between `mkdir` and the pid write.
- Do not render in between the two syncs "for responsiveness". The whole point is that nothing slow runs under the lock.
- Do not change the log or rotation format.
