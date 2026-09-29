---
# quickfix-review-nvim-8arp
title: Born-v3 reviews write the tombstone log.jsonl
status: completed
type: bug
priority: normal
created_at: 2026-09-29T22:54:22Z
updated_at: 2026-09-29T23:55:20Z
---

**Symptom**: a review created by v3 code has `events/` but no tombstone `log.jsonl`. If a Neovim is still running the old code, it will create a fresh v2 `log.jsonl` beside `events/` and write to it. v3 ignores that file with a 'stray-v2' warning. Snapshot GC (lua/quickfix-review/store/maintenance.lua:68-78) reads only segments, so any snapshot referenced only by the stray log becomes an orphan and is later deleted.
**Root cause**: only migration writes the tombstone. The create path (store/migrate.lua:77-81, journal.create) does not; see the stray-v2 branch at migrate.lua:562-567.
**Expected**: old code refuses a born-v3 review, exactly as it refuses a migrated one.

## The edit

When segment 1 of a new review is created, also write the tombstone `log.jsonl` (the same bytes migration writes), under the same lock. Put it after segment 1 exists, so a crash between the two leaves a v3 review with no tombstone, never a tombstone with no events.

## Checklist

- [ ] Test: a fresh review → `log.jsonl` exists and holds the v3 header tombstone.
- [ ] Test: the current `mutate_at` refusal test (Unknown #1) run against a born-v3 dir → refuses, creates no v2 log.
- [ ] `scripts/test.sh` passes; restore `test_file.txt` afterwards with `git checkout -- test_file.txt`.

## Do not

- Do not change snapshot deletion rules (bean 144w).
