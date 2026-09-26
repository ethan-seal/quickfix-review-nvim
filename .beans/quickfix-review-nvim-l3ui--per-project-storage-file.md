---
# quickfix-review-nvim-l3ui
title: Per-project storage directory
status: todo
type: feature
priority: normal
created_at: 2026-09-26T04:31:20Z
updated_at: 2026-09-26T04:57:49Z
blocked_by:
    - quickfix-review-nvim-hffh
    - quickfix-review-nvim-0edn
---

Default `storage_file` is one global file for every project (config.lua:27); jump/summary/export/show span all projects' comments. The event log, state cache and snapshots also need a home, so this becomes a per-project storage *directory*.

## Decision
- New option `storage_dir` (string or `function(root) -> string`). Default: `stdpath('data')/quickfix-review/<basename(root)>-<first 12 hex of sha256(root)>/`, readable in a file browser.
- Project root: `utils.git_toplevel(cwd)` (helper from 1ig6/0edn; add if missing), else cwd. Worktrees each get their own root (git toplevel differs) — documented.
- Re-resolve the root on `DirChanged` (in the QuickfixReview augroup): reload the store from the new dir, refresh signs.
- Files inside the dir: `comments.json` for now (later: `log.jsonl`, `state.json`, `snapshots/`).
- `storage_file` option still honoured if the user set it explicitly (backwards compat: use that single file, global) — documented as deprecated.
- First run in a project with no `comments.json`: if the legacy global file (old default path) exists, import the comments whose filename is under the project root, leave the global file untouched, notify once ("imported N comments from <path>").

## Done when
- [ ] Two temp git repos as cwd → different storage dirs; comments don't leak between them
- [ ] `:cd` into the other repo → list/signs switch
- [ ] Legacy global file with comments from two repos → each project imports only its own; global file unchanged
- [ ] storage_file explicitly set → behaves as before
- [ ] README + help document storage_dir, the default path and the migration
