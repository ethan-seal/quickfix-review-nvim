---
# quickfix-review-nvim-hdzw
title: Relocate comments via vim.diff; outdated state; tracking extmarks
status: completed
type: feature
priority: high
created_at: 2026-09-26T04:57:59Z
updated_at: 2026-09-26T07:00:39Z
parent: quickfix-review-nvim-8oi5
blocked_by:
    - quickfix-review-nvim-2kae
    - quickfix-review-nvim-0edn
    - quickfix-review-nvim-nep3
---

Relocation and the outdated state (parent epic 8oi5 — Diff API, Mapping, When relocation runs, Tracking extmarks sections are the spec).

- Pure function `track.map_range(hunks, lnum, end_lnum) -> new_lnum, new_end, state` implementing the epic's algorithm exactly.
- `track.relocate(comment, current_lines) -> pos`: if hash(current) == anchor.sha → current; if snapshot missing → leave for fallback bean (mark `outdated` for now); else diff snapshot vs current and map.
- Wire the triggers from the epic (BufReadPost, FileChangedShellPost replacing the clear prompt, unloaded-file relocation for qf/export/jump cached by path+size+mtime, never from diff buffers).
- Tracking extmark namespace per epic; signs drawn from tracking positions.
- Outdated display: distinct sign highlight (`QuickfixReviewOutdated`, linked to `DiagnosticWarn` by default), qf row text prefixed `[outdated]`, float header says "outdated — code changed since comment", export marks it `(outdated)`.
- pos changes are persisted only as `update {set={pos}}` events when they differ from the stored pos (cheap, droppable) — never on BufEnter redraw.
- Document min Neovim 0.10 in README + help.

## Done when
- [ ] Unit tests for map_range: insert above, delete above, change inside range, pure insertion inside range, insertion adjacent to edges, whole range deleted, change after range
- [ ] Integration: comment at L5, insert 2 lines above on disk, reopen → sign at L7, state shifted
- [ ] Edit a commented line → outdated sign + qf prefix + float header
- [ ] CRLF file and file without final newline don't produce spurious outdated
- [ ] FileChangedShellPost no longer offers to clear comments
- [ ] Opening a fugitive/diffview buffer never changes stored pos
