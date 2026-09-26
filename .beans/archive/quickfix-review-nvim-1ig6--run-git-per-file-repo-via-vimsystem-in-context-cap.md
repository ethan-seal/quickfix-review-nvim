---
# quickfix-review-nvim-1ig6
title: Run git per-file-repo via vim.system in context capture
status: completed
type: bug
priority: normal
created_at: 2026-09-26T04:31:20Z
updated_at: 2026-09-26T06:02:33Z
blocked_by:
    - quickfix-review-nvim-46kf
---

context.capture (lua/quickfix-review/context.lua) runs git in nvim's cwd via three synchronous shell calls with no timeout. With cwd in repo A and the file in repo B it records A's HEAD (verified: recorded this repo's 6ba8e94e for a file whose repo HEAD is 30142fbc) and falls back to a disk snippet instead of the diff. The fallback snippet is read from disk while lnum comes from the buffer, so unsaved edits give a snippet/hunk that doesn't match the commented lines.

## Decision
- Run git as `vim.system({ 'git', '-C', vim.fn.fnamemodify(file, ':h'), ... }, { text = true, timeout = 2000 }):wait()` (argv form: no shell quoting, no user shell rc noise). On non-zero exit or timeout: leave commit/commit_short nil and fall back to the buffer snippet; never error.
- Add `utils.git_toplevel(path) -> string|nil` (`git -C <dir> rev-parse --show-toplevel`, cached per dir) — shared with 0edn and per-project storage. Use it to make the diff pathspec repo-relative.
- Fallback snippet comes from `nvim_buf_get_lines` of the commenting buffer. Record `snippet_source = 'buffer' | 'diff'` and `buffer_modified = true` when `vim.bo.modified` was set.
- Expose the pure helpers for tests as `M._parse_hunks` and `M._find_hunk_for_line`.

## Done when
- [ ] Tests for _parse_hunks / _find_hunk_for_line (single hunk, multiple hunks, line outside any hunk, pure insertion hunk)
- [ ] Test: file in a temp git repo while cwd is a different temp repo → commit equals the file's repo HEAD
- [ ] Test: non-git file → no commit fields, buffer snippet present, no error
- [ ] Test: unsaved buffer edit → snippet matches buffer lines



Note (from 0edn): `utils.git_toplevel(dir_or_file)` already exists (vim.system, 1000ms timeout, cached per argument). Diff buffers now pass an ABSOLUTE toplevel-based path to context.capture (previously repo-relative) — verify capture handles it.
