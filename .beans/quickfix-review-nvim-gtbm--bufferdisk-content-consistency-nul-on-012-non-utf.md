---
# quickfix-review-nvim-gtbm
title: 'Buffer/disk content consistency: NUL on 0.12, non-UTF-8 fenc, fileformat=mac, dd sign slide'
status: todo
type: bug
priority: low
created_at: 2026-09-26T12:22:52Z
updated_at: 2026-09-26T12:22:52Z
---

From review cycle 2 (details and repros: /tmp/claude-1001/-home-ethans-Programming-quickfix-review-nvim/cfc4ea53-3598-4975-b59b-e35c5f93f346/scratchpad/review2/fable-tracking.md, /tmp/claude-1001/-home-ethans-Programming-quickfix-review-nvim/cfc4ea53-3598-4975-b59b-e35c5f93f346/scratchpad/review2/opus-edge.md).
- snapshots.lua:14-16 / track.lua:189-202: on NVIM 0.12 nvim_buf_get_lines returns NUL as '\0' while readfile() returns '\n', so canonical() hashes buffer and disk content differently; a comment on a NUL line is outdated when relocated from disk but current when loaded (search fallback never matches). Normalise both to the same representation before hashing (the escape from ukmq must stay stable for existing snapshots).
- track.lua:396-423 vs 286-294: non-UTF-8 files (fenc=latin1 etc.) are UTF-8 in the buffer but raw bytes from readfile(); comments on non-ASCII lines flip current/outdated. Convert disk content with iconv using the buffer's fenc when known, or document.
- track.lua:407: fileformat=mac (CR-only) files read as one line by readfile(); comments outdated at line 1 when unloaded. Split on CR when the file has no LF, or document.
- init.lua (no TextChanged redraw) + utils.lua:127-233: after dd on a commented line the sign extmark slides onto the next line while store.range() says 'outdated at the line before the gap', so that line reports 'No comment on this line' until the next :w/BufEnter. Redraw signs for the buffer on a debounced TextChanged when an invalidated extmark is detected, or make the sign follow store.range.

## Done when
- [ ] Test: NUL line → same state loaded and from disk
- [ ] Test: dd on a commented line → sign and view agree without a save

## Also (leftover from 1mns)
- init.lua DirChanged: only pattern 'auto' defers the qf refill. A ':cd' run by a plugin (vim-rooter etc.) from BufEnter/BufReadPost during :cnext fires DirChanged 'global' and can still abort the jump with E925. Defer whenever a qf jump is pending (or always defer from DirChanged; the sign redraw stays immediate).
- store.lua view_item (leftover from 6hym): a multi-line response still puts '\n' into qf text ('| Response: r1\nr2'). Use only the response's first line (or join with ' ⏎ ') in the qf row.
