---
# quickfix-review-nvim-6m4v
title: Break the store/track/snapshots/utils require cycles
status: completed
type: task
priority: normal
created_at: 2026-09-29T20:45:42Z
updated_at: 2026-09-29T23:27:37Z
blocked_by:
    - quickfix-review-nvim-b8r8
    - quickfix-review-nvim-ugnc
    - quickfix-review-nvim-z2v4
---

**Background.** store, track and snapshots require each other, and utils requires store, so the cycle is broken with `require` calls inside functions. The load order is then implicit, and modules are hard to test in isolation. Fable and Opus flagged this (2026-09-29). After the store and init splits the graph changes, so this bean works against the post-split tree.

**Decision: utils and track are leaves.** Dependencies point one way: `init/edit/jump/signs -> store facade -> {journal, location, migrate, maintenance, view} -> {track, snapshots, log, reduce, storage} -> utils`. Anything a leaf needs from above is passed in as an argument or a callback registered at setup.

## The edit

1. Dump the current graph: `grep -n "require('quickfix-review" lua/quickfix-review -r`. Mark each require that is inside a function body.
2. For each back-edge, move the needed function down or inject it (for example `track.setup({ snapshot_get = snapshots.get })`).
3. Make every require top-of-file.

## Checklist

- [ ] `grep -rn "require('quickfix-review" lua/quickfix-review` shows no require inside a function body. (Check by `awk` for indentation > 0, or by hand, and list any exceptions with a reason in the commit body.)
- [ ] utils.lua and track.lua require no store/init/view module.
- [ ] `scripts/test.sh` passes in full.

## Do not

- Do not change behaviour.
