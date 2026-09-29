# Journal v3: permanent events, disposable checkpoints

This doc carries the argument for the storage redesign. The edits are in the
beans that link here: flock locking, the segmented journal with checkpoints
and migration, reducer indexes, and snapshot refs/GC. Line references are as
of the store split (quickfix-review-nvim-b8r8).

## Goals

1. **Every event is kept forever, byte for byte.** Nothing the plugin does
   deletes or rewrites an event. `:ReviewHistory` can always show the full
   history of every comment.
2. **Startup and sync cost does not grow with history.** Only the tail since
   the last checkpoint is replayed.
3. **Derived data is disposable.** Checkpoints, refs sidecars and in-memory
   indexes can be deleted at any time. The next load rebuilds them from the
   events. They are never the source of truth, so a corrupt or stale one can
   only cost time, never data.
4. **No liveness heuristics in locking.** A lock is released when its holder
   exits, however it exits.

## What is wrong with v2

v2 (log.lua, store/journal.lua, store/sync.lua, store/maintenance.lua) has one active
`log.jsonl` plus rotated `log.<ms>.jsonl` files. Nothing is lost, since
`log_retention_days` defaults to nil. The problems come from mixing derived
state into the event stream:

- **A rotated log starts with a `checkpoint` event** holding the whole state,
  including every trashed comment. Each rotation copies all of it again, and
  `rotate_limit` grows to twice the head size, so rotations get rarer and
  larger.
- **`state.json` is a second, separate cache of the same state**, validated by
  log_id, inode, offset and line count. Several past bugs are in that
  validation.
- **History code has to step around checkpoint events**
  (`history.checkpoint_knows`, init.lua history walk).
- **Rotation is a multi-step rename dance**: a hard link, a `.rotating-<pid>`
  temp file, and `remove_strays` to clean up after crashes, all under a
  mkdir lock.
- **The mkdir lock needs a pid file and liveness checks.** x5ft left one known
  hole: a crashed holder whose pid is later reused keeps the lock forever.
- **Snapshot GC regex-scans log bytes** for hashes, and misses `.torn-*`
  logs.

## Layout

Per review, in the directory that holds `log.jsonl` today:

```
events/
  000001.jsonl          sealed segment
  000001.refs           snapshot hashes referenced by 000001 (derived)
  000002.jsonl          active segment: the only file appended to
checkpoints/
  000002-000000048213.json    state as of segment 2, byte 48213 (derived)
snapshots/                    unchanged, content-addressed
journal.lock                  empty file, locked with flock
                              (<storage_file>.journal.lock when storage_file is set)
log.jsonl                     v2 tombstone after migration (see Migration)
```

Segment and checkpoint names are zero-padded, so sorting by name sorts by
position.

## Events

- **Segment header.** Each segment's first line is
  `{"op":"header","v":3,"journal_id":"<16 hex>","seg":N}`. Every segment of a
  journal has the same `journal_id`. It is minted once, at creation or
  migration. It catches a directory that was wiped and recreated, or segments
  copied in from another review.
- **Events are unchanged.** They keep the v2 shape (`op`, `eid`, `ts`, payload)
  and the reducer's rules.
- **No checkpoint events in v3 segments.** The only exception is a migrated
  v2 segment 1, see Migration.
- **Append** takes the lock, appends to the highest-numbered segment, fsyncs
  and releases. Readers do not lock. They tolerate a partial last line, as
  today.
- **Sealing** happens when the active segment passes `segment_max_bytes`
  (default 4 MiB). This replaces `log_max_bytes`, and the size is fixed: it
  no longer grows with the checkpoint size. Under the lock, in order:
  1. Write `N.refs`: a JSON array of the hashes referenced by segment N,
     written with an atomic rename.
  2. Create `N+1.jsonl` with O_EXCL, containing only its header, then fsync
     it and the directory.
  3. Write a checkpoint at (N+1, end of header).

  A crash after step 1 leaves an extra refs file, which is harmless. A crash
  after step 2 leaves a new segment with no checkpoint, which is also
  harmless: the next load replays from the previous checkpoint. Sealing never
  renames or links an event file.
- **Writers stay out of sealed segments.** Sealing and appending both hold
  the lock, and a writer always appends to the highest-numbered segment. So
  nothing is written to a sealed segment.
- **Sync.** A reader holds its position `(seg, offset)` in memory. Sync
  stats the active segment and reads from `offset`. If a newer segment
  exists, it finishes the old segment first and moves on. There is no inode
  or log_id check, because segments are never replaced. A segment whose
  header `journal_id` differs from the one in memory means the journal was
  replaced, so do a full reload.

## Checkpoints

- **Content.**
  `{"v":3,"state_v":S,"journal_id":…,"seg":N,"offset":O,"state":{comments,trash,removed},"imports":[…],"refs":[…]}`.
  `refs` is the set of snapshot hashes referenced by the active segment up to
  O, so snapshot GC does not need to read the active segment.
