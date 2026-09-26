---
# quickfix-review-nvim-nep3
title: 'setup() idempotent: QuickfixReview augroup'
status: todo
type: bug
priority: high
created_at: 2026-09-26T04:57:33Z
updated_at: 2026-09-26T04:57:33Z
blocked_by:
    - quickfix-review-nvim-46kf
---

`setup()` registers every autocmd without a group (init.lua:543-610: QuickFixCmdPost, BufEnter, FileChangedShellPost, FileType qf). Calling setup() twice (lazy.nvim reload, re-sourcing config) duplicates them — verified: 2 BufEnter and duplicate QuickFixCmdPost handlers, so FileChangedShellPost would prompt twice. view_comment's CursorMoved close autocmd (init.lua:318-333) is also ungrouped.

Several later beans add/replace autocmds (iyuw, cvl0, l6ht, 0edn, line-tracking), so the group must exist first.

## Decision
- One group: `local augroup = vim.api.nvim_create_augroup('QuickfixReview', { clear = true })` created at the top of setup(); every autocmd in setup() passes `group = augroup`.
- Float-lifecycle autocmds use a separate group `QuickfixReviewFloat` (cleared when a float closes) — l6ht will build on this.
- Expose nothing new publicly.

## Done when
- [ ] All setup() autocmds are in `QuickfixReview`
- [ ] Test: call setup() twice; `nvim_get_autocmds({group='QuickfixReview'})` count equals the count after one call; `nvim_get_autocmds({event='BufEnter'})` has no ungrouped plugin handlers
