#!/bin/bash
set -euo pipefail

# sync user db for squirrel
# author: CsHeng
# date: 2025-07-22
# ref: https://github.com/rime/squirrel/issues/421#issuecomment-1851849381

# Error handler with context
handle_error() {
  local exit_code=$?
  local line_number=$1
  echo "ERROR: Script failed on line $line_number with exit code $exit_code" >&2
  exit $exit_code
}

# Set up error trap
trap 'handle_error $LINENO' ERR

# Require commands
require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: Missing dependency: $cmd" >&2
    exit 1
  fi
}

# Check dependencies
require_cmd pgrep
require_cmd ps
require_cmd bc

readonly RIME_DIR="$HOME/Library/Rime"
readonly SQUIRREL_APP="/Library/Input Methods/Squirrel.app"

if [ -n "$(pgrep 'Squirrel')" ]; then
  cpu_usage=$(ps -p "$(pgrep 'Squirrel')" -o %cpu=)
  if [ "$(echo "$cpu_usage <= 0.5" | bc -l)" -eq 1 ]; then
    echo "Squirrel is idle, syncing user db"
    cd "$RIME_DIR" || exit 1
    export DYLD_LIBRARY_PATH="$SQUIRREL_APP/Contents/Frameworks"
    "$SQUIRREL_APP/Contents/MacOS/Squirrel" --quit
    "$SQUIRREL_APP/Contents/MacOS/rime_dict_manager" -s
  else
    echo "Squirrel is running, skipping sync"
  fi
else
  echo "Squirrel is not running, skipping sync"
fi