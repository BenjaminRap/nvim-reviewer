#!/bin/sh
# Run the tests headless, with throwaway data and cache folders.
# SPEC=browser tests/run.sh runs only the files whose name contains "browser".
set -e
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
XDG_DATA_HOME="$tmp/data" XDG_CACHE_HOME="$tmp/cache" XDG_STATE_HOME="$tmp/state" XDG_CONFIG_HOME="$tmp/config" \
  nvim --headless -u tests/minimal_init.lua -c "lua require('tests.runner').run()"
