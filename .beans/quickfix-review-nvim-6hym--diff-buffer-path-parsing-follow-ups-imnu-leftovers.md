---
# quickfix-review-nvim-6hym
title: Diff-buffer path parsing follow-ups (imnu leftovers)
status: in-progress
type: bug
priority: low
created_at: 2026-09-26T12:47:07Z
updated_at: 2026-09-26T13:09:31Z
---

Leftovers accepted in imnu (don't spawn further follow-ups from this bean).
- utils.lua:334-344: diffview git-dir parsing handles worktrees/<n> OR a chain of modules/<n>, not both; a submodule inside a linked worktree (.git/worktrees/wt/modules/sub/<rev>/f) takes 'modules' as the revision. Parse any sequence of worktrees/<n> and modules/<n> segments.
- utils.lua:293-298: <gitdir>/gitdir may hold a path relative to the git dir (worktree.useRelativePaths / --relative-paths); resolve it against gitdir before ':h'.
- utils.lua:352: fugitive guard gd:find('/%.git') also matches dirs like ~/.gitrepos/foo; require '/%.git$' or '/%.git/'.
- Test harness: scheduled store.refresh callbacks from earlier modules (init.lua ~1189) fire at later vim.wait calls and redraw buffers with stale comments; drain pending schedules between test modules in test/run.lua.

## Done when
- [ ] Test: submodule-in-worktree diffview name resolves to <wt>/sub/f
- [ ] Test: relative gitdir file resolves to the absolute worktree
- [ ] Test: fugitive name with a .gitrepos-style git dir stays unresolved (add refused)

## Also (leftover from sxwk)
- test/test_relocate.lua refresh-cost test puts all 300 comments on unloaded files; add 1-3 comments per loaded buffer so the batched from_mark/place/draw_signs path is covered at scale (count calls, no wall clock).

## Also (leftovers from w9y6)
- context.lua:58: if the user's env has GIT_LITERAL_PATHSPECS=1, ':(literal)rel' is taken as a literal filename and the diff is empty. Instead set env GIT_LITERAL_PATHSPECS=1 on the vim.system call and pass bare rel.
- store.lua view_item: quickfix rows use store.headline(c) raw; a multi-line body puts '\n' in qf text. Use the first line (as the edit picker now does).
