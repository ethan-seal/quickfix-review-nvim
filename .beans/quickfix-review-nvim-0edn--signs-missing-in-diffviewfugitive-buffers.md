---
# quickfix-review-nvim-0edn
title: Signs missing in diffview/fugitive buffers
status: todo
type: bug
priority: normal
created_at: 2026-09-26T04:31:20Z
updated_at: 2026-09-26T04:57:49Z
blocked_by:
    - quickfix-review-nvim-nep3
---

Signs never show in diff buffers. Sign refresh uses the raw buffer name (init.lua:524 `nvim_buf_get_name`, init.lua:553 `expand('%:p')`), which is `diffview://…`/`fugitive://…`, while stored comments use `utils.get_real_filepath()` → files_match never matches. Also `get_real_filepath()` takes no argument and always reads `%`, and repo-relative paths from diffview/fugitive/codediff buffers are made absolute against cwd, wrong when cwd is a subdirectory. Symlinked paths don't match either (`fnamemodify(':p')` doesn't resolve symlinks, utils.lua:64-69).

## Decision
- `utils.get_real_filepath(bufnr?)` — optional bufnr, defaulting to current; all callers that know the buffer pass it (sign refresh on BufEnter and on_change, FileChangedShellPost).
- Repo-relative special-buffer paths resolve against `utils.git_toplevel()` (added in 1ig6; if not yet present, add it here with the same signature: `git -C <dir> rev-parse --show-toplevel`, cached, nil outside git → fall back to cwd).
- files_match compares `vim.uv.fs_realpath(p) or p` on both sides (cache realpath per path for the session).

## Done when
- [ ] Tests: get_real_filepath for diffview://, fugitive:// and codediff:// names (fake buffers with those names) returns the real absolute path
- [ ] Test: comment on a file, open a buffer named like a fugitive path for it → extmark present
- [ ] Test: comment via symlink path matches the real path buffer
