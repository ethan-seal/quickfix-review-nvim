---
# quickfix-review-nvim-8w27
title: Store the review in the repo at .quickfix-review/ by default
status: todo
type: feature
created_at: 2026-11-07T20:54:47Z
updated_at: 2026-11-07T20:54:47Z
---

**Background.** The default storage dir is `stdpath('data')/quickfix-review/<basename(root)>-<sha256(root)[1..12]>` (`lua/quickfix-review/store/location.lua:100-104`), so reviews can't be tracked with git. `project_root()` (`location.lua:46-61`) returns the git toplevel or falls back to the cwd, without saying which one it returned. The headless CLI never calls `setup()` (`lua/quickfix-review/cli.lua:12-14`), so `review-export`, `rv-done.sh` and `/rv` (all of which go through `scripts/qfr.lua`) only see the *default* location.

**Decision: when the project root is a git toplevel, the default storage dir is `<root>/.quickfix-review/`. Track the journal and snapshots and ignore everything else.** Outside a git repo (cwd fallback), keep today's stdpath dir. Do this by changing the default, not through a user `storage_dir` function: a function leaves `per_project` nil, so records keep absolute paths (`store/record.lua:145-151`) and the CLI never sees the setting.

## The edit

1. `project_root()` returns a third value, `in_git` (true only when `utils.git_toplevel` answered). A transient-failure guess counts as in-git only if it came from `good_roots`.
2. `location.resolve()`, in the default branch (`location.lua:100`): if `in_git`, then `dir = root .. '/.quickfix-review'`, else the stdpath dir as now. `per_project = true` in both cases, so paths stay relative to the root.
3. When the in-repo dir is first created (the same place `events/` is first made), write two files into it if they are missing. Never overwrite them.
   - `.quickfix-review/.gitignore`:
     ```
     /checkpoints/
     /journal.lock
     /lock
     /comments.json
     ```
   - `.quickfix-review/.gitattributes`:
     ```
     events/*.jsonl merge=union
     ```
4. Migration: the first time a project resolves to the in-repo dir and that dir has no review, check whether its stdpath dir (the old default name for the same root) holds a review. If it does, notify once: `quickfix-review: this project's review is now kept in <root>/.quickfix-review; run :ReviewAdopt <old dir> to bring over the N comments in the old location`. Do not adopt automatically.
5. `store/adopt.lua`: `refusal`/`location_of` assume the old dir is `<name>-<hash>` under stdpath, which still holds for the source. Check that adopting *into* an in-repo dir works, and allow it if `loc.per_project` is the only gate (`adopt.lua:157`).
6. Docs: the `config.lua:26-31` comment (it still says `comments.json`), README "Where reviews are stored" (`README.md:168-186`) and `doc/quickfix-review.txt:139-145`. Describe the in-repo default, what is tracked, the union merge, and that comments now follow the checked-out branch.

## Checklist

- [ ] `test/test_storage_dir.lua`: a temp git repo resolves to `<root>/.quickfix-review`, and a non-git temp dir still resolves to the stdpath dir. Update the existing default-dir test (`:120`).
- [ ] Adding a comment in a fresh repo creates `.quickfix-review/{events,snapshots,.gitignore,.gitattributes}`. After `git add -A`, `git status --short` lists only `events/…` and `snapshots/…` under it, plus the two dotfiles.
- [ ] An existing `.quickfix-review/.gitignore` with different content is left byte-identical.
- [ ] Recorded filenames in `events/000001.jsonl` are relative (no leading `/`).
- [ ] Merge test: branch A and branch B each add one comment to the same journal, then `git merge` B into A. The merge completes with no conflict, and replay shows both comments plus the comments from before the branch point.
- [ ] Checkout test: with nvim running, check out a commit where the journal is shorter. The next sync marks the review stale and reloads (`journal.lua:220-223`) with no error, and the quickfix list shows the older set.
- [ ] Migration: a repo with a review only in its stdpath dir gets the notice once. `:ReviewAdopt <old dir>` copies the comments in, and `qfr.lua export` from the repo root lists them.
- [ ] `nvim --clean -l scripts/qfr.lua export` run in a git repo reads `.quickfix-review/` (the CLI uses the new default).

## Do not

- Do not write to the repo's root `.gitignore` or `.gitattributes`. Keep both files inside `.quickfix-review/` so the plugin never edits user files.
- Do not track `checkpoints/`. Their names are byte offsets into a segment (`000001-000000300821.json`), so they are wrong after any checkout and only stay harmless while untracked.
- Do not delete or move the old stdpath dir during migration. Adopt only reads it.
- Union merge only resolves appends to the *same* segment. If two branches each seal and start `events/000002.jsonl`, git sees an add/add conflict between two different headers. Document this (rare at the 4 MiB `segment_max_bytes`) instead of engineering around it.
- `git reset --hard`, `git checkout -- .` and `git stash` discard comments not yet committed. Say so in the README; the plugin can't prevent it.
