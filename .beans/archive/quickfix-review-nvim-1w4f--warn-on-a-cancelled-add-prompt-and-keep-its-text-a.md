---
# quickfix-review-nvim-1w4f
title: Warn on a cancelled add prompt and keep its text as a per-line draft
status: completed
type: bug
priority: normal
created_at: 2026-11-01T18:04:43Z
updated_at: 2026-11-07T21:17:02Z
---

**Symptom**: Typing a comment and pressing `<Esc>` (or `<C-c>`) at the add prompt discards it with no message. The text isn't in a register or the input history, so it can't be recovered.
**Root cause**: `add_comment` (`lua/quickfix-review/edit.lua:137`) calls `vim.fn.input(prompt)`, which returns `''` both when the prompt is cancelled and when Enter is pressed on an empty line. The `if text ~= ''` branch then does nothing in either case. `keep_typed` (`edit.lua:89`) only runs when the store refuses the add.
**Reproduction**: `<leader>ci`, type `hello`, `<Esc>`. Nothing is printed, `:reg "` doesn't hold `hello`, and `<leader>ci` then `<Up>` doesn't bring it back.
**Expected**: A cancel that had text warns once, keeps the text in register `"` and the input history, and keeps it as a draft. The next add prompt on the same file and line range opens with the draft prefilled. Enter on an empty prompt and a cancel with no text stay silent.

**Decision: detect cancel with a one-shot `CmdlineLeave` autocmd (pattern `@`) around the prompt, reading `vim.v.event.abort` and `vim.fn.getcmdline()`.** `input()` can't return the typed text on cancel (`cancelreturn` only replaces the return value), and `CmdlineLeave` still sees the cmdline. Verified on nvim 0.12.6: see Evidence.

**Decision: drafts live in memory only, in a module-local table in `edit.lua`, keyed by `utils.path_key(file) .. ':' .. start_line .. '-' .. end_line`. The key leaves out the comment type,** so a draft cancelled as ISSUE is offered again when the line is reopened as NOTE. A successful add on that key clears the draft. Drafts are not logged to the journal and don't survive a restart.

## The edit

`lua/quickfix-review/edit.lua`, near `keep_typed`:

```lua
-- Text typed at an add prompt that was cancelled, or whose add was refused,
-- by file and line range: offered again by the next add prompt there. Not
-- logged, so it is gone after a restart.
local drafts = {}

local function draft_key(file, start_line, end_line)
  return utils.path_key(file) .. ':' .. start_line .. '-' .. end_line
end

-- vim.fn.input, but also says whether it was cancelled (<Esc>, <C-c>) and
-- what was typed when it was: input() returns '' for a cancel, as it does
-- for an empty <CR>
-- Returns: text, cancelled (boolean)
local function prompt_text(prompt, default)
  local left = { abort = false, text = '' }
  local id = vim.api.nvim_create_autocmd('CmdlineLeave', {
    pattern = '@',
    once = true,
    callback = function()
      left = { abort = vim.v.event.abort, text = vim.fn.getcmdline() }
    end,
  })
  local ok, text = pcall(vim.fn.input, { prompt = prompt, default = default or '' })
  pcall(vim.api.nvim_del_autocmd, id)
  if not ok or left.abort then return left.text, true end
  return text, false
end
```

In `add_comment`, replace `local text = vim.fn.input(prompt .. ': ')` (`edit.lua:137`) and its use:

```lua
  local key = draft_key(file, start_line, end_line)
  local text, cancelled = prompt_text(prompt .. ': ', drafts[key])
  if cancelled then
    if text ~= '' then
      drafts[key] = text
      keep_typed(text)
      vim.notify('quickfix-review: ' .. comment_type:upper() .. ' comment not added (cancelled); '
        .. 'the text is kept for the next comment on this line, and in register "', vim.log.levels.WARN)
    end
    return
  end
  if text ~= '' then
    ...                        -- unchanged up to the refusal branch
    if not added then
      drafts[key] = text       -- new: a refused add is offered again too
      keep_typed(text)
      ...
    end
    drafts[key] = nil          -- new: right after `stored = true`
```

An empty `<CR>` on a prefilled prompt is a non-cancel `''`. It adds nothing and leaves the draft in place.

Docs: `doc/quickfix-review.txt:410` (step 3 of the usage list) and `README.md:58`. Add one sentence each: "Cancelling the prompt (`<Esc>`) keeps what you typed: it is put in register `"`, and the next comment on the same line starts with it."

## Checklist

- [ ] `prompt_text` and `drafts` added; `add_comment` uses them as above.
- [ ] `test/init.lua:45`: export the saved `original_input` as `M.real_input` so a test can restore the real prompt.
- [ ] New tests in `test/test_comments.lua`. Each sets `vim.fn.input = helpers.real_input` and restores the mock afterwards, and drives the prompt with `vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), 't', false)` before calling `add_comment`:
  - [ ] `hello<Esc>`: no comment added, `vim.fn.getreg('"') == 'hello'`, one WARN notify containing `cancelled`.
  - [ ] Then on the same line, `<CR>` with no keys typed: the comment `hello` is added, which shows the draft was prefilled. A third prompt there opens empty, so the draft was cleared.
  - [ ] `hello<Esc>` on line 1, then `<CR>` on line 2: nothing is added (the draft is per line).
  - [ ] `<Esc>` with nothing typed, and `<CR>` with nothing typed: no notify, nothing added.
- [ ] Regression check: revert only the `cancelled` branch, and the first test fails.
- [ ] Full suite: `nvim --headless --clean -c 'lua dofile("test/run.lua")' -c 'qall'` (as `test/README.md` describes) exits 0.
- [ ] Docs sentence added in both places. `:helptags doc` leaves `doc/tags` unchanged, since no new tags are added.

## Do not

- Don't use a `cancelreturn` sentinel by itself to detect cancel: it can't give back the typed text, which is the point of the bean.
- Don't leave the `CmdlineLeave` autocmd registered if `input()` throws, e.g. on `<C-c>` in some setups. Use `once = true` and delete it after the `pcall` anyway. A leaked autocmd would fire on the next unrelated `input()` and overwrite `left`.
- Don't write drafts to the journal or the review file: every event there is replayed by other instances and `:ReviewHistory`.

---

## Evidence

2026-11-01, nvim 0.12.6 headless (`nvim --headless --clean -l cancel.lua`). The test fed keys with `nvim_feedkeys(..., 't')`, then called `vim.fn.input({prompt=..., cancelreturn='\0'})` with a `CmdlineLeave` (pattern `@`) autocmd recording `v:event.abort` and `getcmdline()`:

| keys | input() returned | abort | getcmdline() |
|---|---|---|---|
| `typed text<Esc>` | cancelreturn | true | `typed text` |
| `typed text<CR>` | `typed text` | false | `typed text` |
| `<CR>` | `''` | false | `''` |
| `abc<C-c>` (default `kept `) | cancelreturn | true | `kept abc` |

Found while chasing comments the user expected in the server_nix review. The journal there (`~/.local/share/nvim/quickfix-review/server_nix-2e65d04e9c09/events/000001.jsonl`) only ever recorded three `add` events, which fits text lost at a cancelled prompt.
