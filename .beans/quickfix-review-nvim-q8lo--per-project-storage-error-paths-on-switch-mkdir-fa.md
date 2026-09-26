---
# quickfix-review-nvim-q8lo
title: 'Per-project storage: error paths on switch, mkdir failure, fixed storage_dir import'
status: todo
type: bug
priority: normal
created_at: 2026-09-26T06:10:52Z
updated_at: 2026-09-26T06:10:52Z
---

Follow-ups from l3ui review:
- store.lua sync refuse(): after :cd into a project whose comments.json cannot be read, the previous project's comments stay in memory (list/signs/jump/export show them). When path ~= synced.path and load fails: clear comments, set synced.path, refresh_view() + on_change().
- mkdir_for (store.lua:199) raises E739 unguarded; can abort add/remove/clear and setup(). pcall and return false,msg through the existing save-error path.
- With a fixed string storage_dir all projects share one comments.json but the legacy import filters by the first root only. For a fixed dir, import everything (no root filter).
- autochdir: DirChanged pattern is only 'global'; also refresh on 'auto'.

## Done when
- [ ] Test: cd from repo A into repo B with corrupt comments.json → list empty, ERROR shown, writes refused
- [ ] Test: storage_dir under an unwritable path → add returns error notify, no exception
- [ ] Test: string storage_dir + legacy file with two repos → all comments imported
