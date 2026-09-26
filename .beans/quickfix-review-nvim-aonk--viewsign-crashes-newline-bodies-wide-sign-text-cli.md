---
# quickfix-review-nvim-aonk
title: 'View/sign crashes: newline bodies, wide sign_text, clipboard export claims success'
status: todo
type: bug
priority: normal
created_at: 2026-09-26T12:22:52Z
updated_at: 2026-09-26T12:22:52Z
---

From review cycle 2 (details and repros: /tmp/claude-1001/-home-ethans-Programming-quickfix-review-nvim/cfc4ea53-3598-4975-b59b-e35c5f93f346/scratchpad/review2/opus-ui.md).
- init.lua:700 (medium): a body/response containing a newline (external tool, legacy import, Lua API) makes view_comment throw 'item contains newlines' (:ReviewView, ]r/[r stack trace; auto_show silently no float). Split lines for nvim_buf_set_lines; also check qf text, export, history for the same.
- utils.lua:227 / config.lua:183 (medium): sign text wider than 2 cells ('NIT', or a count >= 100) throws 'Invalid sign_text' — add succeeds but user sees a stack trace, and every later redraw errors. Validate/truncate sign text in config (WARN) and clamp counts (e.g. '9+').
- export.lua:97,108 (medium): with no clipboard provider, setreg('+') stores nothing but export prints 'Review copied to clipboard'. Check vim.fn.has('clipboard')/provider, fall back to unnamed register with an honest message.

## Done when
- [ ] Test: comment with a newline in body → view opens, shows both lines
- [ ] Test: comment type sign 'NIT' → config WARN, no error on add/redraw
- [ ] Test: no clipboard provider → message does not claim clipboard
