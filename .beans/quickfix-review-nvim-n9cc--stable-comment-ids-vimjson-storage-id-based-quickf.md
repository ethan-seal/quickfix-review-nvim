---
# quickfix-review-nvim-n9cc
title: Stable comment ids + vim.json storage + id-based quickfix deletion
status: todo
type: task
priority: high
created_at: 2026-09-26T04:57:33Z
updated_at: 2026-09-26T04:57:33Z
blocked_by:
    - quickfix-review-nvim-mspz
    - quickfix-review-nvim-hh4t
    - quickfix-review-nvim-cvl0
---

Comments have no identity: delete-from-quickfix maps a qf row to the Nth stored comment, and everything else matches by filename+lnum. The append-only log, restore, line tracking and edit-comment all need a stable id. Also the storage encoder is `vim.fn.json_encode`, which writes `{}` as `[]` (empty maps come back as lists) — switch now so every later bean inherits correct JSON.

## Decision
- Id: 16 hex chars from `vim.uv.random(8)` (NOT math.random — LuaJIT's is unseeded, so every nvim instance produces the same sequence). Field name `id`.
- Assigned in store.add. Existing comments without an id get one in normalize on load, and the file is rewritten once (atomic_write from hh4t).
- Quickfix rows carry the id in `user_data.id`; delete_comment_from_qf, delete_comment, view/jump resolve comments by id, never by list position.
- Storage JSON: `vim.json.encode` / `vim.json.decode(s, {luanil={object=true,array=true}})` everywhere (plugin + tests). Use `vim.empty_dict()` where an empty object is meant. Never pretty-print.
- Public: `store.get(id)`, `store.remove(id)`.

## Done when
- [ ] Ids assigned on add and backfilled on load (file rewritten once; second load doesn't rewrite)
- [ ] Two headless nvim processes each add a comment → different ids
- [ ] qf `dd` deletes by id: reorder stored comments on disk between opening the list and pressing dd → the right comment is deleted
- [ ] Empty-table round-trip test: a comment with `user_data = vim.empty_dict()` saves as `{}` and loads as a table
