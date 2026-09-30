#!/usr/bin/env bash
# Run the test suite hermetically: scripts/test.sh [test/test_x.lua ...]
#
# --clean skips the user's init.lua and installed plugins, so only this
# checkout (QFR_TEST_ROOT, prepended to rtp by test/init.lua) is loaded.
# XDG_DATA_HOME points at a throwaway directory, so stdpath('data') (the
# default storage dir and the legacy global file) never touches real data, and
# tests run with a throwaway working directory (QFR_TEST_WORKDIR), so relative
# writes such as test_file.txt never land in the repo. QFR_TEST_HERMETIC marks
# the run as hermetic: test/init.lua refuses to run without it.
#
# Optional arguments are test files (relative to the repo root) to run instead
# of the full suite. Exits non-zero if any test fails.
set -euo pipefail

cd "$(dirname "$0")/.."

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/data" "$tmp/work"

export XDG_DATA_HOME="$tmp/data"
export QFR_TEST_WORKDIR="$tmp/work"
export QFR_TEST_ROOT="$PWD"
export QFR_TEST_HERMETIC=1
export QFR_TEST_FILES="$*"

nvim --headless --clean -c 'lua dofile("test/run.lua")' -c 'qall'
