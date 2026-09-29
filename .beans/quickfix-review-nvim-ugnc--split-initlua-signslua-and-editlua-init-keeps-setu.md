---
# quickfix-review-nvim-ugnc
title: 'Split init.lua: signs.lua and edit.lua; init keeps setup and wiring'
status: todo
type: task
created_at: 2026-09-29T20:45:42Z
updated_at: 2026-09-29T20:45:42Z
blocked_by:
    - quickfix-review-nvim-f7n4
---

**Background.** After quickfix-review-nvim jump/float extraction (the bean this is blocked by), lua/quickfix-review/init.lua still holds sign/extmark drawing and its caches (`drawn_at`, `read_once`, `redraw_gen`, around init.lua:1143-1160), comment add/edit prompts, the history view and autocmd wiring, in about 1500 lines. All three reviewers (2026-09-29) flagged its size and module state.

**Decision: init.lua becomes setup + autocmd/keymap wiring + the public API.** Sign drawing moves to `lua/quickfix-review/signs.lua`, and comment add/edit/prompt flows move to `lua/quickfix-review/edit.lua`. The public `require('quickfix-review')` API is unchanged.

## The edit

1. Move sign/extmark rendering and its caches into signs.lua. `utils.refresh_buffer_signs` either moves there too or stays as the pure helper signs.lua calls. Pick one owner.
2. Move `add_comment`, edit/delete/prompt handling (including `prompt_edit`) into edit.lua.
3. init.lua keeps `setup`, autocmd and keymap registration, and thin public wrappers.

## Checklist

- [ ] `wc -l lua/quickfix-review/init.lua` is under 600.
- [ ] Every public `M.*` in init.lua before the move is still exported (diff the grep before and after).
- [ ] `scripts/test.sh` passes in full.
- [ ] Use the shared `notify_once` from the store split. Add no new notify-once table.

## Do not

- Do not change behaviour. It is a pure move.
