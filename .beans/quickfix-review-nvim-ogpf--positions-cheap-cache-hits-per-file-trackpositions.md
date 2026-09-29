---
# quickfix-review-nvim-ogpf
title: 'Positions: cheap cache hits, per-file track.positions() readers, O(1) store.get'
status: todo
type: task
created_at: 2026-09-29T22:11:02Z
updated_at: 2026-09-29T22:11:02Z
---

**Background.** Left over from z2v4 (4065858):
- `track.pos` (lua/quickfix-review/track.lua ~:550-556) runs `utils.path_key` (fnamemodify + realpath) and `source_of` (buffer lookup or fs_stat) on every call, cache hits included. view_item and refresh_buffer_signs each call pos twice per comment.
- `track.positions()` (~:572) has no production caller; signs, qf view, float and export read per comment via store.range/is_outdated → record.pos → track.pos.
- `store.get(id)` (lua/quickfix-review/store.lua ~:160-166) scans the list instead of using reduce's `index.by_id` (co2g).

**Decision: make cache hits cheap and route per-file readers through `track.positions()`.**

## The edit

- track.lua: memoise `path_key(filename)` per filename (invalidate on DirChanged and in `forget_buffer`), and compute the stamp once per path per refresh — e.g. `positions(path)` computes the stamp once and serves every id in that file.
- signs.lua draw and store/view.lua view_items: fetch `track.positions(path)` once per file and read from it, instead of pos per comment.
- store.get: look up via `reduce.get(journal.reduced(), id)` or the view's id map; keep the returned-object contract.

## Checklist

- [ ] Baseline then after: time `signs.refresh_all` + `qf.show_list` with 2 000 comments over 50 files (record both); after is faster.
- [ ] `grep -n "track.positions" lua/quickfix-review/signs.lua lua/quickfix-review/store/view.lua` → at least one hit each.
- [ ] Test: a DirChanged between two refreshes still resolves relative filenames correctly (memo invalidated).
- [ ] `scripts/test.sh` passes; restore `test_file.txt` before committing.

## Do not

- Do not memoise realpath across DirChanged or symlink creation without invalidation (z2v4's symlink test in test_signs.lua must keep passing).
