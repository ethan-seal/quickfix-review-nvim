---
# quickfix-review-nvim-2kae
title: Capture anchor + snapshot when adding a comment
status: completed
type: task
priority: high
created_at: 2026-09-26T04:57:59Z
updated_at: 2026-09-26T06:43:25Z
parent: quickfix-review-nvim-8oi5
blocked_by:
    - quickfix-review-nvim-m9rq
    - quickfix-review-nvim-1ig6
    - quickfix-review-nvim-0scv
---

Capture the anchor when a comment is added (parent epic 8oi5 — Model section).

- In add_comment/context.capture: take the commenting buffer's lines (canonicalised), `snapshots.put` them FIRST, then build `anchor = {sha, lnum, end_lnum, lines, before, after}` and include it in the add event/comment. `pos` initialised to `{sha, lnum, end_lnum, state='current'}`.
- Diff buffers: snapshot the diff buffer's content (what the reviewer saw), filename = real path.
- Schema: bump to v3 via a `from_2_to_3` step in storage.upgrade (or the log's upgrade path): existing comments get `anchor = {lnum, end_lnum, lines = current file lines if readable}` and NO sha (→ fallback search handles them).
- Delete paths/export/view/signs read `pos` (falling back to anchor, then legacy lnum).

## Done when
- [ ] New comment has anchor with sha whose snapshot file exists and equals buffer content
- [ ] Comment in a buffer with unsaved edits anchors to the buffer content, not disk
- [ ] Legacy comments upgraded without sha, still displayed at their line
