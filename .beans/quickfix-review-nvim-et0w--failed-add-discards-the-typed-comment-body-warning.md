---
# quickfix-review-nvim-et0w
title: Failed add discards the typed comment body; warning omits the reason
status: todo
type: bug
created_at: 2026-09-30T01:29:01Z
updated_at: 2026-09-30T01:29:01Z
---

**Symptom**: `add_comment` (lua/quickfix-review/edit.lua ~:126-145) reads the body with `vim.fn.input`; when `store.add` returns false (lock timeout after lock.lua's 1 s wait, read-only dir, failed import) it warns "comment was not added" and the typed text is lost. The warning omits the error reason.
**Expected**: the body survives a failed add and the user sees why it failed.

**Decision: on failure, put the body in the unnamed register and a `quickfix-review` history slot, and include the error in the warning** ("…not added (<err>); the text is in register \""). Same for edit/response paths that take typed text and can fail (grep `vim.fn.input` in lua/).

## Checklist

- [ ] Test: stub `store.add` (or the lock) to fail → `vim.fn.getreg('"')` equals the typed body; the warning contains the error string.
- [ ] Same for every other typed-text path whose store call can fail (list them in the summary).
- [ ] `scripts/test.sh` passes.

## Do not

- Do not run test files directly with nvim; only `scripts/test.sh` is hermetic.
- Do not retry the add in a loop on the main thread.
