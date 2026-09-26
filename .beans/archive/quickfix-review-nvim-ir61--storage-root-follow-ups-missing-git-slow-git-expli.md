---
# quickfix-review-nvim-ir61
title: 'Storage root follow-ups: missing git, slow git, explicit-mode legacy log import'
status: completed
type: bug
priority: normal
created_at: 2026-09-26T13:09:31Z
updated_at: 2026-09-26T15:11:34Z
---

Leftovers accepted in zvy7 (don't spawn further follow-ups from this bean).
- utils.lua:243-248,264-273 / store.lua:342-351 (regression): if git is not installed, vim.system throws ENOENT inside pcall; it is treated as transient, never cached, so a no-git user gets a false 'git rev-parse failed ... Comments may be stored under a different directory' WARN per cwd and git is respawned every 5s. Treat a spawn error as a definitive 'no repo' (cached, no WARN).
- utils.lua:273,333 (callers context.lua:101, get_real_filepath -> worktree_of): timeouts are no longer cached, so an always-slow git blocks 1000 ms on every call. Add a per-dir retry-after timestamp in utils (like store's RETRY_NS).
- store.lua:764-772 import_legacy: comments written while storage_file pointed at the legacy global path live in <legacy>.log.jsonl; after the setting is removed the per-project import reads only the legacy file / .pre-log.bak, missing them. Also import (reduce) <legacy>.log.jsonl's state for that project.
- No dedicated test for load_cache rejecting a state.json whose offset lands mid-line (at_line_start).

## Done when
- [ ] Test: vim.system throwing ENOENT → no WARN, git not re-spawned on the next resolve
- [ ] Test: always-timing-out git → second worktree_of/git_toplevel call within the retry window doesn't spawn
- [ ] Test: comments added with storage_file = legacy path appear per-project after the setting is removed
- [ ] Test: state.json with mid-line offset → rejected, full replay
