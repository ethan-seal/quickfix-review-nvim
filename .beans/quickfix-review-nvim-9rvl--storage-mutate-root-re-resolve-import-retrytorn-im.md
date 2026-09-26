---
# quickfix-review-nvim-9rvl
title: 'Storage: mutate root re-resolve, import retry/torn import, GC lock hold'
status: todo
type: bug
priority: normal
created_at: 2026-09-26T16:43:08Z
updated_at: 2026-09-26T16:43:08Z
---

From review cycle 3 (details/repros: /tmp/claude-1001/-home-ethans-Programming-quickfix-review-nvim/cfc4ea53-3598-4975-b59b-e35c5f93f346/scratchpad/review3/fable-storage.md, /tmp/claude-1001/-home-ethans-Programming-quickfix-review-nvim/cfc4ea53-3598-4975-b59b-e35c5f93f346/scratchpad/review3/opus-adversarial.md).

- (medium) store.lua mutate (:1336/1346/1352): nested sync() (:1170) re-resolves the project via resolve() (:356-395); if the fallback-root retry window expires mid-change, events go to another project's log (add invisible, delete no-op, snapshots.put to wrong dir). Pin the resolved location for the whole mutate.
- (low) import_legacy sets import_tried before the attempt (store.lua:774-775): a failed import is never retried and the next change marks the project as imported. Set it only on success.
- (low) import_legacy (store.lua:869, is_torn :927): a torn import write (disk full/crash) leaves header + torn line that counts as imported; legacy comments never imported. Treat a log without a complete import event as not imported / retry.
- (low) gc (store.lua:1276) reads every rotated log under the lock; with many large rotated logs another instance's change times out after WAIT_MS (log.lua:205) and the comment is dropped. Collect references outside the lock (or cache per rotated file), and/or make a lock timeout on a user change retry rather than drop.

## Done when
- [ ] Test: retry window expiring mid-mutate still writes to the originally resolved project
- [ ] Test: failed legacy import is retried next session
- [ ] Test: torn import log is re-imported
- [ ] Test: GC with large rotated logs does not make a concurrent add fail
- [ ] scripts/test.sh passes
