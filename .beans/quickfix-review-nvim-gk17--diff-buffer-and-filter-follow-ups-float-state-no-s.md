---
# quickfix-review-nvim-gk17
title: 'Diff-buffer and filter follow-ups: float state, no-sha comments, :%! sign redraw'
status: todo
type: task
priority: low
created_at: 2026-09-26T07:58:17Z
updated_at: 2026-09-26T07:58:17Z
parent: quickfix-review-nvim-8oi5
---

Follow-ups from ck1d (utils.range_in, track from_mark invalid branch):
- view_comment in a diff buffer (fugitive, diffview, codediff) shows the working-file state (possibly 'outdated') in the float header, while the sign there is drawn current. When the comment is shown via range_in in a special buffer, show the state as current in the float, or omit the state.
- Comments with no anchor sha (legacy, or snapshots.put failed) are hidden in diff buffers, and delete_comment from a diff buffer then silently deletes nothing. Report 'No comment on this line (diff buffer shows another revision)' instead of the generic message.
- Signs are not redrawn after :%!cmd (there is no TextChanged or ShellFilterPost hook). Redraw signs for the buffer on ShellFilterPost, or on a debounced TextChanged guarded by changedtick.
- utils special_sha cache is never pruned; clear the entry on BufWipeout.

## Done when
- [ ] Test: view_comment in a fugitive buffer holding the snapshot shows no 'outdated' header for a comment that is outdated in the working file
- [ ] Test: :%!cat then check signs without calling store.refresh() → signs present
