---
# quickfix-review-nvim-4r18
title: 'Huge end_lnum hangs sign refresh: clamp comment ranges to the buffer'
status: todo
type: bug
created_at: 2026-09-30T01:29:01Z
updated_at: 2026-09-30T01:29:01Z
---

**Symptom**: a record with a huge `end_lnum` (hand-edited or foreign journal, e.g. 1e9) makes every sign refresh loop ~1e9 times and hangs Neovim.
**Root cause**: `refresh_buffer_signs` (lua/quickfix-review/utils.lua ~:201) iterates `for line = start_line + 1, end_line - 1` before its `line > buf_line_count` guard (~:217). Nothing clamps `end_lnum`: record.lua (~:94, ~:177) only enforces `end_lnum >= lnum`; `track.relocate` (~:213) and `range_in` for special buffers (~:509) return it raw.

## The edit

- utils.lua `refresh_buffer_signs`: clamp `end_line = math.min(end_line, nvim_buf_line_count(buf))` (and skip when `start_line` > line count) before any per-line loop.
- grep other per-line loops over a comment range (qf view, float, export, jump, track) and clamp them the same way.

## Checklist

- [ ] Test: a comment with `end_lnum = 1e9` on a 3-line buffer → `signs.refresh_all()` returns in < 100 ms and places signs on lines 1-3 only.
- [ ] `scripts/test.sh` passes.

## Do not

- Do not rewrite the stored record; clamp at use.
- Do not run test files directly with nvim; only `scripts/test.sh` is hermetic.
