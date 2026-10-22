---
# quickfix-review-nvim-e88r
title: Delete at cursor picks one comment when several cover the line
status: completed
type: feature
priority: normal
created_at: 2026-10-22T20:28:44Z
updated_at: 2026-10-22T20:48:57Z
---

**Background.** `M.delete_comment(range)` (`lua/quickfix-review/edit.lua:330`) with no range uses the cursor line and removes **every** comment overlapping it through `store.remove_if` (`edit.lua:346`), without asking. A small comment inside a larger range on the same line is deleted along with it. `keymaps.delete_comment` (`<leader>cd`) calls it with no range (`lua/quickfix-review/init.lua:319`); `:ReviewDelete` passes `nil` when no range was given (`lua/quickfix-review/commands.lua:10`).

**Decision: with no range, delete works like edit — one comment covering the line is deleted at once, several get a `vim.ui.select` picker.** An explicit range (`:[range]ReviewDelete`, visual `<leader>cd`, or a `{l1, l2}` argument) keeps deleting everything overlapping it.

## The edit

In `M.delete_comment` (`edit.lua:330`), when `range == nil`, after the file/buffer checks:

```lua
local matches = comments_on_line()
if #matches == 0 then
  -- existing "No comments found" / DIFF_MISS messages
elseif #matches == 1 then
  delete_one(matches[1].id)
else
  vim.ui.select(matches, {
    prompt = 'Delete which comment?',
    format_item = function(c) return (store.headline(c):match('^[^\n]*')) end,
  }, function(c) if c then delete_one(c.id) end end)
end
```

- Take ids (and headlines) before the picker, as `edit_comment` does (`edit.lua:497-511`): the review may change while the picker is open.
- `delete_one(id)`: factor the `store.remove(id)` call and its warnings out of `M.delete_comment_from_qf` (`edit.lua:398-420`) and use it in both places. Print `Deleted 1 comment(s) from <file>:<line>` on success to match the current message.
- The range path (`range ~= nil`) is unchanged.
- Docs: README `:[range]ReviewDelete` row (`README.md:291`), `doc/quickfix-review.txt:513`, and the `keymaps.delete_comment` description: "the comment at the cursor (you pick one when several cover the line), or all comments overlapping the range".

## Checklist

- [ ] Test: two comments covering line 5, `delete_comment()` with `vim.ui.select` stubbed to pick the second → only that one is gone (`#qf.comments() == 1`, the other id survives).
- [ ] Test: same, picker cancelled (`on_choice(nil)`) → both comments remain, no remove event.
- [ ] Test: one comment covering the line → deleted with no picker (stub asserts it is not called).
- [ ] Test: `delete_comment({5, 5})` with two comments → both deleted, no picker (existing range behaviour, `test/test_comments.lua:102-123` still pass).
- [ ] Test: `:ReviewDelete` with no range and two comments → picker; `:5ReviewDelete` → both deleted.
- [ ] `scripts/test.sh` passes.

## Do not

- Do not route the explicit-range path through the picker: tests call `delete_comment({l, l})` for a bulk single-line delete, and visual `<leader>cd` on one line means "everything here".
- Do not delete by a comment table captured before the picker without re-resolving by id: `store.remove(id)` already returns `0` for a comment that's gone — report `Comment no longer exists` then.
