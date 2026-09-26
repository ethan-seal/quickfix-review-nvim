#!/usr/bin/env bash
# Run the full test suite hermetically: --clean skips the user's init.lua and
# installed plugins, so only this checkout (prepended to rtp by test/run.lua)
# is loaded. XDG_DATA_HOME points at a throwaway directory, so stdpath('data')
# (the default storage dir and the legacy global file) never touches real
# data. Exits non-zero if any test fails.
set -euo pipefail

cd "$(dirname "$0")/.."

data_home="$(mktemp -d)"
trap 'rm -rf "$data_home"' EXIT
export XDG_DATA_HOME="$data_home"

nvim --headless --clean -c 'lua dofile("test/run.lua")' -c 'qall'
