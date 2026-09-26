---
# quickfix-review-nvim-rcof
title: 'Diff buffers: decode fugitive names, reject gitsigns://, retry git for new dirs'
status: todo
type: bug
priority: normal
created_at: 2026-09-26T16:43:09Z
updated_at: 2026-09-26T16:43:09Z
---

From review cycle 3 (details/repros: /tmp/claude-1001/-home-ethans-Programming-quickfix-review-nvim/cfc4ea53-3598-4975-b59b-e35c5f93f346/scratchpad/review3/fable-paths.md).

- (medium) utils.lua:404-407: fugitive percent-encodes %, #, ? in fugitive:// names; plugin never decodes → comments stored on non-existent path (notes%231.md) and real-file comments not shown there. Decode fugitive's encoding when parsing.
- (medium) init.lua:94-107 + utils.lua:382-420,456-468: gitsigns://<gitdir>//:0:<path> index buffers (buftype acwrite) pass all guards; comment stored with literal gitsigns:// filename. Parse to the worktree path or reject.
- (low) utils.lua:247-254,302-316: git -C <nonexistent dir> exits 128 and is cached as definitive not-a-repo; file whose dir is created later never gets commit/diff context. Don't cache when the dir doesn't exist (walk to nearest existing parent, or treat as retryable).

## Done when
- [ ] Test: fugitive buffer for notes#1.md maps to notes#1.md
- [ ] Test: gitsigns:// buffer maps to real path or is rejected (no literal gitsigns:// path stored)
- [ ] Test: dir created after first lookup gets repo context
- [ ] scripts/test.sh passes
