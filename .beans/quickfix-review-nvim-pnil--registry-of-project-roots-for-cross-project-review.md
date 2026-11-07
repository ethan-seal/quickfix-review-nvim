---
# quickfix-review-nvim-pnil
title: Registry of project roots for cross-project review lookup
status: draft
type: feature
created_at: 2026-11-07T20:54:55Z
updated_at: 2026-11-07T20:54:55Z
blocked_by:
    - quickfix-review-nvim-8w27
---

**Background.** Once reviews live in each repo (quickfix-review-nvim-8w27), there is no single place to list every project's review. Today `ls ~/.local/share/nvim/quickfix-review/` does that job.

**Decision: keep a registry of project roots at `stdpath('data')/quickfix-review/roots.json`, and add a `qfr.lua roots` command that prints it.** The registry only lists roots. Reviews stay in the repos.

## The edit

- When the store first writes an event for an in-repo location, add `{ root, dir, last_seen }` to `roots.json` (atomic write: tmp + rename, under its own lock). Bump `last_seen` at most once per session per root.
- `cli.lua`: add a `roots` command that prints a JSON array of the entries whose `dir` still exists, so stdout stays parseable.
- README and help: document the registry and the command.

## Checklist

- [ ] Commenting in two temp repos gives two entries in `roots.json`. `qfr.lua roots` prints both.
- [ ] After deleting one repo's `.quickfix-review/`, `roots` omits that entry and does not error.
- [ ] Two headless nvims adding comments in different repos at the same time both end up in the registry (no lost update).

## Do not

- Do not have the registry hold or cache comments. It goes stale as soon as a branch is switched.
