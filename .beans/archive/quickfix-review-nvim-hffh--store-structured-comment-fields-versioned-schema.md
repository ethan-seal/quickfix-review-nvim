---
# quickfix-review-nvim-hffh
title: Store structured comment fields + versioned schema
status: completed
type: feature
priority: normal
created_at: 2026-09-26T04:31:20Z
updated_at: 2026-09-26T05:52:19Z
blocked_by:
    - quickfix-review-nvim-n9cc
    - quickfix-review-nvim-vj7e
---

Kind, range and response are encoded in the text string (`[ISSUE:L1-5] ... | Response: ...`) and regex-parsed in several places (utils.lua:73, export.lua:21-22, init.lua:291, init.lua:347). The qf `type` is lossy (issue and insight both → 'I'). The file is a bare JSON array with no version; migration is split between normalize() and the out-of-band scripts/migrate.ts.

## Decision: schema v2 (this is also the payload the event log and line tracking build on)
```
file: { "version": 2, "comments": [ comment... ] }
comment: {
  id,                         -- from quickfix-review-nvim-n9cc
  filename,                   -- absolute real path
  kind,                       -- full type name as in config.comment_types, e.g. "issue", "insight"
  body,                       -- the comment text, no prefix
  response?,                  -- optional
  lnum, end_lnum,             -- 1-based, end_lnum >= lnum (line tracking will replace these with anchor/pos later)
  context?: { commit?, commit_short?, snippet?, snippet_source?, buffer_modified? },
  created_at                  -- unix seconds
}
```
- qf items (text, type letter, lnum/end_lnum, user_data.id) are derived only in store.show()/refresh_view(); the text keeps today's visible format `[ISSUE:L1-5] body` so the list looks the same.
- Upgrades live in `storage.upgrade(doc) -> doc` with one function per version step (`from_1_to_2`), so later schema bumps just add a step. v1 = today's bare array (with or without user_data); parse legacy text prefix/`| Response:` into kind/body/response; move user_data.context → context.
- Before writing an upgraded file, copy the original to `<file>.pre-v2.bak` (never overwritten if it exists).
- Delete scripts/migrate.ts: legacy comments simply keep whatever context they have; no backfill.
- sign lookup, view_comment, export and summary read `kind`/`body`/`response` fields — no regex parsing of text anywhere.

## Done when
- [ ] Load v1 file (bare array, legacy text prefixes incl. `| Response:`) → v2 in memory, .bak written, file rewritten as v2
- [ ] Export of a v1 fixture is byte-identical before and after migration (golden test)
- [ ] `issue` and `insight` comments keep distinct kinds through save/load
- [ ] No remaining `text:match('%[')`-style parsing in lua/ (grep)
- [ ] scripts/migrate.ts removed; README/help no longer mention it
