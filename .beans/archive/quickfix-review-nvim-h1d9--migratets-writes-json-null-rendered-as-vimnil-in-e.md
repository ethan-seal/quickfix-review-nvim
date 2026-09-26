---
# quickfix-review-nvim-h1d9
title: migrate.ts writes JSON null, rendered as vim.NIL in export
status: scrapped
type: bug
priority: high
created_at: 2026-09-26T04:31:20Z
updated_at: 2026-09-26T04:57:50Z
---

scripts/migrate.ts:111-114 sets commit/commit_short to null on git failure. vim.fn.json_decode maps null → vim.NIL (truthy), so export.lua:39 prints commit: `vim.NIL`. Verified headless.

- [ ] Omit keys instead of null in migrate.ts
- [ ] Defensively treat vim.NIL as nil in storage.load/normalize
- [ ] migrate.ts also ignores NVIM_APPNAME and throws on empty file (line 117)



## Reasons for Scrapping

Merged into quickfix-review-nvim-mspz: decoding storage with `vim.json.decode(..., {luanil = {object = true, array = true}})` turns JSON null into nil at load time, which fixes the vim.NIL export for existing files. migrate.ts itself is deleted by quickfix-review-nvim-hffh.
