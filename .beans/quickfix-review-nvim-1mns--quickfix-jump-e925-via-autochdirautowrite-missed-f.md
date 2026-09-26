---
# quickfix-review-nvim-1mns
title: 'Quickfix jump: E925 via autochdir/autowrite, missed finish_jump after sync'
status: todo
type: bug
priority: normal
created_at: 2026-09-26T12:22:52Z
updated_at: 2026-09-26T12:22:52Z
---

From review cycle 2 (details and repros: /tmp/claude-1001/-home-ethans-Programming-quickfix-review-nvim/cfc4ea53-3598-4975-b59b-e35c5f93f346/scratchpad/review2/opus-concurrency.md). All medium, headless-reproduced.
- init.lua:1240-1244: the DirChanged callback syncs without defer_view. With 'autochdir', :cnext into a file in another directory fires DirChanged during the jump; a sync with changes refills the qf list and aborts the jump with E925. Use store.all({defer_view=true}) / defer the refill there.
- init.lua:1206-1212: write_back on BufWritePost refills the list immediately. With 'autowrite' + 'nohidden', :cnext autowrites the current buffer mid-jump → E925. Defer the refill from write_back (refresh_view_later).
- init.lua:1132-1142: in relocate_buffer, the BufReadPost sync picks up another instance's change and redraws signs before relocation, which already updates the comment position, so relocated=false and finish_jump is never scheduled: :cnext leaves the cursor on the stale line (2 instead of 5) and no float opens. Decide finish_jump on whether the selected entry's position differs from the qf entry's lnum, not on the relocate return.

## Done when
- [ ] Test: autochdir + other-instance append + :cnext into another dir → no E925
- [ ] Test: autowrite nohidden modified buffer + :cnext → no E925, anchors written
- [ ] Test: other instance appends, then :cnext into shifted file → cursor on relocated line
