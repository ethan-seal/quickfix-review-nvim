---
# quickfix-review-nvim-b8r8
title: Split store.lua into location/journal/migrate/maintenance/view modules
status: completed
type: task
priority: normal
created_at: 2026-09-29T20:45:42Z
updated_at: 2026-09-29T21:06:29Z
blocked_by:
    - quickfix-review-nvim-x5ft
---

**Background.** lua/quickfix-review/store.lua is 1727 lines with ~25 module-level locals (`comments`, `synced`, `reduced`, `resolved`, `good_roots`, `import_*`, `reappeared_*`, `retention_done`, `head`, several notify-once tables). It bundles: storage location resolution (store.lua:322-441), view/quickfix rendering (197-305), locking and append/sync/cache (482-684, 1214-1295, 1401-1460), legacy migration and import (685-962), torn-log recovery (964-1037), rotation/retention/GC (1039-1390), and the public comment API (1461-end). All three reviewers (2026-09-29) named it the main structural risk: any fix touches unrelated state.

**Decision: split store.lua into focused modules behind store.lua as a thin facade.** The public `require('quickfix-review.store')` API (every `M.*` function) is unchanged, so init.lua, commands.lua, export.lua, history.lua and the tests do not need edits beyond what the move forces.

## The edit

New modules under lua/quickfix-review/store/ (or flat `store_*.lua`, match whichever reads cleaner with the existing `require` style):
- `location` — `project_root`, `resolve`, the path getters, pinning (`with_location`), and the `resolved`/`good_roots`/`fallback_warned` state.
- `journal` — `locked`, `apply`, `flush`, `load_cache`, `read_log`, `sync`/`sync_data`, `mutate_at`, torn recovery, `check_reappeared`, and the `synced`/`reduced` state.
- `migrate` — `load_records`, `serialise_all`, `is_legacy_global`, `migrate`, `import_legacy`, `load_readonly`, `init_storage`, and the `import_*` state.
- `maintenance` — rotation, retention, `remove_strays`, `gc`, `schedule_startup_gc`.
- `view` — `view_item(s)`, `refresh_view`, `refresh_view_later`, `view_of`.
- `store.lua` keeps `normalize`/`parse_anchor` (or moves them to a `record` module) and the public `M.*` API, delegating.

Each module owns its own state. Cross-module state goes through functions, not shared tables. Collapse the separate notify-once tables into one shared `notify_once(key, msg, level)` helper (utils.lua or a small `notify.lua`), used by every module (reviewer finding H).

## Checklist

- [ ] `wc -l lua/quickfix-review/store.lua` is under 400. No new module is over 600.
- [ ] Every `M.*` name exported by store.lua before the split is still exported: diff `grep -o "^function M\.[a-z_]*" ` output before and after.
- [ ] `scripts/test.sh` passes in full, with no test changed except `require` paths for tests that poked internals (list them in the commit body).
- [ ] No module requires another lazily (inside a function) unless the cycle is documented in a comment. Bean G removes the rest.

## Do not

- Do not change behaviour, the log format, or file paths in this bean. It is a pure move. Fixes found along the way become new beans.
- Do not leave state duplicated between the facade and a module (e.g. two `comments` tables). There must be exactly one owner.
