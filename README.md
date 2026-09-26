# quickfix-review.nvim

A lightweight code review system for Neovim using the built-in quickfix list and signs. You can use it to annotate files or git diffs in neovim with comments of varying type and export them for an AI agent (see screencast below).

## Comparison to other tools

This tool was inspired by:

- [tuicr](https://github.com/agavra/tuicr/), in particular the different comment types and report structure. Many thanks for that. It has a great interface but I wanted something integrated into my editor (keeping LSPs etc), and also a solution that allows me to review entire files and not diffs.
- [Review.nvim](https://github.com/georgeguimaraes/review.nvim), a nice nvim version of tuicr. I wanted a lighter weight solution that also works for reviewing non-diff files.I therefore decided to use the quickfix mechanics and the sign column for this plugin.

## Screencast

[Screencast From 2026-02-13 17-53-29.webm](https://github.com/user-attachments/assets/4e22c039-0efe-4e6f-856c-ac8cc03a5c11)


## Features

- **Six default comment types**: ISSUE, SUGGESTION, NOTE, PRAISE, QUESTION, INSIGHT
- **Customizable comment types**: Add your own or replace defaults entirely
- **Visual gutter signs**: See review comments at a glance
- **Comments follow the code**: When a file changes, comments move with their lines; a comment whose code changed is marked outdated
- **Diff buffer support**: Works also on diffbuffers
- **Export to markdown**: Share reviews with formatted output
- **Persistent storage**: Every change is saved immediately and reloaded on startup
- **Quickfix integration**: Navigate comments with familiar commands

## Installation

Requires Neovim 0.10 or later.

### lazy.nvim

```lua
{
  'your-username/quickfix-review.nvim',
  config = function()
    require('quickfix-review').setup()
  end,
}
```

### packer.nvim

```lua
use {
  'your-username/quickfix-review.nvim',
  config = function()
    require('quickfix-review').setup()
  end,
}
```

## Quick Start

1. Open a file to review
2. Press `<leader>ci` to add an ISSUE comment (or `cs`/`cn`/`cp`/`cq`/`ck` for other types)
3. Enter your comment text
4. Use `]r` and `[r` to navigate between comments
5. Press `<leader>ce` to export the review to markdown

### Comment Type Cycling

For faster workflow, use the cycling feature:
1. Press `+` to cycle through comment types (or `-` to go backwards)
2. Press `<leader>ca` to add a comment with the current type

The current comment type is shown in the status message.

### Running Tests

To run the test suite:

```bash
scripts/test.sh
```

This runs `nvim --headless --clean -c 'lua dofile("test/run.lua")' -c 'qall'`, so your own config and installed plugins are not loaded. See [test/README.md](test/README.md) for details.

The tests will:
- Verify all comment types work correctly
- Check sign placement and parsing
- Test add/delete functionality
- Validate persistence (save/load)

**Note**: The test output includes a "Plugin version check" line confirming the current plugin version is being tested.

## Configuration

All options are optional. Here's the full configuration with defaults:

```lua
require('quickfix-review').setup({
  -- Per-project storage directory: nil (the default below), a string, or
  -- function(root) -> string. See "Where reviews are stored".
  storage_dir = nil,

  -- Export filename (nil = clipboard only)
  export_file = nil,

  -- Deprecated, does nothing: comments now follow the file when it
  -- changes on disk (setting it to true shows a one-time notice)
  prompt_on_file_change = false,

  -- Show the comment float when :cnext/:cprev/:cc/:cfirst/:clast lands
  -- on an entry of the review quickfix list
  auto_show = true,

  -- Comment types: replaces all defaults if provided (see Custom comment types)
  -- comment_types = { ... },

  -- Additional comment types: merged with defaults
  -- additional_comment_types = { ... },

  -- Signs, keyed by type name and <type>_continuation
  -- Generated from comment_types; a non-empty table replaces them all
  -- signs = { issue = { text = '!', texthl = 'DiagnosticError' },
  --           issue_continuation = { text = '│', texthl = 'DiagnosticError' }, ... },

  -- Markdown export
  export = {
    header = '# Code Review\n\n',
    -- Generated from comment_types unless set (set '' to leave it out)
    -- type_legend = 'Comment types: ISSUE (Problems to fix), ...\n',
    -- string.format pattern for each comment, given 4 values in this order:
    -- index (number), TYPE, file:line or file:start-end, comment text
    item_format = '%d. **[%s]** `%s` - %s',
  },

  -- Keymaps (set to false to disable)
  -- Default type keymaps: add_issue, add_suggestion, add_note,
  --   add_praise, add_question, add_insight (all <leader>c + first letter)
  keymaps = {
    -- Comment type cycling
    add_comment_cycle = '<leader>ca',  -- Add comment with current cycle type
    cycle_next = '+',                  -- Cycle to next type
    cycle_previous = '-',              -- Cycle to previous type

    delete_comment = '<leader>cd',
    view = '<leader>cv',
    export = '<leader>ce',
    clear = '<leader>cc',
    summary = '<leader>cS',
    save = '<leader>cw',
    load = '<leader>cr',
    open_list = '<leader>co',
    next_comment = ']r',
    prev_comment = '[r',
    goto_real_file = '<leader>cg',
  },
})
```

### Where reviews are stored

Each project has its own review, kept as an append-only event log, `log.jsonl`, inside a per-project storage directory. By default that is:

```
stdpath('data')/quickfix-review/<basename(root)>-<first 12 hex chars of sha256(root)>/
```

e.g. `~/.local/share/nvim/quickfix-review/my-app-3f9a1c0b7d2e/log.jsonl`, readable in a file browser.

- **The log**: one JSON object per line. The first line is a header; every later line is an event (`add`, `delete`, `clear`, `restore`, `import`, ...), and the review is those events replayed in order. Lines are only ever appended, in a single write under a lock, so several Neovims can share a review and no change can overwrite another. Deleted and cleared comments stay in the log. A line that can't be read is skipped with a warning naming its line number.
- **`state.json`**: a cache of the replayed log next to it, written on exit and every 50 events. It is never needed: delete it and it is rebuilt from the log.

- **Project root**: the git toplevel of Neovim's global working directory, or that directory itself outside git (symlinks resolved). Each git worktree has its own toplevel, so each worktree gets its own review.
- **Switching projects**: after `:cd` into another project, the review is re-read from that project's directory and the quickfix view and signs follow. `:lcd` and `:tcd` don't switch projects. The root is looked up once per directory per session, so running `git init` in an open directory takes effect after a restart.
- **`storage_dir`**: a function receives the resolved root and returns the directory to use; a string is used as-is, so every project shares it.

**Migrating from `comments.json`.** Earlier versions kept the review in `comments.json` in the same directory. When a project has a `comments.json` but no log yet, its comments are copied into a new log as one `import` event and the file is renamed to `comments.json.pre-log.bak`, byte for byte as it was. From then on the log is the review: a `comments.json` that reappears next to it (written by an older version or another tool) is not read; you get one warning and the file is left alone.

**Migrating from the global file.** Older versions kept every project's comments in one file, `stdpath('data')/quickfix-review.json`. The first time you open a project that has neither a log nor a `comments.json`, the comments in that file whose path is inside the project are imported (you'll see "imported N comments from ..."). The global file is only read, never changed. This happens once per project: once its log exists, even with nothing imported, nothing is imported again.

**`storage_file` (deprecated).** If you set `storage_file`, one review is used for every project, as before: no storage directory, no switching on `:cd`, and no import from the global file. Its log and cache sit next to the path you give: `<storage_file>.log.jsonl` and `<storage_file>.state.json` (plus a `<storage_file>.lock` directory while writing); an existing file at that path is migrated to the log and renamed to `<storage_file>.pre-log.bak`. If you copied the old "full configuration" example, remove its `storage_file` line to get per-project reviews.

### When the code changes

Each comment remembers the version of the file it was written against (a snapshot in `snapshots/` in the storage directory). When the file changes, the snapshot is diffed against the file as it is now and the comment moves with its lines. This happens when a file is read or reloaded after changing on disk, as you edit it, and, for a file that isn't open, when it is read for the quickfix list, export or a jump. The new position is kept in memory only; nothing is written to the review log. Diff buffers (fugitive, diffview, codediff) show an old revision and never move a comment.

A comment is **outdated** when one of its lines was changed or deleted, a line was inserted inside its range, or its file or snapshot is missing. It stays where its code was (a deleted range collapses to the line before it). Outdated comments get:

- the `QuickfixReviewOutdated` sign highlight (linked to `DiagnosticWarn` unless you define it)
- `[outdated] ` in front of their quickfix row
- "outdated — code changed since comment" at the top of the comment float
- ` (outdated)` after their location in the export

Lines added or removed next to a range don't make it outdated, and neither do CRLF line endings or a missing final newline. While a file is open, a comment whose whole range you delete becomes outdated at once; other edits inside a range are checked the next time the file is read from disk. Comments made before snapshots existed stay at their saved line and are never marked outdated.

### Multiple signs per line

To display multiple comment signs side by side (when a line has multiple comments), configure your signcolumn:

```lua
vim.opt.signcolumn = "yes:2"  -- Reserve 2 columns for signs
```

### Custom comment types

To **add** types while keeping defaults, use `additional_comment_types`:

```lua
require('quickfix-review').setup({
  additional_comment_types = {
    security = { sign = '🔒', highlight = 'DiagnosticError', description = 'Security concern' },
    perf = { sign = '⚡', highlight = 'DiagnosticWarn', description = 'Performance issue' },
  },
  keymaps = {
    add_security = '<leader>cx',
    add_perf = '<leader>cf',
  },
})
```

To **replace** defaults entirely, use `comment_types`:

```lua
require('quickfix-review').setup({
  comment_types = {
    bug = { sign = '🐛', highlight = 'DiagnosticError', description = 'Bug' },
    idea = { sign = '💡', highlight = 'DiagnosticInfo', description = 'Idea' },
  },
  keymaps = {
    add_bug = '<leader>cb',
    add_idea = '<leader>ci',
  },
})
```

Signs and continuation signs are auto-generated. The `description` field is shown during type cycling and in the export legend. Types are listed (when cycling, in the summary and in the legend) in the default order issue, suggestion, note, praise, question, insight, followed by any other types sorted by name.

`comment_types` must be a non-empty table; anything else is ignored with a warning and the default types are used.

### Export format

`export.item_format` is a `string.format` pattern applied to each comment with four values: the index, the TYPE, the location (`file:line` or `file:start-end`) and the comment text. For example:

```lua
require('quickfix-review').setup({
  export = { item_format = '- [%d] %s at %s: %s' },
})
```

A pattern that doesn't accept those four values falls back to the default with a warning.

## Commands

| Command | Description |
|---------|-------------|
| `:ReviewAddIssue` | Add an ISSUE comment |
| `:ReviewAddSuggestion` | Add a SUGGESTION comment |
| `:ReviewAddNote` | Add a NOTE comment |
| `:ReviewAddPraise` | Add a PRAISE comment |
| `:ReviewDelete` | Delete comment at cursor |
| `:ReviewView` | View comment at cursor |
| `:ReviewExport` | Export to markdown and clipboard |
| `:ReviewClear` | Clear all comments (asks first; `:ReviewClear!` doesn't) |
| `:ReviewTrash` | List deleted and cleared comments, newest first, in a quickfix list titled "Review trash" |
| `:ReviewRestore [id]` | Restore a deleted comment; with no id, the last one deleted, or every comment of the last `:ReviewClear` (asks first) |
| `:ReviewHistory [id]` | Show the logged history of one comment, or the last 50 events |
| `:ReviewSave` | Write the `state.json` cache (every change is already in the log as it is made) |
| `:ReviewLoad` | Replay the review's log from disk and show it in the quickfix list |
| `:ReviewSummary` | Show comment summary |
| `:ReviewGoto` | Jump to real file from diff |

## Documentation

See `:help quickfix-review` for full documentation.

## License

MIT
