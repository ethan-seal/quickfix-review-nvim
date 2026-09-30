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
log.jsonl                     v2 tombstone: after migration (see Migration),
                              and in every review born v3
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
- **Rebase events.** `{"op":"rebase","from_root":"/old/root",…}` is the one
  event that `:ReviewAdopt` appends. It goes on the end of the copied active
  segment, before the journal is moved into place; segments are never
  rewritten. It records the project root of the adopted review. Reading
  resolves an absolute filename that is strictly under a recorded
  `from_root` (it starts with `from_root .. '/'`) to the same relative path
  under the current root. When several match, the longest wins. Rebases are
  permanent and part of the state (`rebases`), so replay is deterministic. A
  `from_root` already recorded is a no-op. Versions from before rebase events
  skip it as an unknown op, and show those comments at the old path. The
  state shape change bumped `STATE_VERSION` to 2.
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
  `{"v":3,"state_v":S,"journal_id":…,"seg":N,"offset":O,"state":{comments,trash,removed,rebases},"imports":[…],"refs":[…]}`.
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
3. **Never delete anything in `events/`.** One exception: `:ReviewAdopt` replaces a target journal that never held a comment (only a header and an empty import, from before fgb6), since it holds no history to lose.

## Locking

**flock through LuaJIT FFI**: `ffi.cdef'int flock(int, int);'` and
`ffi.C.flock(fd, LOCK_EX + LOCK_NB)` on `journal.lock` (landed in 5ajb, store/lock.lua). This works in the
Neovim on this machine (it returned 0 on 2026-09-29) and needs no library
beyond libc.

- **Taking the lock.** Retry the non-blocking call with a short sleep, up to
  the current 1 s budget. Hold it only for appends, sealing, checkpoint write
  and GC, never while rendering. x5ft already moved rendering out.
- **Release is automatic.** The kernel releases the lock when the process
  exits or crashes. The mkdir lock taken inside it (below) still relies on
  its pid file, `stale()` and `STALE_SECONDS`.
- **Not reentrant across fds.** flock is per open file description. Keep one
  fd per lock file per process, plus the existing `lock_held` guard, and key
  that guard by lock path. That also fixes the Opus finding that a single
  global flag skips the lock for another review.
- **Fallback.** Without FFI (PUC Lua build) or on Windows, keep today's
  mkdir lock behind the same `with_lock` interface. Windows could use
  `LockFileEx` later.
- **Every mutation takes both locks** (hp7k). Under the flock, `with_lock`
  also takes the mkdir lock (`loc.lock`), in that order, so a Neovim still
  running pre-flock code, or a process whose flock failed and fell back
  (below), is excluded by it. The usual mkdir rules apply to `loc.lock`: one
  naming a dead pid (`log.pid_alive` false) or this process's own pid, or
  with no pid and older than `STALE_SECONDS`, is broken through break_lock;
  one naming a live pid is waited on (up to 1 s, on top of up to 1 s on the
  flock) and never removed. Trade-off: after a crash under the flock,
  recovery now also depends on pid liveness for `loc.lock`; if the dead
  holder's pid is reused by a live process, writes time out until the dir is
  removed. `with_both` is kept as the explicit call for the v3 migration and
  v2 writes; it is now the same as `with_lock`. Restarting every Neovim
  after updating is still advised (README), since older versions' own rules
  are not changed by this.
