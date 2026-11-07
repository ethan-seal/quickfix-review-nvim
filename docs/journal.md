# Journal v3: permanent events, disposable checkpoints

This doc carries the argument for the storage redesign. The edits are in the
beans that link here: flock locking, the segmented journal with checkpoints
and the `comments.json` migration, reducer indexes, and snapshot refs/GC. Line references are as
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

## Why not the old format

The journal replaced an earlier single-log format (v2: one active `log.jsonl`
plus rotated `log.<ms>.jsonl` files, and a `state.json` cache). Support for it
has since been removed. It mixed derived state into the event stream: each
rotation copied a whole-state `checkpoint` event into the new log, and
`state.json` was a second cache of the same state with fragile validation. Its
mkdir lock also needed pid liveness checks.

## Layout

Per review, in the review's storage directory (flat, as below, in a
stdpath('data') dir, a `storage_dir` option's dir or next to `storage_file`):

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
```

In a git repo the default storage directory is `<root>/.quickfix-review/`,
laid out so that what is tracked is only what other clones need:

```
events/                       tracked
  .gitattributes              `*.jsonl merge=union`
  000001.jsonl ...            segments, as above
snapshots/                    tracked
local/                        untracked
  .gitignore                  `*`: local/ ignores itself
  journal.lock, lock
  checkpoints/
  refs/000001.refs            the `.refs` sidecars
  gc.stamp
  tmp/                        every temp file (seal, snapshot, adopt staging)
