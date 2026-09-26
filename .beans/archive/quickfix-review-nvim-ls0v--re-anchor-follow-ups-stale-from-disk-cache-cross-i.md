---
# quickfix-review-nvim-ls0v
title: 'Re-anchor follow-ups: stale from_disk cache, cross-instance sticky state'
status: completed
type: bug
priority: normal
created_at: 2026-09-26T07:36:01Z
updated_at: 2026-09-26T08:26:28Z
parent: quickfix-review-nvim-8oi5
---

Follow-ups from uv21 (write-back on save + :ReviewReanchor).

- **Stale from_disk cache after :ReviewReanchor.** In track.lua, from_disk (~246-269) caches files[path].pos[id] keyed only on size+mtime. After a :ReviewReanchor with no save, then :bd, the comment shows as outdated at its old line until restart, because track.forget (~167-173) only clears marks[id]. Fix: have forget (or any anchor update) also drop files[c.filename].pos[id]; more generally, invalidate the cache when a comment's anchor sha/lnum changes.
- **Cross-instance sticky state.** When instance B applies a synced anchor update from A, B may keep a stale marks[id].pos, from_disk entry or outdated flag. Invalidate the track state for any comment whose anchor changes in a synced update (store change hook → track.forget for the changed ids).
- **:ReviewHistory output.** Anchor updates are shown as a truncated vim.inspect string. Show them as 'anchor → L<lnum>-<end> (sha abbrev)' instead.
- **Perf.** context.anchor hashes the whole buffer once per comment being re-anchored. Compute the sha once per write-back instead.
- **Edge cases.** Check that the modified-guard in write-back behaves for :saveas and :w !cmd.

## Done when
- [ ] Test: reanchor with no save, then :bd and reopen the buffer → comment is current at the new line
- [ ] Test: a synced anchor update from another instance clears the outdated state in this instance
- [ ] :ReviewHistory shows anchor updates readably
- [ ] :saveas and :w !cmd do not write anchors for the wrong file



Note (ck1d): the unloaded-file cache in track.lua now keys on inode and mtime nsec, is capped at 32 entries (LRU), and has a drop_file helper. forget() still does not clear files[path].pos[id], so use drop_file or the per-id clear for the stale-cache fix here.
