---
# quickfix-review-nvim-8oi5
title: Track comment lines across edits (git-style line mapping)
status: todo
type: epic
priority: high
created_at: 2026-09-26T04:31:20Z
updated_at: 2026-09-26T04:57:50Z
---

Epic: comments follow code edits, git-style. Today the stored lnum never changes: extmarks follow edits in-session, but every BufEnter/add/delete clears the namespace and re-places from the stale stored lnum (verified: comment at L5, insert 2 lines above, BufEnter snaps it back to L5). View/delete/export also use stale lines.

Decision (user): snapshots of the commented file version live in the plugin's own data dir (per-project storage_dir/snapshots/), not git blobs.

## Model
- `anchor = {sha, lnum, end_lnum, lines, before, after}` — written at comment time; lnum/end_lnum are relative to snapshot `sha`. `lines` = commented lines (max 50), `before`/`after` = up to 2 context lines each (fallback search when the snapshot is missing).
- `pos = {sha, lnum, end_lnum, state}` — derived display position, `state` ∈ `current|shifted|outdated`. A cache: may be dropped and recomputed.
- The anchor triple (sha, lnum, end_lnum) is only ever updated together, in one event. Outdated comments keep their ORIGINAL anchor (never re-anchor a guess); always diff from the anchor snapshot to the current content, never through a chain of intermediate snapshots.
- Top-level lnum/end_lnum from schema v2 become aliases of pos (fallback anchor) — qf items, signs, view, delete, export all read pos.

## Hash canonicalisation
`sha = sha256(table.concat(lines, "\n") .. "\n")` from buffer lines or readfile() (both already strip CR and BOM); always append the trailing "\n" regardless of eol/fixeol. Diff with `ignore_cr_at_eol = true`. Non-UTF-8 fileencoding: documented as noisy.

## Diff API
`vim.text.diff` (0.11+; fall back to `vim.diff` on 0.10) with `result_type = 'indices', algorithm = 'histogram'`. Hunks `{sa, ca, sb, cb}`: when a count ≥ 1 its start is 1-based; when a count is 0 its start is the line AFTER which the change sits (0 = before line 1). Verified: insert middle of a,b,c → {1,0,2,1}; insert at top → {0,0,1,1}; delete middle → {2,1,1,0}; change → {2,1,2,1}.

## Mapping (per line L of the old file)
```
delta = 0
for each hunk (sa, ca, sb, cb) in order:
  if (ca == 0 and L <= sa) or (ca > 0 and L < sa): return L + delta, CLEAN
  if ca > 0 and L < sa + ca:  -- L itself changed or deleted
    if cb > 0 then return sb + math.min(L - sa, cb - 1), TOUCHED
    else return math.max(sb, 1), TOUCHED   -- deleted: the line before the gap (or 1)
  delta = (cb == 0 and sb + 1 or sb + cb) - (ca == 0 and sa + 1 or sa + ca)
return L + delta, CLEAN
```
Ranges: map lnum and end_lnum independently, then `end = max(end, start)`. A range is **outdated** if any hunk with ca > 0 overlaps [lnum, end_lnum], or a pure insertion lies strictly inside it (`lnum <= sa < end_lnum`). Insertions/deletions adjacent to the edges don't count. Whole range deleted → outdated, collapsed to one line.

## When relocation runs
- Loaded real-file buffers: BufReadPost and FileChangedShellPost (the latter currently offers to CLEAR comments — replace that prompt with relocation; `prompt_on_file_change` option becomes a no-op with a one-time deprecation notice). In-session, tracking extmarks are the source of truth; BufEnter only redraws, using a cache keyed by b:changedtick.
- Unloaded files (qf list, export, summary, jump): relocate from readfile(), cached by (path, size, mtime); never persisted.
- Diff buffers (fugitive/diffview/codediff) hold an old revision: never relocate from or persist from them. Capturing a snapshot FROM a diff buffer is correct (anchor to what the reviewer saw).
- File missing/renamed → outdated.

## Tracking extmarks
Separate namespace `quickfix-review-track` that is NEVER cleared wholesale: one extmark per comment with `end_row` and `invalidate = true` (verified: `invalid = true` only when the whole range is deleted). Signs are drawn from these positions (the sign namespace may still be cleared/redrawn).

Min Neovim version becomes 0.10 — document it.
