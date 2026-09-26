---
# quickfix-review-nvim-ck1d
title: 'Relocation follow-ups: whole-buffer replace, ColorScheme, in-session outdated, diff-buffer signs'
status: completed
type: bug
priority: normal
created_at: 2026-09-26T07:00:39Z
updated_at: 2026-09-26T07:58:17Z
---

Follow-ups from hdzw review (track.lua, utils.lua):
- track.lua:229-233: an invalid tracking extmark always yields outdated+collapsed without comparing content, so `:%!fmt` / a formatter replacing every line marks every comment outdated at L1 even when content still matches. When d.invalid: forget the mark and fall back to place(c, buf) (diff buffer content vs snapshot).
- utils.lua:60: QuickfixReviewOutdated (and other plugin highlight links) are lost on `:colorscheme`. Re-apply in a ColorScheme autocmd in the QuickfixReview augroup (default=true links).
- Editing inside a comment's range in an open buffer doesn't mark it outdated until the next BufReadPost/FileChangedShellPost. Re-diff on BufWritePost (and optionally debounced TextChanged/InsertLeave, cached by changedtick).
- Diff buffers (fugitive/diffview) showing an older revision draw signs / resolve view+delete at the WORKING-file pos. Map pos back into the diff buffer's content when that buffer's content hash == anchor.sha (use anchor lnum directly), else hide signs there.
- Unloaded-file line cache (path,size,mtime) never evicts; cap it (LRU ~32) and include mtime nsec / inode in the key.

## Done when
- [ ] Test: `:%!cat` on a commented buffer → comments stay current at their lines
- [ ] Test: `:colorscheme default` keeps QuickfixReviewOutdated linked
- [ ] Test: edit a commented line in-buffer + :w → outdated
- [ ] Test: comment added in a fugitive-like buffer whose content equals the anchor snapshot shows its sign at the anchor line in that buffer
