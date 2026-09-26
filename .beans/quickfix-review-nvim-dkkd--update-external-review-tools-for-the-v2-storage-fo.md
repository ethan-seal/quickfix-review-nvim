---
# quickfix-review-nvim-dkkd
title: Update external review tools for the v2 storage format
status: todo
type: task
priority: high
tags:
    - human-only
created_at: 2026-09-26T05:52:19Z
updated_at: 2026-09-26T06:02:38Z
---

The plugin now writes `{ "version": 2, "comments": [ {id, filename, kind, body, response?, lnum, end_lnum, context?, created_at} ] }` (was a bare array of qf items with `text`). Tools outside this repo read/write the old shape:
- `~/.local/bin/review-export` (used by `<leader>rx` and rv.sh) expects a bare array with `.text`
- `~/.claude/commands/rv.md` tells the agent to append `| Response:` to `text` — should set `response` instead
- `rv-done.sh` writes `[]` (still loads, but re-triggers the v1 upgrade)

The first nvim start after hffh rewrites the live file (a `.pre-v2.bak` copy is kept). quickfix-review-nvim-t1m3 makes the plugin tolerate a legacy `text` field, but review-export still needs to read `.comments[]` and kind/body/response.

## Done when
- [ ] review-export reads v2 (and ideally both shapes)
- [ ] rv.md writes `response`
- [ ] rv-done.sh writes `{"version":2,"comments":[]}`



Note (l3ui): comments move to a per-project directory `stdpath('data')/quickfix-review/<name>-<hash>/comments.json` (unless `storage_file` is set explicitly). The tools must locate the file per project (or you can pin `storage_file` in your nvim config to keep one global file).
