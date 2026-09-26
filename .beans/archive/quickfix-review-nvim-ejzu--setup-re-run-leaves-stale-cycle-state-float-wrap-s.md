---
# quickfix-review-nvim-ejzu
title: setup() re-run leaves stale cycle_state; float wrap splits UTF-8
status: completed
type: bug
priority: normal
created_at: 2026-09-26T08:35:23Z
updated_at: 2026-09-26T08:38:21Z
---

Found during puwt:
- init.lua keeps cycle_state in a module-local (~13-22) and setup() never resets it. When setup() is called again with different comment_types, config.options.comment_types[current_type].description (~44, ~60) can index nil and throw. Reset or clamp cycle_state in setup(), and fall back to the first configured type when current_type is no longer configured.
- view_comment's word-wrap (~576-580) measures #line and uses line:sub, so it counts bytes. It can split a multibyte UTF-8 character across lines and wraps too early for wide text. Use vim.fn.strdisplaywidth and vim.fn.strcharpart, or split on character boundaries.

## Done when
- [ ] Test: setup with types {A,B,C}, cycle to C, setup with {A,B} → cycle_next / add_comment_cycle do not error
- [ ] Test: a body of multibyte characters (e.g. 'é' or CJK) wraps with no line exceeding the float width in display cells and no broken characters
