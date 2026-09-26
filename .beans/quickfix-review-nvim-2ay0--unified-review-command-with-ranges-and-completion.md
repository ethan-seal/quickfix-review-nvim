---
# quickfix-review-nvim-2ay0
title: Generated :ReviewAdd<Type> commands with ranges and completion
status: todo
type: feature
priority: low
created_at: 2026-09-26T04:31:20Z
updated_at: 2026-09-26T04:57:49Z
blocked_by:
    - quickfix-review-nvim-vj7e
---

plugin/quickfix-review.lua hardcodes add commands for 4 of 6 default types, none for custom types, and no command passes `range = true` although add_comment/delete_comment support ranges.

## Decision (no subcommand parser; keep existing names)
- Create commands in setup() (types are only known then; vj7e makes defaults available before setup, so plugin/ can create the default set and setup() recreates them): `:ReviewAdd<Type>` (e.g. ReviewAddIssue, ReviewAddInsight, custom ones CamelCased) for every configured type, all with `range = true`.
- `:ReviewAdd {type}` with `complete` listing configured types, `range = true`.
- `:ReviewDelete` gets `range = true`.
- Existing command names keep working unchanged; no deprecation warnings.
- README + help list the generated commands; regenerate doc/tags.

## Done when
- [ ] Custom type `nit` in config → `:ReviewAddNit` exists
- [ ] `:3,5ReviewAddNote` creates a 3-5 range comment (input stubbed)
- [ ] `:ReviewAdd <Tab>` completes configured types
- [ ] setup() twice → no duplicate/erroring command definitions
