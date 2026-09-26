#!/usr/bin/env bash
# Run the full test suite hermetically: --clean skips the user's init.lua and
# installed plugins, so only this checkout (prepended to rtp by test/run.lua)
# is loaded. Exits non-zero if any test fails.
set -euo pipefail

cd "$(dirname "$0")/.."
exec nvim --headless --clean -c 'lua dofile("test/run.lua")' -c 'qall'
