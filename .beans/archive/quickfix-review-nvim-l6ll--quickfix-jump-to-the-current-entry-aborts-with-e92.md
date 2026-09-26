---
# quickfix-review-nvim-l6ll
title: Quickfix jump to the current entry aborts with E925 when comments relocate on read
status: completed
type: bug
priority: normal
created_at: 2026-09-26T08:06:29Z
updated_at: 2026-09-26T08:17:15Z
---

Follow-ups from dsak (init.lua pending_jump / finish_jump / relocate_buffer).

- pending_jump detects a jump under way only when idx ~= last_seen.idx. A jump to the entry that is already current, into an unloaded file whose comments relocate on read, still refills the qf list synchronously during the buffer read. The jump then aborts with E925 ('Current quickfix list was changed'). Examples: :ReviewOpen then <CR> on entry 1; :cc N to the current N. Detect a jump in progress by another signal, e.g. always defer the refill while inside a QuickFixCmdPre/Post pair or while the buffer is being read for a qf jump. Alternatively, defer every relocation refill of the review list during BufReadPost (vim.schedule) and keep the synchronous path only for explicit refresh calls.
- With auto_show = false, auto_show_check returns before it updates last_seen (init.lua ~461-466). last_seen goes stale, so later :e!/:checktime relocations of the selected buffer are treated as a pending jump and may move the cursor. Update last_seen before the auto_show early return.
- Nit: relocate_buffer's doc comment now sits above pending_jump; move it back above relocate_buffer.
- aazu nits, if cheap:
  - a sync with nothing new costs two fs_stat calls (check_reappeared);
  - a log rewritten in place at the same byte size is not detected until the next append.

## Done when
- [ ] Test: :ReviewOpen, then <CR> on entry 1 into a wiped file with lines inserted on disk → no E925, cursor at the relocated line
- [ ] Test: auto_show=false, :e! on the selected buffer after an on-disk shift → cursor not moved by the plugin
