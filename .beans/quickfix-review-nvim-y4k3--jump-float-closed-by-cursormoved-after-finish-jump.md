---
# quickfix-review-nvim-y4k3
title: 'Jump: float closed by CursorMoved after finish_jump; ]r misdetected as qf jump'
status: todo
type: bug
priority: normal
created_at: 2026-09-26T16:43:09Z
updated_at: 2026-09-26T16:43:09Z
---

From review cycle 3 (details/repros: /tmp/claude-1001/-home-ethans-Programming-quickfix-review-nvim/cfc4ea53-3598-4975-b59b-e35c5f93f346/scratchpad/review3/opus-events.md).

- (medium) init.lua:1156-1169 with 743-746: finish_jump moves the cursor and opens the float; the CursorMoved it triggers then closes the float. Existing test only passes because navigate() fires CursorMoved before finish_jump. Ignore the CursorMoved caused by the plugin's own cursor move (e.g. record the position the float was opened at).
- (low) init.lua:1177/1187/1162 via 505-510: ]r into an unloaded, shifted file is treated as a qf jump by pending_jump(fresh): cursor lands on the wrong comment (line 5 instead of 3), no float. Only treat as qf jump when the jump actually came from the quickfix list.

## Done when
- [ ] Test (realistic event order, CursorMoved after finish_jump) : float stays open after :cnext
- [ ] Test: ]r into unloaded shifted file lands on the intended comment
- [ ] scripts/test.sh passes
