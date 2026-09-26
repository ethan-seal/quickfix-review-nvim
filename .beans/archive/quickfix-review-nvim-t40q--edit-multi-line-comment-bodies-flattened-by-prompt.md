---
# quickfix-review-nvim-t40q
title: 'Edit: multi-line comment bodies flattened by prompt_edit'
status: completed
type: bug
priority: normal
created_at: 2026-09-26T16:43:09Z
updated_at: 2026-09-26T17:41:07Z
---

From review cycle 3 (details/repros: /tmp/claude-1001/-home-ethans-Programming-quickfix-review-nvim/cfc4ea53-3598-4975-b59b-e35c5f93f346/scratchpad/review3/opus-adversarial.md).

- (medium) init.lua:974 prompt_edit with store.lua:1536 M.edit: editing a comment whose body has newlines converts them to spaces and logs an edit even when the user just presses Enter unchanged. Don't record an edit if the input equals the flattened original (keep original body); ideally edit multi-line bodies in a scratch buffer, or preserve newlines via an escape.

## Done when
- [ ] Test: prompt_edit on multi-line body + unchanged Enter → no update event, body intact
- [ ] Test: actual edit of multi-line body behaves as documented (newlines preserved or documented)
- [ ] scripts/test.sh passes
