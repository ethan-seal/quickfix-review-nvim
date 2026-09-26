---
# quickfix-review-nvim-zbpk
title: 'Jump detection edge cases: read_once gaps, mid-jump sync refill, sync stat cost'
status: completed
type: bug
priority: low
created_at: 2026-09-26T08:17:15Z
updated_at: 2026-09-26T11:26:42Z
---

Leftovers from l6ll/dsak/aazu. None are blockers.

- read_once is only set on BufReadPost. A buffer that enters without firing that event is never added: BufNewFile then :w, :enew then :saveas, or noautocmd edit. Its first :e! is treated as a fresh read, so finish_jump may move the cursor. Also set read_once on BufNewFile and BufWritePost (init.lua ~929, ~1086).
- store.all() runs synchronously inside relocate_buffer during BufReadPost. When another nvim has appended to the log, the resulting sync refill can abort a qf jump with E925. Defer sync-triggered refresh_view while inside a read, as the relocation refill already is.
- A jump to the current entry into a buffer that was :bunload-ed (not wiped) avoids E925 but leaves the cursor on the old line. This is documented in pending_jump.
- Nit: the first plain :edit +N of the file holding the selected entry counts as a jump; if the cursor is on the entry's old line, it moves to the relocated line.
- aazu nits:
  - a sync with nothing new costs two fs_stat calls (check_reappeared on comments.json);
  - a log rewritten in place at the same byte size is not detected until the next append.

## Done when
- [ ] Test: BufNewFile + :w + comment + on-disk shift + :e! → cursor not moved
- [ ] Test: another instance appends to the log; :cnext into a file → no E925
