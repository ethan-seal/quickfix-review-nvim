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
3. Enter your comment text. Cancelling the prompt (`<Esc>`) keeps what you typed: it is put in register `"`, and the next comment on the same line starts with it.
4. Press `<leader>cm` to edit the comment under the cursor (text and type)
5. Use `]r` and `[r` to navigate between comments
6. Press `<leader>ce` to export the review to markdown

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

This runs `nvim --headless --clean -c 'lua dofile("test/run.lua")' -c 'qall'` with a throwaway data home and working directory, so your own config, installed plugins and real reviews are never involved. Pass test files to run only those (`scripts/test.sh test/test_migrate.lua`); running a test file directly with `nvim` is refused. See [test/README.md](test/README.md) for details.

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

  -- The review journal: seal a segment once it grows past this many bytes,
  -- write a checkpoint every this many events, and keep this many
  -- checkpoints. See "Where reviews are stored". (log_max_bytes is the
  -- deprecated name of segment_max_bytes; log_retention_days is ignored.)
  segment_max_bytes = 4 * 1024 * 1024,
  checkpoint_every = 500,
  checkpoint_keep = 2,

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

  -- Keymaps (set one to false to disable it, or keymaps = false for none)
  -- Default type keymaps: add_issue <leader>ci, add_suggestion <leader>cs,
  --   add_note <leader>cn, add_praise <leader>cp, add_question <leader>cq,
  --   add_insight <leader>ck
  keymaps = {
    -- Comment type cycling
    add_comment_cycle = '<leader>ca',  -- Add comment with current cycle type
    cycle_next = '+',                  -- Cycle to next type
    cycle_previous = '-',              -- Cycle to previous type

    delete_comment = '<leader>cd',  -- Delete the comment at cursor (pick one when several), or all in the selection
    view = '<leader>cv',
    edit = '<leader>cm',  -- Edit the text and type of the comment at cursor (or on the quickfix row) in a float
    export = '<leader>ce',
    clear = '<leader>cc',
    summary = '<leader>cS',
    save = '<leader>cw',
    load = '<leader>cr',
    open_list = '<leader>co',
    next_comment = ']r',
    prev_comment = '[r',
    goto_real_file = '<leader>cg',
    reanchor = false,  -- :ReviewReanchor (not mapped by default)
  },
})
```

### Where reviews are stored

Each project has its own review, kept as an append-only event journal, `events/`, inside a per-project storage directory. By default that is:

```
stdpath('data')/quickfix-review/<basename(root)>-<first 12 hex chars of sha256(root)>/
```

e.g. `~/.local/share/nvim/quickfix-review/my-app-3f9a1c0b7d2e/events/000001.jsonl`, readable in a file browser. The storage directory must be on a local filesystem: the journal relies on `flock(2)` and hard links. After updating the plugin, restart every running Neovim, so that no older version keeps writing next to it. On a filesystem that refuses `flock`, the plugin warns once and falls back to a lock directory.

- **The journal**: `events/000001.jsonl`, `events/000002.jsonl`, ... (segments), one JSON object per line. Each segment starts with a header; every later line is an event (`add`, `delete`, `clear`, `restore`, `import`, ...), and the review is every segment's events replayed in order. Only the highest-numbered segment is written, and only appended to, in a single write under a lock, so several Neovims can share a review and no change can overwrite another. Once it grows past `segment_max_bytes` (4 MiB by default) it is sealed: the next segment is started, and the sealed one is never written again. Segments are never renamed, rewritten or deleted, so the whole history is kept: `:ReviewHistory` reads across them. A line that can't be read is skipped with a warning naming its line number. A segment written by a newer version of the plugin is refused with an ERROR and left unmodified, rather than shown empty.
- **`checkpoints/`**: the replayed review at a position in the journal, written every `checkpoint_every` events (500), when a segment is sealed, by `:ReviewSave`, and on exit when events were read since the last one; the newest `checkpoint_keep` (2) are kept. They only make loading faster: delete them and the review is rebuilt from the journal. `:ReviewLoad` ignores them.
- **Reviews from v2 (`log.jsonl`)**: no longer read. A review kept in `log.jsonl` (with rotated `log.<unix ms>.jsonl` and `state.json`) by a version before the journal must be opened once with a version that still migrates it (up to commit 2b05db0) before upgrading.

- **Project root**: the git toplevel of Neovim's global working directory, or that directory itself outside git (symlinks resolved). Each git worktree has its own toplevel, so each worktree gets its own review.
- **Switching projects**: after `:cd` into another project (or when `'autochdir'` changes directory), the review is re-read from that project's directory and the quickfix view and signs follow. If that project's review can't be read, the list is emptied and it is not modified until the file is fixed. `:lcd` and `:tcd` don't switch projects. The root is looked up once per directory per session, so running `git init` in an open directory takes effect after a restart. Only a definite answer from git is kept: if `git rev-parse` fails or times out, you get a warning, the last root git gave for that directory (else the directory itself) is used meanwhile, and git is asked again a few seconds later.
- **`storage_dir`**: a function receives the resolved root and returns the directory to use; a string is used as-is, so every project shares it (and the import from the global file below takes every comment, not just one project's).
- **Repo-relative paths**: in the default per-project directory, a comment on a file inside the project root is logged with its path relative to the root (`src/app.lua`), and read back against the current root, never the working directory; a file outside the root keeps its absolute path. Comments logged by earlier versions keep their absolute paths and load as before. `comments()` always returns absolute paths. With `storage_file` or `storage_dir` set, paths stay absolute, since one directory can hold several projects. An older version of the plugin reads a relative path against the working directory, so after a downgrade those comments only show up when Neovim is started at the project root.
- **Moved, renamed or cloned projects (`:ReviewAdopt`)**: the storage directory is named after the root's real path, so after `mv ~/src/app ~/work/app` (or in a clone or another worktree) the project starts with an empty review, and the old one is still in the old directory. Run `:ReviewAdopt <old storage dir>` in the project, e.g. `:ReviewAdopt ~/.local/share/nvim/quickfix-review/app-3f9a1c0b7d2e`, to copy it over: the event segments and snapshots are copied (never hard-linked), checkpoints are rebuilt, and the old directory is only read. The current project must not have a review of its own yet. That means no segment, `log.jsonl` or `comments.json` in its directory, even for a review that was cleared; a review that only ever held an empty import counts as empty and is replaced. A comment logged before relative paths existed names the old absolute path. Adopting remaps such paths under the old root to the same place under the current root, when the old root can be confirmed from the old directory's name (its `<name>-<hash>`). That fails for a directory made with a custom `storage_dir`, and for comments logged through a symlinked path. Those comments keep showing at the old location. The logged records are never rewritten, so an older version of the plugin shows them at the old location too.

**Migrating from `comments.json`.** Earlier versions kept the review in `comments.json` in the same directory. When a project has a `comments.json` but no journal yet, its comments are copied into a new journal as one `import` event and the file is renamed to `comments.json.pre-log.bak`, byte for byte as it was (if a `comments.json.pre-log.bak` from an earlier migration is already there, it is kept and the new copy is named `comments.json.pre-log.<unix ms>.bak`). From then on the journal is the review: a `comments.json` that reappears next to it (written by an older version or another tool) is not read; you get one warning and the file is left alone.

**Migrating from the global file.** Older versions kept every project's comments in one file, `stdpath('data')/quickfix-review.json`. The first time you open a project that has neither a journal nor a `comments.json`, the comments in that file whose path is inside the project are imported (you'll see "imported N comments from ..."). The global file is only read, never changed (if it is missing but `quickfix-review.json.pre-log.bak` exists, left by an older version used with `storage_file` pointing at the global file, that copy is read instead). This happens once per project: once its journal exists, nothing is imported again. When nothing in the file is inside the project, no journal is started, so the storage dir stays empty (and `:ReviewAdopt` can still fill it) until the project's first change. A project rooted at your home directory or at `/` (Neovim started outside any git repo, in `~`) imports nothing, since nearly every comment is inside it: you get one warning naming the global file, and its first change starts its journal, so it never imports later. Open Neovim inside the project to import its comments. A string `storage_dir` still imports every comment (see above), wherever Neovim is started.

**`storage_file` (deprecated).** If you set `storage_file`, one review is used for every project, as before: no storage directory, no switching on `:cd`, and no import from the global file. Its journal and checkpoints sit next to the path you give: `<storage_file>.events/` and `<storage_file>.checkpoints/` (plus a `<storage_file>.journal.lock` lock file; a v2 `<storage_file>.log.jsonl` is migrated as above); an existing file at that path is migrated to the journal and renamed to `<storage_file>.pre-log.bak`, except the global file `stdpath('data')/quickfix-review.json` itself, which is left in place so per-project reviews can still import from it once you remove `storage_file`. If you copied the old "full configuration" example, remove its `storage_file` line to get per-project reviews.

### Using a review from outside Neovim

Tools outside Neovim (a review exporter, an agent answering the comments) should not read or write the journal themselves. They run the plugin headless instead, from inside the project:

```bash
nvim --clean -l /path/to/quickfix-review-nvim/scripts/qfr.lua export
nvim --clean -l /path/to/quickfix-review-nvim/scripts/qfr.lua respond <id> '<text>'
nvim --clean -l /path/to/quickfix-review-nvim/scripts/qfr.lua clear
```

- `export` prints the review's comments to stdout as one JSON array: `id`, `filename` (absolute), `kind`, `body`, `response` (absent until there is one) and the lines it is displayed at now, `lnum` and `end_lnum` (followed through edits to the file, as in the quickfix list).
- `respond <id> <text>` sets the comment's response, replacing any earlier one. The earlier one stays in the journal (`:ReviewHistory`).
- `clear` removes every comment, as `:ReviewClear` does.

The review is the one for the working directory's project, found and locked as an interactive Neovim finds and locks it. A running Neovim shows a change on its next sync (focus or `CursorHold`). Only results go to stdout; messages (such as the one-time import notice) go to stderr. Exit codes: 0 on success, 1 on failure (such as an unknown id), 2 on a usage error. `--clean` keeps your config out, so `setup()` is never called and the default `storage_dir` is used: with a custom `storage_dir` or `storage_file`, these commands see a different review than your Neovim does.

### When the code changes

Each comment remembers the version of the file it was written against (a snapshot in `snapshots/` in the storage directory). When the file changes, the snapshot is diffed against the file as it is now and the comment moves with its lines. This happens when a file is read or reloaded after changing on disk, as you edit it, and, for a file that isn't open, when it is read for the quickfix list, export or a jump. The new position is kept in memory only until you save the file: on `:w`, every comment in it that is current or shifted is re-anchored to the saved content (one `update` event per comment whose anchor changed), so it reopens where it is now. Unsaved edits (`:q!`, `:e!`) never change a stored anchor, and outdated comments keep theirs. Diff buffers (fugitive, diffview, gitsigns, codediff) show an old revision and never move a comment. A diff buffer shows a comment's signs at its original lines when the buffer holds exactly the revision the comment was written against, and none otherwise. Saving the working file re-anchors the comment, so after that a buffer holding the older revision no longer shows it.

A comment is **outdated** when one of its lines was changed or deleted, a line was inserted inside its range, or its file or snapshot is missing. It stays where its code was (a deleted range collapses to the line before it). Outdated comments get:

- the `QuickfixReviewOutdated` sign highlight (linked to `DiagnosticWarn` unless you define it)
- `[outdated] ` in front of their quickfix row
- "outdated — code changed since comment" at the top of the comment float
- ` (outdated)` after their location in the export

Lines added or removed next to a range don't make it outdated, and neither do CRLF line endings or a missing final newline. Files not in UTF-8, and CR-only files read with `fileformat=mac`, are compared as raw bytes while not loaded, so a comment on them can show as outdated until the file is opened. While a file is open, a comment whose whole range you delete becomes outdated at once; other edits inside a range are checked when you save the file or it is next read from disk. Comments made before snapshots existed stay at their saved line and are never marked outdated; saving their file gives them a snapshot.

To accept an outdated comment's new position, put the cursor on it and run `:ReviewReanchor` (or map `keymaps.reanchor`): it is re-anchored to the buffer's lines as they are now (unsaved edits included, as when adding a comment) and is current again.

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

`comment_types` must be a non-empty table; anything else is ignored with a warning and the default types are used. A list of names (`comment_types = { 'bug', 'issue' }`) also works: a default type's name gets its default config, any other name a generic one. In `additional_comment_types`, `name = false` removes that type (`additional_comment_types = { praise = false }`).

A keymap value must be a key sequence (a non-empty string) or `false`; any other value (`true`, `''`) warns and leaves that map unset.

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
| `:[range]ReviewAdd {type}` | Add a comment of `{type}` (Tab completes the configured types) |
| `:[range]ReviewAddIssue` | Add an ISSUE comment |
| `:[range]ReviewAddSuggestion` | Add a SUGGESTION comment |
| `:[range]ReviewAddNote` | Add a NOTE comment |
| `:[range]ReviewAddPraise` | Add a PRAISE comment |
| `:[range]ReviewAddQuestion` | Add a QUESTION comment |
| `:[range]ReviewAddInsight` | Add an INSIGHT comment |
| `:[range]ReviewDelete` | Delete the comment at the cursor (you pick one when several cover the line), or all comments overlapping the range |
| `:ReviewView` | View comment at cursor |
| `:ReviewEdit` | Edit the text and type of the comment at cursor, or of the row under the cursor in the review's quickfix window, in a float: `<CR>` or `:w` saves, `q` cancels, `+`/`-` (the cycle keys) change the type; the change shows in `:ReviewHistory` |
| `:ReviewExport` | Export to markdown and clipboard |
| `:ReviewClear` | Clear all comments (asks first; `:ReviewClear!` doesn't) |
| `:ReviewTrash` | List deleted and cleared comments, newest first, in a quickfix list titled "Review trash" |
| `:ReviewAdopt {dir}` | Copy the review in storage dir {dir} (e.g. the project's dir from before it was moved) into this project, which must have no review yet |
| `:ReviewRestore [id]` | Restore a deleted comment; with no id, the last one deleted, or every comment of the last `:ReviewClear` (asks first) |
| `:ReviewHistory [id]` | Show the logged history of one comment, or the last 50 events |
| `:ReviewReanchor` | Accept the current lines of the outdated comment at cursor: re-anchor it there, no longer outdated |
| `:ReviewSave` | Write a checkpoint (every change is already in the journal as it is made) |
| `:ReviewLoad` | Replay the review's journal from disk, ignoring checkpoints, and show it in the quickfix list |
| `:ReviewSummary` | Show comment summary |
| `:ReviewGoto` | Jump to real file from diff |

With a range (`:3,5ReviewAddNote`, or `:'<,'>` from visual mode) a comment covers those lines; without one, the current line. `setup()` makes a `:ReviewAdd<Type>` command for every configured comment type, custom ones included, CamelCased from the type name (`nit` gives `:ReviewAddNit`, `needs_work` gives `:ReviewAddNeedsWork`). Type names are lowercased at setup (with a warning), so `Bug` becomes `bug` and gets `:ReviewAddBug`. Only type names of lowercase letters, digits and `_` get one; any other name (such as `needs-work`) warns and is reachable through `:ReviewAdd {type}`. A type left out of the config (for example when `comment_types` replaces the defaults) loses its command.

## Documentation

See `:help quickfix-review` for full documentation.

## License

MIT