```

No temp file is ever created in `events/` or `snapshots/`, so a crash leaves
nothing there for `git add -A` to pick up; stale temps in `local/tmp/` are
swept like the others. Neither marker file is rewritten once it exists, and
the repo's own `.gitignore` and `.gitattributes` are never touched.

Since segments are only appended to, two branches that each append to the
same active segment merge cleanly with the union driver. The limit: if both
branches seal (start segment N+1) independently, each has its own
`00000N+1.jsonl`, and git reports an add/add conflict on that file, which
has to be resolved by hand. Nothing works around this.

Segment and checkpoint names are zero-padded, so sorting by name sorts by
position.

## Events

- **Segment header.** Each segment's first line is
  `{"op":"header","v":3,"journal_id":"<16 hex>","seg":N}`. Every segment of a
  journal has the same `journal_id`. It is minted once, at creation. It catches a directory that was wiped and recreated, or segments
  copied in from another review.
- **Event shape.** `op`, `eid`, `ts`, payload, with the reducer's rules.
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
- **No checkpoint events in segments.** Checkpoints are only files, loaded
  via `reduce.load_state`.
- **Append** takes the lock, appends to the highest-numbered segment, fsyncs
  and releases. Readers do not lock. They tolerate a partial last line, as
  today.
- **Sealing** happens when the active segment passes `segment_max_bytes`
  (default 4 MiB). This replaces `log_max_bytes`, and the size is fixed: it
  no longer grows with the checkpoint size. Under the lock, in order:
  1. Write `N.refs`: `{"sha": <sha256 of segment N>, "refs": [...]}`, the
     hashes referenced by segment N and the hash of the bytes they were
     read from, written with an atomic rename.
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
  `{"v":3,"state_v":S,"journal_id":…,"seg":N,"offset":O,"lines":L,"state":{comments,trash,removed,rebases},"imports":[…],"refs":[…],"prefix_sha":…,"sealed":[{"size":…,"sha":…},…]}`.
  `lines` is how many lines of segment N precede O (for warnings' line
  numbers). `refs` is the set of snapshot hashes referenced by the active
  segment up to O, so snapshot GC does not need to read the active segment.
  `prefix_sha` is the sha256 of segment N's bytes [0, O), and `sealed` has
  one `{size, sha}` per segment 1 .. N-1, each over its whole file: the
  bytes the state was built from.
- **Bounded trash.** `trash` and `removed` keep only the newest
  `reduce.TRASH_KEEP` (1000) removals, plus every removal of the newest
  removing event, so undo of the last delete or clear stays whole. The
  reducer prunes the oldest after each delete, clear and checkpoint event,
  so checkpoint size is bounded by the live comments plus that tail rather
  than by every deletion ever made. `TRASH_KEEP` is a module constant, never
  a user option: replay and checkpoints must agree for every config. Raw
  events stay forever; only the reduced state is bounded. An id pruned from
  the trash is no longer known to the reducer, so an `add` or `import` of it
  is applied rather than ignored as a duplicate, and `:ReviewTrash` /
  `:ReviewRestore {id}` cannot reach it. Introducing the bound bumped
  `STATE_VERSION` to 3.
- **Written:**
  - on sealing;
  - after an append that leaves the tail at least `checkpoint_every` events
    (default 500) or 256 KiB past the newest checkpoint;
  - on VimLeavePre when the tail is non-empty.
- **Write procedure.** Encode the state outside the lock. `prefix_sha` is
  hashed from the active segment read through one fd whose inode must still
  be the one the state was read from; each `sealed` entry was hashed when
  that segment's bytes were read into the state. If any hash is unknown, no
  checkpoint is written. Under the lock,
  write `checkpoints/<name>.tmp.<pid>`, fsync it, rename it into place,
  fsync the directory, then run checkpoint GC. Two instances writing the same
  position produce identical files, and the rename makes that harmless.
- **Valid when all hold:**
  1. `v` is 3.
  2. `state_v` equals the reducer's current `STATE_VERSION`.
  3. `journal_id` matches the segment headers.
  4. Segment `seg` exists, and `offset` is not past its end and falls on a
     line start.
  5. The content matches: `prefix_sha` is the hash of segment `seg`'s bytes
     [0, `offset`), and each `sealed` entry the size (checked first) and
     hash of its segment now. A segment can be replaced with other bytes
     behind the same header (a git checkout or merge of an in-repo
     journal), so this is checked on every load, whatever the inode or
     size. A checkpoint without the hashes (one from before them) is
     invalid too: it costs one full replay, then is rebuilt. No
     `STATE_VERSION` bump and no migration.
- **Load.** Take the newest valid checkpoint and replay from `(seg, offset)`
  to the end. If none is valid, replay from segment 1. That path is slow but
  always correct.
- **An outdated `state_v` is not an error.** It is how state-shape changes
  ship: bump `STATE_VERSION`, and old checkpoints are skipped and rebuilt.
  There is never a migration for checkpoints.

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
  removed. Restarting every Neovim
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
either. Reducer indexes are never serialised: checkpoints write only `comments`, `trash` and `removed`
(`reduce.persisted`; the last two bounded, see Checkpoints), and the index is rebuilt (`reduce.reindex`, O(n))
when a checkpoint is applied. Duplicate checks and
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
  `.refs` whose `sha` is not the segment's current hash (the segment was
  replaced), or in the old bare-list format, is treated as missing. A
  sealed segment with no `.refs` (crash) is rebuilt
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
  active segment's tail after the checkpoint is still scanned.
- **When GC stops.** GC deletes nothing when it finds no segments
  (events/ missing, or its listing failed), or when a file it needs
  can't be read or has a header this version doesn't read.

## Migration

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
  under the lock of the current dir and the lock of the old
  one, every `events/NNNNNN.jsonl` is copied (read and write, fsync'ed,
  never `link`: the active segment is appended to) into
  `events.adopt-<pid>/`, which is renamed to `events/`. Then `snapshots/`
  is copied, while `checkpoints/` and `.refs` are skipped (derived and
  rebuilt). It refuses when the current dir already holds a segment or a
  `comments.json` (no merge semantics), when the old dir
  has no journal, and outside the per-project dir. Records logged with
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
  the one nested inside the flock) still uses it to judge a stale lock.
- **2d. The mkdir lock inside the flock** (`lock.with_lock`). Where the
  mkdir lock is itself the backend, it is taken once.
- **2h. Segments are created with a temp file and `link(2)`**
  (`segment.create`): the header (and, for a new review, its import) is
  written to `events.tmp.<pid>`, fsynced, and linked to its segment name.
  `link` fails with EEXIST when another Neovim created that segment first,
  so a segment is never created twice, never seen without its header, and
  never renamed over.

**Other decisions**

- The journal interface is narrowed: `store/migrate.lua` and
  `store/sync.lua` no longer call `journal.reset/reduced/synced/set_readonly/
  unsaved`; they use `switch`, `load`, `load_readonly`,
  `read_tail`, `create`, `append` and the state views.
- **The legacy import follows the legacy review's journal**: with
  `storage_file` once set to the legacy global file, its review is read from
  `<legacy>.events/` (nothing else is read). When the legacy file changed after that
  review imported it, its records are re-imported only if their ids appear
  in none of the review's raw events (every event is replayed, so no
  checkpoint is used), not merely if its pruned state lacks them: a deletion
  pruned from the bounded trash is not resurrected. An id-less record is
  matched by file name, line and body against every comment record those
  events carried (and the live comments), so a deleted one stays deleted too.
- **`:ReviewSave` writes a checkpoint** (always).
  `VimLeavePre` still calls `store.flush()`, which writes a checkpoint only
  when events were read since the last one.
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
- **Tests.** Tests of in-place log rewrites are replaced by "a journal
  replaced by another one is loaded from the start": segments are never
  rewritten in place. `test_sealing.lua` covers sealing.
- **`:ReviewHistory`** reads segments newest first and stops once it has
  50 events (all events), or, for one comment, at a segment whose checkpoint
  does not know the comment.

## Documented unknowns (settle empirically in the beans)

1. **flock on network filesystems** (NFS, 9p, SSHFS). Linux emulates flock
   with fcntl locks on NFS; others may silently succeed. Out of scope.
   Document that the storage dir must be local.
2. **Checkpoint cadence.** Does 500 events keep the tail replay under 20 ms?
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
