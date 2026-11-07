---
# quickfix-review-nvim-8w27
title: Store the review in the repo at .quickfix-review/ by default
status: completed
type: feature
priority: normal
created_at: 2026-11-07T20:54:47Z
updated_at: 2026-11-07T23:17:17Z
---

**Background.** The default storage dir is `stdpath('data')/quickfix-review/<basename(root)>-<sha256(root)[1..12]>` (lua/quickfix-review/store/location.lua:100-104), so a review can't be tracked with git. `project_root()` (location.lua:46-61) returns the git toplevel, or falls back to the cwd, without saying which one it returned. The headless CLI never calls `setup()` (cli.lua:12-14), but `config.options` starts out as the defaults (config.lua:387), so changing the default branch of `resolve()` also changes `scripts/qfr.lua export`, review-export, rv-done.sh and /rv.

**Decision: when the project root is a git toplevel, the review lives in `<root>/.quickfix-review/`. Tracked and ignored files sit in separate folders, and each folder marks itself.** Outside a git repo, keep today's stdpath dir and layout. Make this a change to the default, not a user `storage_dir` function: a function leaves `per_project` nil, so records keep absolute paths (store/record.lua:145-151), and the CLI never sees the setting.

```
.quickfix-review/
  events/            tracked
    .gitattributes     *.jsonl merge=union
    000001.jsonl
  snapshots/         tracked
  local/             ignored
    .gitignore         *
    lock  journal.lock  lock.stale-*
    checkpoints/
    refs/000001.refs
    gc.stamp
    tmp/               every temp file and staging dir
```

## The edit

1. `project_root()` returns a third value, `in_git`. It is true at :52 (git answered). At :60 (a transient-failure guess) it is true only when the guess came from `good_roots`.
2. In the default branch of `location.resolve()` (:100), when `in_git`: `dir = root .. '/.quickfix-review'`, `loc.in_repo = true`, and the layout above:
   - `lock = dir/local/lock`, `flock = dir/local/journal.lock`
   - `checkpoints = dir/local/checkpoints`, `refs = dir/local/refs`
   - `gc_stamp = dir/local/gc.stamp`, `tmp = dir/local/tmp`
   - `events` and `snapshots` stay at `dir/events` and `dir/snapshots`
   - `path = dir/local/comments.json`, so a legacy file can never be tracked

   Otherwise build the stdpath dir and layout as now, with `refs = events`, `gc_stamp = snapshots/gc.stamp` and `tmp = dir`, so the current paths are unchanged. Factor the stdpath name (:102-103) into a helper; step 5 uses it too. `per_project = true` in both cases.
3. Route the paths that are built outside `resolve()` through `loc`:
   - `segment.refs_path(dir, n)` (segment.lua:22): every caller passes `loc.refs`, not `loc.events`. Callers are in maintenance.lua:91,148,151 and `segment.write_refs`.
   - `gc.stamp` (maintenance.lua:116) → `loc.gc_stamp`
   - `durable_write` and `create_file` (segment.lua:68-125) take an optional tmp dir. When it is given, write the temp file there, rename or link it into place, then fsync both the target's dir and the tmp dir. Every write into `events/` or `snapshots/` passes `loc.tmp`, including `snapshots.put` (snapshots.lua:112-117).
   - Staging dirs: the `events.tmp.<pid>` in `segment.create` (segment.lua:102), plus `events.adopt-<pid>` and `events.replaced-<pid>` (adopt.lua:180,207), go under `loc.tmp`.
   - `sweep_tmp` (maintenance.lua:59) also sweeps `loc.tmp`.
4. Seed the marker files in `journal.locked` (journal.lua:86), right after `mkdir_for`, and only when `loc.in_repo`. Every writer, adopt included, goes through that function. Use `segment.create_file`, which returns `'exists'` on EEXIST and leaves the file untouched:
   - `local/.gitignore`: `*\n`
   - `events/.gitattributes`: `*.jsonl merge=union\n`
