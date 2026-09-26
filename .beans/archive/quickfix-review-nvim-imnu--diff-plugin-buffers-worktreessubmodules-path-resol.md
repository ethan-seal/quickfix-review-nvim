---
# quickfix-review-nvim-imnu
title: 'Diff-plugin buffers: worktrees/submodules path resolution, non-file buffers, ]r/[r'
status: completed
type: bug
priority: normal
created_at: 2026-09-26T12:22:52Z
updated_at: 2026-09-26T12:47:07Z
---

From review cycle 2 (details and repros: /tmp/claude-1001/-home-ethans-Programming-quickfix-review-nvim/cfc4ea53-3598-4975-b59b-e35c5f93f346/scratchpad/review2/opus-edge.md, /tmp/claude-1001/-home-ethans-Programming-quickfix-review-nvim/cfc4ea53-3598-4975-b59b-e35c5f93f346/scratchpad/review2/fable-arch.md).
- utils.lua:281-290 (medium): in a linked worktree or submodule, diffview/fugitive buffers resolve to the wrong file (diffview: nonexistent <main>/wt/<rev>/... path) or the raw fugitive:// URL, because both plugins name buffers after the git dir (.git/worktrees/<wt>, .git/modules/<name>). Resolve the work tree from the git dir (read <gitdir>/gitdir or core.worktree, or git rev-parse --show-toplevel with GIT_DIR).
- init.lua:94-100 (low): add_comment accepts diff-plugin buffers mapping to no file (diffview panel, diffview://null, fugitive summary/commit buffers) and stores the URL as filename. Refuse with a clear message when the buffer maps to no real file.
- init.lua:438,444-486 (low): ]r/[r in a fugitive/diff buffer use store.range (working-file line) while signs/view/delete use utils.range_in, so the cursor lands where view says 'No comment on this line' (sign at 5, jump to 15). Use range_in for navigation in special buffers.

## Done when
- [ ] Test: fugitive and diffview buffer names inside a worktree/submodule git dir resolve to the worktree file
- [ ] Test: add in diffview://null → refused, nothing logged
- [ ] Test: ]r in a fugitive buffer lands on the signed line
