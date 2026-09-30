---
# quickfix-review-nvim-02fl
title: 'latin1 files: current while loaded, outdated after bwipeout'
status: completed
type: bug
priority: normal
created_at: 2026-09-30T01:29:01Z
updated_at: 2026-09-30T01:45:02Z
---

**Symptom**: a comment in a latin1 (non-UTF-8) file shows 'current' while the buffer is loaded, then 'outdated' after `:bwipeout`.
**Root cause**: `from_disk` (lua/quickfix-review/track.lua ~:543-547) hashes raw `readfile` bytes, while the loaded path (`content_of`, ~:408-416) hashes `nvim_buf_get_lines`, which Neovim has converted to UTF-8. No `fileencoding`/iconv handling exists in lua/.
**Expected**: same state loaded or not.

## The edit

In `from_disk`: if the raw bytes are not valid UTF-8 (`vim.str_utf_pos`/`pcall(vim.str_utfindex)` or `vim.fn.iconv` round-trip check), try each encoding in `vim.o.fileencodings` after utf-8 (typically `latin1`) with `vim.iconv(text, enc, 'utf-8')` and hash the converted lines. If none converts, treat the file as unknown (keep the previous state) rather than 'outdated'. Also check anchors/snapshots written from a latin1 buffer store UTF-8 lines (they come from buffer lines, so they should).

## Checklist

- [ ] Test: write a file with bytes `caf\xe9` under the test workdir, open with `++enc=latin1`, add a comment, `:bwipeout`, reload positions → state is 'current' in both.
- [ ] Test: plain UTF-8 file unaffected (existing tests).
- [ ] `scripts/test.sh` passes.

## Do not

- Do not run test files directly with nvim; only `scripts/test.sh` is hermetic.