5. Migration: in `migrate.open`, before `import_legacy` (migrate.lua:199, called at :355), when `loc.in_repo`, the in-repo dir has no review, and the stdpath dir for the same root holds one (adopt's has_review: any segment or comments.json), skip `import_legacy` for this location and notify once per nvim session per root: `quickfix-review: this project's review is now kept in <root>/.quickfix-review; run :ReviewAdopt <old dir> to bring over the N comments in the old location`. Do not adopt automatically. Confirm that the adopted review's `imports` set keeps the legacy file from being imported again on the next open.
6. Adopt (store/adopt.lua): `refusal`/`location_of`/`old_root` parse only the source dir's `<name>-<hash>`. Adopting into an in-repo dir is gated only by `loc.per_project` (:157), so it needs no change beyond the staging paths in step 3. The two seeded dotfiles do not count as a review.
7. Docs:
   - config.lua:26-31 comment (it still says comments.json)
   - README "Where reviews are stored" (README.md:168-186), the ReviewAdopt/moved-projects paragraph, "Repo-relative paths" and the CLI note
   - doc/quickfix-review.txt:139-145 and its ReviewAdopt example
   - header comments in scripts/qfr.lua and cli.lua
   - docs/journal.md "Layout" (:31)

   Describe the in-repo layout, what is tracked, the union merge, and that comments follow the checked-out branch. State that a move of a git repo keeps its review with no adopt. Warn that `snapshots/` puts copies of every commented file into git history, including untracked or ignored files such as `.env`. Also state that `git reset --hard`, `git checkout -- .` and `git stash` discard comments not yet committed.

## Checklist

- [ ] Git tests run hermetically: `GIT_CONFIG_GLOBAL=/dev/null`, `GIT_CONFIG_NOSYSTEM=1`, `-c user.name=t -c user.email=t@t -c commit.gpgsign=false`.
- [ ] test/test_storage_dir.lua:
  - split `default_dir` into `stdpath_dir(root)` and `repo_dir(root)`
  - a temp git repo resolves to `repo_dir` with the paths in step 2
  - a non-git temp dir resolves to `stdpath_dir` with today's paths
  - point the two `import_legacy` fault-injection tests, the git-retry test and the retry-window tests at `repo_dir`
  - add: with `good_roots` populated and git then failing, the review stays in `repo_dir`; a cwd guess not in `good_roots` goes to stdpath
- [ ] Move-and-adopt tests run on non-git dirs. A new test checks that moving a git repo keeps its review.
- [ ] test_cli.lua: `events_path` returns `<repo>/.quickfix-review/events`, and `qfr.lua export` in a git repo reads it. The "cannot be read" test plants its file there.
- [ ] Hermeticity: `guarded_run` (test_setup.lua) and the explicit `storage_file` test also assert that no `.quickfix-review/` appeared in the plugin checkout or the repo.
- [ ] Fresh repo: add a comment, force a checkpoint, a seal, a GC and an adopt. After `git add -A`, `git status --short --ignored -- .quickfix-review` lists only `events/…` and `snapshots/…` plus `!! .quickfix-review/local/`. A simulated crash leaves its temp file under `local/tmp/`. Filenames in `events/000001.jsonl` are relative.
- [ ] An existing `local/.gitignore` and `events/.gitattributes` with different content stay byte-identical. Nothing is written to the repo's root `.gitignore` or `.gitattributes`.
- [ ] Merge: a committed base comment, then branches A and B each add one. `git merge B` from A exits 0 with no conflict markers, and after a restart `store.all()` holds base + A + B.
- [ ] Checkout, both directions, with nvim running: check out a commit with a shorter journal, then a diverged branch with a longer one (force a checkpoint first). Each sync reloads with no error, and `store.all()` is exactly that commit's set.
- [ ] Migration: plant a review in `stdpath_dir(a)` (and in a second case, a legacy `quickfix-review.json` as well). Exactly one notice per session naming the dir and the count, and `import_legacy` does not run. Then `:ReviewAdopt <stdpath_dir(a)>` brings the comments over, the stdpath dir stays byte-identical, and `qfr.lua export` from the repo lists them. Existing WARN-counting tests (e.g. test_storage_dir.lua:452) still pass.

## Do not

- Do not use the new layout for stdpath dirs or an explicit `storage_file`. An older nvim on the same review would lock `<dir>/lock` while this one locked `<dir>/local/lock`, and both would write at once.
- Do not write to the repo's root `.gitignore` or `.gitattributes`, or put any pattern list in `.quickfix-review/`. The folders mark themselves.
- Do not leave a temp file next to its target in `events/` or `snapshots/`. A crash would leave it there for `git add -A` to pick up.
- Do not delete or move the old stdpath dir during migration. Adopt only reads it.
- A union merge only resolves appends to the *same* segment. If two branches each seal and start `events/000002.jsonl`, git sees an add/add conflict between two different headers. Document this (rare at the 4 MiB `segment_max_bytes`) instead of engineering around it.
