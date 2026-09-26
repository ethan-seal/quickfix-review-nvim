---
# quickfix-review-nvim-vj7e
title: Small fixes from plugin review
status: todo
type: task
priority: normal
created_at: 2026-09-26T04:31:28Z
updated_at: 2026-09-26T05:27:41Z
blocked_by:
    - quickfix-review-nvim-0edn
---

Grab-bag of small, local fixes from the multi-model review. Items that overlapped other beans were moved: augroup → its own bean; `<leader>cr` → cvl0; fs_realpath → 0edn; view_comment range match → l6ht. Each behavioural item needs a test.

## Robustness
- [ ] Commands work before setup(): at module load set `config.options` to a deep copy of defaults with the derived `comment_types`/`signs`/`export.type_legend` filled in (config.lua:75); setup() still merges user opts. Test: fresh require, no setup(), `:ReviewSummary` and `:ReviewExport` don't error.
- [ ] Refuse comments on unnamed/special buffers: in add_comment return with a warning when `get_real_filepath()` is '' or `vim.bo.buftype` is not '' / 'acwrite' and the buffer isn't a recognised diff buffer (init.lua:84). Make `store.add` return true/false instead of silently dropping when normalize returns nil (store.lua:114), and only print "added" on true. Test: add in a `nofile` scratch buffer → count unchanged, warning shown.
- [ ] jump_comment: clamp target lnum to `nvim_buf_line_count` of the target buffer (init.lua:267). Test: comment at L50 in a 10-line file → jump lands on L10, no error.
- [ ] FileChangedShellPost handler uses the buffer from the autocmd args (`args.buf` → `get_real_filepath(args.buf)` once 0edn lands, else `fnamemodify(args.file, ':p')`) instead of `%` (init.lua:561-578).
- [ ] `:ReviewClear` / `<leader>cc` asks for confirmation (`vim.fn.confirm`, default No) — it is currently irreversible on one keystroke. Add `bang` to skip (`:ReviewClear!`). Test: confirm stubbed to 2 → nothing cleared.

## Config / export
- [ ] `export.item_format` is read (export.lua:15) but the line is hardcoded (export.lua:33): use it. Document placeholders.
- [ ] `export.type_legend` is regenerated unconditionally (config.lua:132-137), clobbering user overrides; only generate when the user didn't set it (same pattern as `signs`, config.lua:112).
- [ ] summary() hardcodes 4 types (init.lua:345): iterate `config.options.comment_types` in a deterministic order. Split into `M.summary_data()` returning `{ total, by_type = {{name, count}...} }` and `M.summary()` printing it. Test the data function.
- [ ] Validate `comment_types`: an empty table (or non-table) falls back to defaults with a vim.notify WARN (config.lua:89) — today it crashes later in get_comment_type_config.

## Cleanup
- [ ] Remove dead `utils.place_comment_signs` (utils.lua:87) and the unneeded `sign_define` calls in init_signs (utils.lua:58) — extmarks are used.
- [ ] `get_comment_types()`: deterministic order (definition order from config, not `tbl_keys`).

## Docs
- [ ] Document `signs` and `export.{header,type_legend,item_format}` options in README and doc/quickfix-review.txt; regenerate doc/tags (`nvim --headless --clean -c 'helptags doc' -c q`).
- [ ] Document `open_list()` and `jump_comment()` in help §7 FUNCTIONS; README commands table lists all add commands.


- [ ] qf hook (configure_qf_buffer in init.lua): only delete buffer-local `dd`/`<leader>cd` maps that the plugin created (check `desc`/callback via `nvim_buf_get_keymap`), so another plugin's qf maps survive. (from cvl0 review)

- [ ] storage.atomic_write: resolve the target with `fs_realpath` first (a symlinked storage file must keep updating its target) and copy the existing file's mode onto the tmp (`fs_fstat` + `fs_fchmod`) before rename. (from hh4t review)
- [ ] export.lua:68-72 writes the export with io.open("w") and unchecked write/close: use `storage.atomic_write` and report errors. (from hh4t review)

- [ ] (from n9cc review) When the storage file is unreadable, qf `dd` prints "Comment no longer exists" because `update()` returns nil → `remove_if` returns 0. Distinguish refused (nil) from not-found (0) and say the file is unreadable. Test.
- [ ] (from n9cc review) normalize: if two loaded comments share an id (hand-copied JSON), give the later one a fresh id so `remove(id)` never deletes both. Test.

- [ ] (from 0edn review) jump_comment (]r/[r) compares `c.filename` to the buffer path as raw strings; use `utils.files_match` so symlinked paths navigate. Test.