- **flock errors are not contention.** Only EWOULDBLOCK/EAGAIN (11 on Linux,
  35 on macOS/BSD) and EINTR are retried. Any other errno (ENOLCK,
  EOPNOTSUPP on some NFS/FUSE mounts) falls back (iv2p's decision) to the
  mkdir lock alone, with one warning naming the errno, instead of a 1 s
  spin then "Timed out". ENOLCK (37 on Linux, 77 on macOS/BSD) is transient:
  it falls back for that call only, and flock is tried again on the next.
  Any other errno falls back for that review for the rest of the session.
  A holder that fell back and a holder on the flock exclude each other
  through `loc.lock` (above). A nested call on a review whose flock or
  mkdir lock is already held runs under the outer lock, so a nested call
  inside an ENOLCK fallback neither retries flock nor breaks its own lock.

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
  sealed segment with no `.refs` (crash, or migrated from v2) is rebuilt
  under the lock from a 64-hex scan of its bytes (`segment.refs_of`, the same
  scan as at seal time), and the `.refs` file is written then. A checkpoint
  whose `refs` are empty past the header line is not trusted (its writer may
  have failed to read the segment): the whole active segment is scanned.
- **Removal rule.** Delete a snapshot only if it is not in the live set and
  older than 24 h. The 24 h grace covers a put whose event is still being
  written.
- **When GC runs.** At most once a day per review, gated by the mtime of a
  `gc.stamp` file, under the lock. It no longer runs at every Neovim start.
- **What is still scanned.** The regex scan over all segments is gone. The
  active segment's tail after the checkpoint is still scanned, and so are
  `log.jsonl` and its rotated logs while `log.jsonl` is not a tombstone (v2
  fallback mode, or a stray v2 log). `.torn-*` logs are ignored.
- **When GC stops.** GC deletes nothing when it finds no events and no v2
  log (events/ missing, or its listing failed), or when a file it needs
  can't be read or has a header this version doesn't read.

## Migration

### v2 → v3, one time, on first load

The goal is that no byte of any existing log is rewritten, and that a
Neovim still running the old code cannot keep writing to the old log.

Under both the v2 mkdir lock (old instances respect it) and the new flock:

1. List the v2 files oldest first: `log.<ms>.jsonl` by ms, then `log.jsonl`.
   `.torn-*` files are skipped (see "As implemented", 2b).
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
`events/`, so a manual rollback is `ln -f events/<last>.jsonl log.jsonl`
(the last v2 segment). Documented in the README and the help.

### Later format changes

- **Events are never rewritten.** A change to an event's shape ships as an
  upcaster in the reducer (keyed by the segment header `v`, or a per-event
  field) that maps old events to the new shape when they are read.
- **State-shape changes** bump `STATE_VERSION`. Old checkpoints are then
  invalid and are rebuilt by replay (see Checkpoints).
- **Legacy `comments.json` import** (store/migrate.lua) is unchanged: it
  appends an `import` event to the active segment.
- **Repo-relative filenames (bean fgb6).** A comment record's `filename`
  may be relative to the project root. `add` and `import` events write it
  that way (record.relativize) when the file is under `loc.root` and the
  review is in the default per-project dir (`loc.per_project`: one root per
  dir; never with `storage_file`, a string `storage_dir` or a function
  `storage_dir`, which may map several roots to one dir). Other files stay
  absolute. `update`, `restore`, `delete` and `clear` copy the logged
  record, so they keep whichever form it was written in. The reader
  (record.normalize via view.view_of) joins a relative name to `loc.root`,
  never the cwd, and passes an absolute one through, so old segments read
  exactly as before. **No upcaster and no `STATE_VERSION` bump:** the
  reducer and checkpoints never interpret `filename` (they key on `id`),
  so the state shape is unchanged. Resolution on read is the compatibility
  layer, and existing segments are never rewritten. *Downgrade:* an older
  plugin makes a relative name absolute against the cwd (`:p`), so it
  misplaces those comments unless Neovim runs at the project root.
- **Adopting a review (`:ReviewAdopt`, store/adopt.lua).** The dir key
  stays the realpath hash of the root. A moved project adopts its old dir:
  under both locks of the current dir (`with_both`) and the lock of the old
  one, every `events/NNNNNN.jsonl` is copied (read and write, fsync'ed,
  never `link`: the active segment is appended to) into
  `events.adopt-<pid>/`, which is renamed to `events/`. Then `snapshots/`
  is copied, while `checkpoints/` and `.refs` are skipped (derived and
  rebuilt). The tombstone `log.jsonl` is written last, with the journal's
  `journal_id`. It refuses when the current dir already holds a segment, a
  `log.jsonl` or a `comments.json` (no merge semantics), when the old dir
  has no v3 journal, and outside the per-project dir. Records logged with
  absolute names keep naming the old location: they are not remapped.

### Options

- `log_max_bytes` becomes `segment_max_bytes`. The old name is accepted with
  a deprecation note.
- `log_retention_days` is removed, because events are permanent. When it is
  set, warn once and ignore it.

## As implemented (bean un0y)

Corrections to the plan above, and where the code differs from it.

**Corrections**

- **2a. `log.pid_alive` stays.** The mkdir lock (the fallback backend, and
  the lock v2 instances take) still uses it to judge a stale lock.
- **2b. `.torn-*` files are not migrated.** They hold no finished event (a
  torn v2 log is one whose only content is a partial first record), so
  linking them in would only add undecodable lines. They are left in place.
- **2c. Rotated logs are deduplicated by inode.** A v2 rotation that
  crashed after its `link` leaves `log.<ms>.jsonl` and `log.jsonl` as one
  inode; it is linked in once, at its latest position.
- **2d. Both locks: the mkdir lock inside the flock** (`lock.with_both`).
  Where the mkdir lock is itself the backend, it is taken once. Every write
  to a review that is not yet a v3 journal takes both, so v2 instances are
  excluded from the migration and from v2-mode writes.
- **2e. Crash recovery keys on the tombstone,** not on the state of
  `events/`. While `log.jsonl` is a v2 log, any `events/` that is only a
  half-built migration (segments 1..N as linked, at most a `migrated_from`
  segment N+1 holding just its header) is removed and the migration redone.
  A journal holding anything else beside a v2 `log.jsonl` is a native one:
  it is loaded and the v2 log ignored with one warning.
- **2f. The abort path deletes `events/` and `checkpoints/`.** This is the
  one place besides checkpoint GC that deletes checkpoints; it only runs
  while the v2 log is still the review, under both locks.
- **2g. `journal_id` checks exempt the migrated segments.** Segments
  1..`migrated_from.segments` keep their v2 headers (a `log_id`, no
  `journal_id`); every later segment must carry the journal's id.
- **2h. Segments are created with a temp file and `link(2)`**
  (`segment.create`): the header (and, for a new review, its import) is
  written to `events.tmp.<pid>`, fsynced, and linked to its segment name.
  `link` fails with EEXIST when another Neovim created that segment first,
  so a segment is never created twice, never seen without its header, and
  never renamed over.

**Other decisions**

- The journal interface is narrowed: `store/migrate.lua` and
  `store/sync.lua` no longer call `journal.reset/reduced/synced/set_readonly/
  unsaved`; they use `switch`, `load`, `load_v2`, `load_readonly`,
  `read_tail`, `create`, `append` and the state views.
- **New reviews are born v3.** The first change (or the `comments.json` /
  legacy import) creates `events/000001.jsonl`, then the tombstone
  `log.jsonl` (the migration's shape, with the new `journal_id` as its
  `log_id`), so a pre-v3 Neovim refuses the review instead of starting a v2
  log beside it. It is created exclusively (a temp file hard-linked into
  place), so an old Neovim's v2 `log.jsonl` is never replaced; that is then
  the stray-v2 case. A journal with no `log.jsonl` (born before this, or a
  crash between the two) gets its tombstone on the next load.
- **The legacy import follows the legacy review's journal**: with
  `storage_file` once set to the legacy global file, its review is read from
  `<legacy>.events/` when that exists, else from `<legacy>.log.jsonl`
  (unless that is a tombstone).
- **Step 7 leaves the mkdir lock dir alone**: the migration holds it, and
  its holder removes it on release, as with every v2 write.
- **A stray `state.json`** beside a v3 journal is ignored and deleted at
  load.
- **`:ReviewSave` writes a checkpoint** (always, for a v3 journal).
  `VimLeavePre` still calls `store.flush()`, which writes a checkpoint only
  when events were read since the last one. For a review still in v2 (its
  migration failed this session) both are no-ops.
- **Code layout.** Segment files (listing, paths, `.refs`, `create`, durable
  writes) are in `store/segment.lua`; checkpoint encoding, validation,
  choosing, writing and GC in `store/checkpoint.lua`.
- **Checkpoints carry `lines`** (the line count at their offset) besides
  `seg` and `offset`, so warnings about unreadable lines keep their line
  numbers after a load from a checkpoint.
- **The tail read checks the inode** of the active segment: a segment
  replaced by another file (e.g. the journal deleted and started again by
  another Neovim) makes the journal reload from the start.
- **A no-op sync makes 2 stats**: the active segment, and segment N+1 (to
  notice a seal by another Neovim).
- **No checkpoint on switching projects**; the one on exit is only for the
  review open then.
- **A review that could not be migrated is read in v2 mode**: `log.jsonl`
  replayed (no `state.json` cache any more), written under both locks, and
  the migration retried next session.
- **Tests.** The v2 tests of in-place log rewrites (truncation, a
  replacement log with the same size) are replaced by "a journal replaced by
  another one is loaded from the start": segments are never rewritten in
  place. `test_rotation.lua` is replaced by `test_sealing.lua`.
- **`:ReviewHistory`** reads segments newest first and stops once it has
  50 events (all events), or, for one comment, at a segment that starts with
  a v2 checkpoint that does not know the comment.

**Unknown #1** is settled: a v2 instance refuses the tombstone (it is too
new), does not move it aside and does not start a fresh log
(test/test_migrate.lua; the test passed against the v2 code before this
change).

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
