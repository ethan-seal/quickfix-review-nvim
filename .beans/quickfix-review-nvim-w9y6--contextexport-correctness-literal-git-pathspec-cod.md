---
# quickfix-review-nvim-w9y6
title: 'Context/export correctness: literal git pathspec, code-fence collisions'
status: todo
type: bug
priority: normal
created_at: 2026-09-26T12:22:52Z
updated_at: 2026-09-26T12:22:52Z
---

From review cycle 2 (details and repros: /tmp/claude-1001/-home-ethans-Programming-quickfix-review-nvim/cfc4ea53-3598-4975-b59b-e35c5f93f346/scratchpad/review2/opus-edge.md).
- context.lua:55-60 (low-medium): git diff -- rel treats rel as a glob pathspec, so a comment in app/[id]/page.tsx captures the hunk of app/d/page.tsx. Use ':(literal)'..rel or GIT_LITERAL_PATHSPECS=1 (check other git invocations too).
- export.lua:76-81 (low-medium): a snippet/diff context line that is a bare ``` closes the export's code fence early and leaves the closing fence unterminated. Choose a fence longer than the longest backtick run in the content (CommonMark rule), for all fenced blocks in export.

## Done when
- [ ] Test: file with [id] in its path next to a matching sibling → only its own hunk captured
- [ ] Test: snippet containing a ``` line → export fence stays balanced
