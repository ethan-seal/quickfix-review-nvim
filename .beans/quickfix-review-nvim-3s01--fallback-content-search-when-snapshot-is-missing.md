---
# quickfix-review-nvim-3s01
title: Fallback content search when snapshot is missing
status: todo
type: task
priority: normal
created_at: 2026-09-26T04:57:59Z
updated_at: 2026-09-26T04:57:59Z
parent: quickfix-review-nvim-8oi5
blocked_by:
    - quickfix-review-nvim-hdzw
---

Fallback when the anchor snapshot is missing (deleted data dir, storage synced from another machine, legacy comments without sha) — parent epic 8oi5.

- Search the current lines for `anchor.lines` (exact match of the whole block) with `before`/`after` as tie-breakers, preferring the match nearest to anchor.lnum within ±200 lines. Unique best match → shifted; none → outdated at the clamped old position.
- Repeated trivial lines (`end`, `}`) must use context to disambiguate; if still ambiguous → outdated.

## Done when
- [ ] Snapshot deleted, lines moved by +3 → found, shifted
- [ ] Block of `end` lines with distinct context → correct match
- [ ] Lines removed → outdated
