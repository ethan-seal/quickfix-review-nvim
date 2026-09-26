---
# quickfix-review-nvim-pkbq
title: 'Harden repair path: per-repair backups, reject inf lnum, keep unconsumed text'
status: todo
type: bug
priority: normal
created_at: 2026-09-26T05:59:32Z
updated_at: 2026-09-26T05:59:32Z
---

Follow-ups from t1m3 review (store.lua sync/normalize/to_line):
- backup_once never overwrites `.pre-repair.bak`, so a second repair that drops different records has no backup while the WARN still claims "original kept at …". Use a timestamped backup per repair (e.g. `.repair-<unix>.bak`) and name the actual path in the WARN.
- to_line accepts inf (`"1e999"`), after which vim.json.encode fails every save. Reject non-finite values.
- A string `text` whose content is not fully consumed (no ` | Response:` marker but record already has a differing body, lowercase "response:", etc.) is dropped for good. Keep the original text in `extra.legacy_text` when parse_text's kind/body/response did not all land on the record.

## Done when
- [ ] Test: two repairs dropping different records → two distinct backups, WARN names each
- [ ] Test: lnum "1e999" → dropped (not a save failure)
- [ ] Test: record with body "a" and text "[ISSUE:L1] b" → text preserved in extra after save
