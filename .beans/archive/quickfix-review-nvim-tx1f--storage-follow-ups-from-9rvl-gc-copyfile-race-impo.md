---
# quickfix-review-nvim-tx1f
title: 'Storage follow-ups from 9rvl: GC copyfile race, import WARN repeats, header-without-import, snapshot put pin'
status: completed
type: bug
priority: normal
created_at: 2026-09-26T16:55:16Z
updated_at: 2026-09-26T17:50:42Z
---

Leftovers from 9rvl (all should-fix, narrow).

- store.lua:1288-1295,1317-1328 vs rotate :1146-1147: GC now reads rotated logs outside the lock, but rotate's fs_copyfile fallback (no hard links) creates the rotated file then fills it; a concurrent GC can read it half-copied, accept it (header complete) and delete old snapshots referenced only in the uncopied tail. Fix: rotate copies to a temp name then renames into place (or GC re-reads under the lock any rotated file whose size/mtime changed). Also fix the comment claiming rotated logs are 'renamed into place'.
- store.lua:820,831,877-881: while an import keeps failing it's retried every sync; the WARNs ('not importing N comment(s) ... invalid line number', 'not importing from <legacy_log>', 'not importing from <legacy>') repeat each sync. Gate them once per log per session like import_failure_notified.
- store.lua:1381-1386 with 888-895: if the in-change import retry fails but the change's own append succeeds, mutate_at writes header+events and the project counts as imported without legacy comments. When the log is empty and import_tried[loc.log] unset, don't write the header / abort the change with an error.
- snapshots.lua:101 via context.lua:163 / init.lua:583,1260: snapshots.put resolves snapshots_dir before mutate's pin; if the retry window expires between put and add, snapshot and event land in different dirs. Resolve the location once for the whole add flow (pin before anchor/put, or pass loc).

## Done when
- [ ] Test: rotate without hard links never exposes a partially written rotated log under its final name
- [ ] Test: repeated syncs with a failing import warn once
- [ ] Test: failed in-change import doesn't leave a header+event log that skips legacy import
- [ ] Test: retry window expiring between snapshot put and add keeps both in one dir
- [ ] scripts/test.sh passes

Note (from jou7): track.lua:109 norm() and context.lua:132-140 slice() still strip only a single trailing CR (snapshots.canonical now strips all trailing CRs), so the search fallback can miss a CR CR line read from disk. Make them match canonical. Add a test.

Note (from rcof): utils.lua:354-358 worktree_of with git_toplevel walk-up (:314-319): if a fugitive/gitsigns gitdir's main-repo prefix no longer exists, git_toplevel(prefix) now walks up to an enclosing repo and worktree_of caches that (e.g. /home/u/deleted-repo/.git maps files to /home/u/<rel> when /home/u is a repo). Fall back to prefix when the prefix dir does not exist. Add a test.