- **Written:**
  - on sealing;
  - after an append that leaves the tail at least `checkpoint_every` events
    (default 500) or 256 KiB past the newest checkpoint;
  - on VimLeavePre when the tail is non-empty.
- **Write procedure.** Encode the state outside the lock. Under the lock,
  write `checkpoints/<name>.tmp.<pid>`, fsync it, rename it into place,
  fsync the directory, then run checkpoint GC. Two instances writing the same
  position produce identical files, and the rename makes that harmless.
- **Valid when all hold:**
  1. `v` is 3.
  2. `state_v` equals the reducer's current `STATE_VERSION`.
  3. `journal_id` matches the segment headers.
  4. Segment `seg` exists, and `offset` is not past its end and falls on a
     line start.
- **Load.** Take the newest valid checkpoint and replay from `(seg, offset)`
  to the end. If none is valid, replay from segment 1. That path is slow but
  always correct.
- **An outdated `state_v` is not an error.** It is how state-shape changes
  ship: bump `STATE_VERSION`, and old checkpoints are skipped and rebuilt.
  There is never a migration for checkpoints.
- **`state.json` is removed.** Its role is taken by checkpoints.

### Checkpoint GC

Runs under the lock, right after a checkpoint is written (so at most once per
checkpoint write, never on a timer):

1. **Delete every `*.tmp.<pid>` file in `checkpoints/`.** Temp files are only
   written under the lock, and this process holds the lock. So any temp file
   present belongs to a writer that died. There is no age or pid check.
2. **Sort the checkpoints by name.**
   - Keep the newest `checkpoint_keep` valid ones (default 2). The second is
     a fallback in case the newest is corrupted after its rename, on a
     filesystem that reorders writes.
   - Delete older valid ones.
   - Delete invalid ones. That covers files that fail to parse, have the
     wrong `journal_id`, a stale `state_v`, or a position past the end of
     the journal (restored from a backup of a different history).
3. **Never delete anything in `events/`.**

## Locking

**flock through LuaJIT FFI**: `ffi.cdef'int flock(int, int);'` and
`ffi.C.flock(fd, LOCK_EX + LOCK_NB)` on `journal.lock` (landed in 5ajb, store/lock.lua). This works in the
Neovim on this machine (it returned 0 on 2026-09-29) and needs no library
beyond libc.

- **Taking the lock.** Retry the non-blocking call with a short sleep, up to
  the current 1 s budget. Hold it only for appends, sealing, checkpoint write
  and GC, never while rendering. x5ft already moved rendering out.
- **Release is automatic.** The kernel releases the lock when the process
  exits or crashes. The pid file, `stale()`, `STALE_SECONDS` and break_lock
  are gone from the flock path. `log.pid_alive` survives only for
  maintenance's `.rotating-<pid>` stray cleanup, which v3 deletes.
- **Not reentrant across fds.** flock is per open file description. Keep one
  fd per lock file per process, plus the existing `lock_held` guard, and key
  that guard by lock path. That also fixes the Opus finding that a single
  global flag skips the lock for another review.
- **Fallback.** Without FFI (PUC Lua build) or on Windows, keep today's
  mkdir lock behind the same `with_lock` interface. Windows could use
  `LockFileEx` later.
- **Mixed versions do not exclude each other.** A Neovim still running
  pre-flock code takes the mkdir lock; the new code takes the flock. Until
  the v3 migration (which takes both), restart every Neovim after updating.
- **flock errors are not contention.** ENOLCK/EOPNOTSUPP (some NFS/FUSE
  mounts) must surface as a lock error, not a 1 s spin then "Timed out".

## Indexes

The reducer keeps `state.index.by_id` (id → live comment record; the
trash is already keyed by id) in memory, updated by every reducer function
that changes `comments`. The `by_path` index that z2v4 added for
positions is not a reducer index: it is a view-side index in
store/view.lua (`view.in_file` / `store.in_file`), built lazily from the
live comments and cleared by `set_comments`, and it is never serialised
either. Reducer indexes are never serialised: the state.json cache and the rotation
checkpoint write only `comments`, `trash` and `removed`
(`reduce.persisted`), and the index is rebuilt (`reduce.reindex`, O(n))
when a checkpoint is applied or a cache is loaded. Duplicate checks and
lookups are O(1), which removes the O(n²) cost of adding many comments;
update and delete still scan `comments` for the record's position, since
records are replaced rather than changed in place.

## Snapshots

Every event is kept, so every snapshot an event references must be kept
too, or history can't show its code. GC therefore only removes orphans:
snapshots that were written but whose event never landed (a crash between
`snapshots.put` and the append).

