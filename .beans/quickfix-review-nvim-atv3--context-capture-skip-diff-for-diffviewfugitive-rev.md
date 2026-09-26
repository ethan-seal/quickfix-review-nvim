---
# quickfix-review-nvim-atv3
title: 'Context capture: skip diff for diffview/fugitive revision buffers; export labels buffer snippets'
status: todo
type: bug
priority: normal
created_at: 2026-09-26T06:02:33Z
updated_at: 2026-09-26T06:02:33Z
---

Follow-ups from 1ig6 review:
- context.lua:109 gates the diff path only on buffer_modified. For a diffview/fugitive buffer showing an OLD revision, start_line is an old-revision line but is matched against working-tree hunks, so an unrelated hunk can be recorded with snippet_source='diff'. Skip the diff when utils.is_special_buffer(bufnr) and use the buffer snippet.
- export always fences snippets as ```diff; use a plain fence (or the filetype) when snippet_source == 'buffer', and note buffer_modified.
- utils.git_toplevel calls `:wait(1000)` without a vim.system `timeout` option; pass timeout so the child is killed.

## Done when
- [ ] Test: capture from a fugitive:// / diffview:// buffer → snippet_source == 'buffer'
- [ ] Test: export of a buffer-sourced snippet is not fenced as diff
