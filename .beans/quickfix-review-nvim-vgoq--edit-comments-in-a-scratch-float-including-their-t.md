---
# quickfix-review-nvim-vgoq
title: Edit comments in a scratch float, including their type
status: todo
type: feature
created_at: 2026-10-22T20:28:44Z
updated_at: 2026-10-22T20:28:44Z
---

**Background.** `:ReviewEdit` / `keymaps.edit` (`<leader>cm`) resolve the comment (quickfix row, else `comments_on_line()` with a picker when several cover the line) in `M.edit_comment()` (`lua/quickfix-review/edit.lua:475`), then `prompt_edit()` (`edit.lua:444`) asks for the body in a one-line `vim.ui.input`. Multi-line bodies are flattened through `escape_body`/`unescape_body` (`edit.lua:426-441`). The type (`kind`) can't be changed at all. `store.edit(id, body)` (`lua/quickfix-review/store.lua:324`) logs one `update {set={body}, prev={body}}`.

**Decision: editing opens an entered scratch float holding the comment body, always.** `<leader>cm` / `:ReviewEdit` open it directly, whether or not the view float is showing (an open view float is closed first with `jump.close_float()`). There is no separate "edit from the view float" key: the view float is never entered (`nvim_open_win(buf, false, …)`, `edit.lua:314`), so the edit key on the code line already covers it.

**Decision: the type is changed in the same window, and saved in the same event as the body.**

## The edit

1. `store.edit(id, body, kind)` (`store.lua:324`): `kind` optional (lowercase type key). Build `set`/`prev` from whichever of `body`/`kind` differ from the live comment; `'unchanged'` when neither does. Still exactly one `update` event. Reject a `kind` that is not a configured type (`utils.get_comment_type_config`) the same way an empty body is rejected (return `nil`). Update the doc comment above it.
2. `edit.lua`: replace `prompt_edit`, `escape_body`, `unescape_body` with `open_editor(id, comment)`:
   - `jump.close_float()`, then a scratch buffer (`nvim_create_buf(false, true)`, `bufhidden=wipe`, `buftype=acwrite`, name `quickfix-review://edit/<id>`) with `vim.split(body, '\n', {plain=true})` as its lines.
   - Entered float: `relative='cursor'`, `row=1`, width `math.min(80, vim.o.columns - 4)` (as the view float), height `#lines` clamped to 3..15, `border='rounded'`, `wrap=true`. Title ` <KIND> ` (uppercased pending kind), footer ` <CR> save · q cancel · <cycle keys> type ` (Neovim 0.10 has `footer`).
   - Save on `BufWriteCmd` (`:w`) and buffer-local normal `<CR>`: text = buffer lines joined with `\n`, trailing blank lines dropped. Empty → message `Comment text is empty (q to cancel)`, window stays open. Otherwise `store.edit(id, text, pending_kind)`:
     - `'edited'` → close, `print('Comment edited')`; `'unchanged'` → close silently; `'missing'` → close, `print('Comment no longer exists')`.
     - `nil` → `keep_typed(text)`, the existing warning (`… was not edited (<err>); the text is in register "`), and the window **stays open**.
   - Cancel: buffer-local normal `q` and `<Esc>` close with force; nothing is logged. `:q` on a modified buffer gives the normal E37 — leave it.
   - Type cycling: buffer-local normal maps on `config.options.keymaps.cycle_next` / `cycle_previous` (default `+`/`-`); a direction set to `false` gets no map. They step a local `pending_kind` through `utils.get_comment_types()` and retitle the float (`nvim_win_set_config`). A kind no longer configured is shown as-is and cycling starts from the first configured type.
   - `M.edit_comment()` keeps its resolution logic and calls `open_editor` in place of `prompt_edit` (all three call sites, `edit.lua:493,504,511`).
3. Docs: README command table row for `:ReviewEdit` (`README.md:293`, drop the `\n` escaping text), README Quick Start gets a step "press `<leader>cm` to edit the comment under the cursor (text and type)", `keymaps.edit` comment (`README.md:150`), `doc/quickfix-review.txt:518` (`:ReviewEdit`) and `:655`/`:698` as needed.

## Checklist

- [ ] Replace the `with_input` edit tests (`test/test_comments.lua:802-950`) with ones that drive the float: set its lines, `feedkeys`/`nvim_feedkeys` `<CR>` or `:w`, `q`.
- [ ] Test: edit body via `<CR>` → one `update` event, body changed, id and anchor unchanged, qf row text updated.
- [ ] Test: same via `:w`.
- [ ] Test: `q` after changing text → no event, float closed.
- [ ] Test: multi-line body opens as multiple buffer lines; saving unchanged → no event, newlines intact.
- [ ] Test: cycle type with `+` then save → one event with `set.kind` and `prev.kind`; sign and qf type change. Global cycle type (`edit.current_cycle_type()`) is unchanged.
- [ ] Test: emptied buffer + `<CR>` → no event, float still open.
- [ ] Test: `<leader>cm` while the view float is open → view float closed, edit float open; editing from the review quickfix row edits that row's comment.
- [ ] `scripts/test.sh` passes.

## Do not

- Do not touch the global cycle state from the editor's type keys: `+`/`-` in the float must not change what `<leader>ca` adds next.
- Do not log two events for a body+type change: `:ReviewHistory`/restore treat one `update` as one change.
- Do not close the float on a failed save: the buffer is the user's only copy of what they typed besides the register.
- Do not move adding a comment (`add_comment`, `vim.fn.input` at `edit.lua:136`) onto this window here; that's a separate change.