- **Live set.** The union of every sealed segment's `.refs` and the newest
  checkpoint's `refs`, plus the hashes in the tail after that checkpoint. A
  sealed segment with no `.refs` (crash, or migrated from v2) has its refs
  computed by parsing it, and the `.refs` file is written then.
- **Removal rule.** Delete a snapshot only if it is not in the live set and
  older than 24 h. The 24 h grace covers a put whose event is still being
  written.
- **When GC runs.** At most once a day per review, gated by the mtime of a
  `gc.stamp` file, under the lock. It no longer runs at every Neovim start.
- **No log scanning.** The regex scan of log bytes and the special handling
  of `.torn-*` logs are deleted.

## Migration

### v2 → v3, one time, on first load

The goal is that no byte of any existing log is rewritten, and that a
Neovim still running the old code cannot keep writing to the old log.

Under both the v2 mkdir lock (old instances respect it) and the new flock:

1. List the v2 files oldest first: `log.<ms>.jsonl` by ms, then `log.jsonl`.
   Include any `.torn-*` files in their time position.
2. Hard-link each into `events/` as `000001.jsonl`, `000002.jsonl`, and so
   on. The bytes are unchanged, so they keep their v2 headers.
3. Start a fresh v3 active segment `N+1` with a new `journal_id`. The first
   v3 segment's header also records `"migrated_from":{"segments":N}`, which
   tells the reader which segments are v2 and how to validate them.
4. **Verify.** Replay the new journal and compare its state with the v2
   replay (the existing `sync_data` result). If they differ, stop: remove
   `events/` and `checkpoints/`, keep using v2, and warn once. The v2 files
   were only linked, never moved, so nothing is lost.
5. Write the first checkpoint and the `.refs` files.
6. **Tombstone.** Write `log.jsonl.tmp.<pid>` containing only
   `{"op":"header","v":3,"log_id":"<old id>","moved_to":"events/"}`, and
   rename it over `log.jsonl`. The old code refuses a log whose header `v`
   is newer than it knows (log.lua `too_new`), so an old instance's next sync
   sees a new inode, rereads, and refuses to append. It does not start a
   fresh log.
7. Delete the rotated `log.<ms>.jsonl` names from the top level; their
   inodes live on in `events/`. Delete `state.json`, the lock dir and
   `.rotating-*` strays.

**Reading v2 segments.** A segment whose header has `v` 2 is read with v2
rules: a leading `checkpoint` event replaces the state only if it is in
segment 1 (the base, when retention had deleted older logs). In later v2
segments it is skipped, because the earlier segments already contain every
event it summarises.

**Crash safety.** A crash anywhere before step 6 leaves v2 fully intact and
authoritative. On the next load, a half-built `events/` with no v3 active
segment, or one that fails verification, is deleted and the migration is
redone. A crash after step 6 leaves a complete v3 journal, and step 7
cleanup is idempotent.

**Downgrade.** Not supported automatically. The v2 bytes are all in
`events/`, so a manual rollback is `ln events/<last>.jsonl log.jsonl` (the
last v2 segment). Document this in the README.

### Later format changes

- **Events are never rewritten.** A change to an event's shape ships as an
  upcaster in the reducer (keyed by the segment header `v`, or a per-event
  field) that maps old events to the new shape when they are read.
- **State-shape changes** bump `STATE_VERSION`. Old checkpoints are then
  invalid and are rebuilt by replay (see Checkpoints).
- **Legacy `comments.json` import** (store/migrate.lua) is unchanged: it
  appends an `import` event to the active segment.

### Options

- `log_max_bytes` becomes `segment_max_bytes`. The old name is accepted with
  a deprecation note.
- `log_retention_days` is removed, because events are permanent. When it is
  set, warn once and ignore it.

## Documented unknowns (settle empirically in the beans)

1. **Does a running old instance really refuse the tombstone?** Before
   replacing v2 code, add a test that runs today's `mutate_at` against a
   `log.jsonl` whose header is v3, and asserts that it refuses and does not
   recreate the log. If it doesn't refuse, the tombstone needs another form.
2. **flock on network filesystems** (NFS, 9p, SSHFS). Linux emulates flock
   with fcntl locks on NFS; others may silently succeed. Out of scope.
   Document that the storage dir must be local.
3. **Checkpoint cadence.** Does 500 events keep the tail replay under 20 ms?
   Measure after the bean lands and tune the default.

## Why not SQLite

WAL-mode SQLite would give the same locking, checkpoint and index behaviour.
But it needs `libsqlite3` through FFI:

- It fails to load on NixOS without setting `vim.g.sqlite_clib_path`
  (checked on this machine 2026-09-29).
- The plugin would no longer be dependency-free.
- The review would become a binary file that can't be grepped or read
  without a library.

This design gets the same properties with plain JSONL and one libc call.
