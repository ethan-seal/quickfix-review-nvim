-- Headless entry point for tools outside Neovim (see lua/quickfix-review/cli.lua):
--
--   nvim --clean -l /path/to/quickfix-review-nvim/scripts/qfr.lua <command> [args]
--
-- Run it from inside the project: the review is the one for the cwd's
-- project. --clean keeps the user's config out (stdpath('data') is unchanged,
-- so the review is the one an interactive Neovim with the default
-- storage_dir uses). Exit codes: 0 success, 1 failure, 2 usage error.
local source = debug.getinfo(1, 'S').source:gsub('^@', '')
local root = vim.fn.fnamemodify(vim.fn.resolve(vim.fn.fnamemodify(source, ':p')), ':h:h')
vim.opt.rtp:prepend(root)
os.exit(require('quickfix-review.cli').main(arg))
