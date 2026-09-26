---
# quickfix-review-nvim-mspz
title: 'Harden load: clamp end_lnum, decode JSON null as nil'
status: completed
type: bug
priority: high
created_at: 2026-09-26T04:31:20Z
updated_at: 2026-09-26T05:15:30Z
blocked_by:
    - quickfix-review-nvim-46kf
---

Legacy save data breaks loading in two ways; both are fixed in `store.normalize()` / `storage.load` and both need legacy-file regression tests.

## 1. end_lnum = 0
Older saves stored raw getqflist() items where end_lnum=0 means "unset". normalize() (store.lua:37) keeps 0, then:
- refresh_buffer_signs places an extmark at row -1 → "Invalid 'line': out of range" at utils.lua:205 on BufEnter and from on_change after every add/delete/clear (the write to disk has already happened when it throws).
- delete can't match the item (init.lua:376: `0 >= start` is false).
- export prints `a.txt:5-0`.
Verified headless for all three.

Fix: in normalize, `end_lnum = (item.end_lnum and item.end_lnum >= item.lnum) and item.end_lnum or item.lnum`. In refresh_buffer_signs also skip `line < 1` (defence in depth; the upper-bound skip is at utils.lua:165).

## 2. JSON null → vim.NIL (was h1d9)
scripts/migrate.ts sets commit/commit_short to null when git fails (set at migrate.ts:105, emitted 111-112). `vim.fn.json_decode` turns null into `vim.NIL` (truthy userdata), so export.lua:39 prints commit: `vim.NIL`. Nested: user_data is copied as-is by normalize, so a shallow fix is not enough.

Fix: in storage.load decode with `vim.json.decode(content, { luanil = { object = true, array = true } })` so nulls become nil at every depth. (Encoding stays as-is here; the switch to vim.json.encode happens in quickfix-review-nvim-n9cc.) Re-running migrate.ts does not repair existing files (it skips items with user_data), so the Lua fix is the real repair. migrate.ts itself is deleted in the structured-schema bean.

## Done when
- [ ] normalize clamps end_lnum; refresh_buffer_signs skips line < 1
- [ ] storage.load uses vim.json.decode with luanil
- [ ] Test: storage file with `{lnum=5,end_lnum=0}` → BufEnter no error, delete on line 5 removes it, export shows `:5` not `:5-0`
- [ ] Test: storage file with `user_data.context.commit = null` → export has no commit line
