---
# quickfix-review-nvim-zvy7
title: Storage root and legacy-path robustness
status: todo
type: bug
priority: normal
created_at: 2026-09-26T12:22:52Z
updated_at: 2026-09-26T12:22:52Z
---

From review cycle 2 (details, repros and suggested fixes: /tmp/claude-1001/-home-ethans-Programming-quickfix-review-nvim/cfc4ea53-3598-4975-b59b-e35c5f93f346/scratchpad/review2/fable-storage.md, /tmp/claude-1001/-home-ethans-Programming-quickfix-review-nvim/cfc4ea53-3598-4975-b59b-e35c5f93f346/scratchpad/review2/opus-edge.md).
- utils.lua:250-259 / store.lua:326 (medium): one slow (>1s) or failed `git rev-parse` is cached for the session, re-rooting the review to a cwd-keyed storage dir: existing comments vanish, new ones are written where later sessions never look. Don't cache failures/timeouts (retry next time; keep last good root per cwd), and WARN when falling back.
- store.lua:664-706 (medium): with the old README's `storage_file` equal to the legacy global path, explicit mode renames that file to .pre-log.bak; after the user removes the setting, import_legacy finds nothing and every per-project review is empty. Never rename the legacy global file in explicit mode when it is the global legacy path (or have import_legacy also read .pre-log.bak of the global path).
- storage.lua:107-111 (low): legacy bufnr-only records (raw getqflist saves) are resolved with the current session's bufname(bufnr), importing them onto whatever buffer 1 is. Drop (with WARN) records lacking filename instead.
- log.lua:218-221,285-286 (low): unlock() removes the lock without checking ownership; a holder whose lock was broken as stale deletes the new holder's lock. Check the pid file names us before removing (rename-aside if not).
- store.lua:581-586 / log.lua:116-127 (low): in-place rewrite of log.jsonl keeping inode and log_id and not shrinking is tailed from a stale mid-line offset; wrong state is persisted to state.json. Detect by checking that the byte before the tail offset is '\n' (and the stored mtime), else full replay.
- storage.lua:168,192: storage.save/load are dead code; remove.

## Done when
- [ ] Test: rev-parse failure once then success → same storage dir as a normal session
- [ ] Test: storage_file = legacy global path, then removed → per-project import still finds the comments
- [ ] Test: bufnr-only legacy record is not attached to an unrelated file
- [ ] Test: unlock by a non-owner leaves the other holder's lock
