---
# quickfix-review-nvim-dkkd
title: Point external review tools at the journal via a headless plugin entry point
status: completed
type: task
priority: high
created_at: 2026-09-26T05:52:19Z
updated_at: 2026-10-07T19:37:17Z
---

The plugin no longer keeps a JSON file that external tools can read or
write. A review lives in an append-only journal under a per-project dir,
`stdpath('data')/quickfix-review/<root-name>-<sha256(root)[:12]>/`
(`events/`, `checkpoints/`, `journal.lock`; see docs/journal.md and
lua/quickfix-review/store/location.lua). A legacy comments.json is migrated
and renamed to comments.json.pre-log.bak.

Tools outside this repo still use the old global
`~/.local/share/nvim/quickfix-review.json` (a bare array of qf items with
`[TYPE] text | Response: ...`):

- `~/.local/bin/review-export` (bun/TS, run by `<leader>rx` in
  ~/.config/nvim/lua/plugins/editor.lua and by ~/.claude/commands/rv.sh):
  reads that file and writes `.reviews/<uuid>.md` + `<uuid>-original.md`
  with code context
- `~/.claude/commands/rv.md`: tells the agent to append
  ` | Response: ...` to `text` in that file, matched by filename+lnum
- `~/.claude/commands/rv-done.sh`: archives the review md and writes `[]`
  to that file

None of these files are symlinks or nix-managed; edit them in place.

## Approach

Don't replicate the journal format outside the plugin. Add a small
headless entry point to the plugin and have the tools call it through
`nvim --headless`, so reads and writes go through the plugin's own
location resolution (project root from cwd) and journal locking.

Plugin side (this repo), e.g. `lua/quickfix-review/cli.lua`:
- `export_json()`: print the current project's comments as JSON to stdout
  (id, filename, kind, body, response, lnum, end_lnum)
- `respond(id, text)`: set a comment's `response` through a journaled
  update event (records already carry `response`; store.lua has no API
  for setting it yet)
- `clear()`: clear the current project's review (store.clear)
- Exit codes and stderr suitable for scripts; works without setup() having
  been called by a user config (or calls it with defaults). Tests for each.

Tools side:
- review-export: get comments via the headless export instead of reading
  the file; use kind/body directly instead of parsing `[TYPE]`. Include
  each comment's id in the markdown so the agent can address it
- rv.md: record responses with the headless `respond(id, text)` instead of
  editing a JSON file
- rv-done.sh: call the headless `clear()` instead of writing `[]`

## Done when

- [ ] Headless export / respond / clear in the plugin, with tests
- [ ] review-export reads via the headless export (per-project, v-agnostic)
- [ ] rv.md sets responses via the headless respond
- [ ] rv-done.sh clears via the headless clear
- [ ] `<leader>rx` and /rv work end to end on a real project
