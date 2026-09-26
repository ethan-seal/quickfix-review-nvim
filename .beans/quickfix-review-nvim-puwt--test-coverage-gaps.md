---
# quickfix-review-nvim-puwt
title: Test coverage gaps
status: todo
type: task
priority: normal
created_at: 2026-09-26T04:31:20Z
updated_at: 2026-09-26T04:57:50Z
blocked_by:
    - quickfix-review-nvim-vj7e
    - quickfix-review-nvim-l6ht
    - quickfix-review-nvim-cvl0
    - quickfix-review-nvim-1ig6
    - quickfix-review-nvim-mspz
    - quickfix-review-nvim-hffh
---

Last-mile test coverage for code not covered by the individual beans' own tests. Items already owned elsewhere were removed (flaky screen test → hermetic bean; parse_hunks → 1ig6; qf-guard → cvl0; summary data → vj7e; Response parsing → hffh removes it).

- [ ] export.lua: golden test of full export output (header, legend, item_format, context commit/snippet, range formatting, outdated marker if present)
- [ ] view_comment float content: kind, body, response, context lines, wrapping at width
- [ ] jump_comment ]r/[r across files and wrap-around
- [ ] Comment-type cycling order (deterministic)
- [ ] Sign skip for lines beyond buffer length (utils.lua:165 guard)
- [ ] Run the full suite under `scripts/test.sh` 3x; no flakes
