---
# quickfix-review-nvim-jou7
title: 'Tracking: canonical() not idempotent for CR CR lines; drop ignore_cr_at_eol'
status: completed
type: bug
priority: normal
created_at: 2026-09-26T16:43:09Z
updated_at: 2026-09-26T17:08:08Z
---

From review cycle 3 (details/repros: /tmp/claude-1001/-home-ethans-Programming-quickfix-review-nvim/cfc4ea53-3598-4975-b59b-e35c5f93f346/scratchpad/review3/fable-tracking.md).

- (medium) track.lua:80-88 with snapshots.lua:38-48,80-83: 'x\r\r' stored as 'x\r1\r', returned as 'x\r', re-canonicalised to 'x' → spurious diffs, comments flip to outdated; buffer sha != disk sha for ff=dos with a CR CR LF line. Make escape/unescape round-trip and canonical idempotent on snapshots.get output.
- (low) track.lua:86: ignore_cr_at_eol=true makes escaped and plain lines compare equal (#track.diff({'a\r\r'},{'a\r1'})==0). Remove the option.

## Done when
- [ ] Test: canonical(snapshots.get(put(x))) == canonical(x) for lines ending in CR, CR CR, CR1
- [ ] Test: ff=dos file with CR CR LF line: buffer sha == disk sha, comment not outdated
- [ ] scripts/test.sh passes
