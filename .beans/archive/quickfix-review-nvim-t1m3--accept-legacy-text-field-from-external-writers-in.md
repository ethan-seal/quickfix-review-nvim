---
# quickfix-review-nvim-t1m3
title: Accept legacy text field from external writers in v2 records
status: completed
type: bug
priority: high
created_at: 2026-09-26T05:52:19Z
updated_at: 2026-09-26T05:59:32Z
---

The live storage file is also written by tools outside this repo: `~/.claude/commands/rv.md` tells an agent to append ` | Response: ...` to a comment's `text`, and `rv-done.sh` writes `[]`. After the v2 rewrite (hffh), `store.normalize` builds records only from kind/body/response, so a `text` field written by such a tool is silently dropped on the next save — data loss, which the storage design forbids.

## Decision
- In normalize (or a storage-level pass run on every load, not only for version < 2): if a record has a string `text`, parse it with the same v1_comment logic (storage.lua) and merge: fill `kind`/`body` when missing; if it yields a `response` and the record has none (or a different one), set `response` from it. Then drop `text`. Mark the file for the one-time rewrite (same flag as missing ids).
- Never discard an unknown top-level field silently: keep unrecognised fields in an `extra` table on the record and write them back (so future external fields survive).
- Drop (with one WARN naming the file) records whose `lnum` is not a positive integer instead of crashing in headline/view_items with "attempt to compare nil" (hffh review nit).

## Done when
- [ ] Test: v2 file with a record having `text = "[ISSUE:L1-2] foo | Response: fixed"` and no response → loads with response "fixed", file rewritten without `text`, export shows the response
- [ ] Test: unknown field `foo = 1` on a record survives load+save
- [ ] Test: record with lnum = "x" → dropped with a WARN, other records load
