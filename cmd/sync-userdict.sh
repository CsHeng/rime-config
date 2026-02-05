#!/bin/bash
set -euo pipefail

# 用户词库云同步脚本 (Unison 双向同步)
# macOS 作为中转站，双向同步 iCloud ↔ OneDrive
#
# 同步拓扑:
#   Windows (weasel) ←→ OneDrive ←→ macOS (squirrel) ←→ iCloud ←→ iOS (hamster/hamster3)

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd "$SCRIPT_DIR/.." && pwd)

# shellcheck disable=SC1091
source "$SCRIPT_DIR/frontends.sh"

DRY_RUN=0
DEBUG=0
VERBOSE=0
FORCE=0

usage() {
  cat <<USAGE
Usage: $0 [--dry-run] [--verbose] [--debug] [--force]

Sync user dictionaries between iCloud and OneDrive (macOS only).
Uses Unison for true bidirectional sync with conflict detection.

Options:
  --dry-run   Preview sync without making changes
  --verbose   Show detailed output
  --debug     Enable debug logging
  --force     Skip confirmation for large deletions

Requires: unison (brew install unison)
USAGE
}

_expand_path() {
  local p="$1"
  echo "${p/#\~/$HOME}"
}

_get_icloud_path() {
  local raw
  raw=$(_yq -r '.userdict_sync.icloud // ""')
  [ -n "$raw" ] && _expand_path "$raw" || echo ""
}

_get_onedrive_path() {
  local os
  os=$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo "")
  local raw=""
  case "$os" in
    darwin*) raw=$(_yq -r '.userdict_sync.onedrive.darwin // ""') ;;
    msys*|mingw*|cygwin*) raw=$(_yq -r '.userdict_sync.onedrive.windows // ""') ;;
  esac
  [ -n "$raw" ] && _expand_path "$raw" || echo ""
}

_check_macos() {
  local os
  os=$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo "")
  case "$os" in
    darwin*) return 0 ;;
    *)
      printf "${RED}ERROR: This script runs on macOS only (current: %s)${NC}\n" "$os" >&2
      return 1
      ;;
  esac
}

_check_unison() {
  if ! command -v unison >/dev/null 2>&1; then
    printf "${RED}ERROR: unison not found. Install with: brew install unison${NC}\n" >&2
    return 1
  fi
}

_check_dir() {
  local dir="$1"
  local name="$2"
  if [ ! -d "$dir" ]; then
    printf "${RED}ERROR: %s directory not found: %s${NC}\n" "$name" "$dir" >&2
    return 1
  fi
}

sync_userdict() {
  _check_macos || return 1
  _check_unison || return 1

  local icloud_sync
  local onedrive_sync
  icloud_sync="$(_get_icloud_path)"
  onedrive_sync="$(_get_onedrive_path)"

  if [ -z "$icloud_sync" ]; then
    printf "${RED}ERROR: userdict_sync.icloud not configured in frontends.yaml${NC}\n" >&2
    return 1
  fi
  if [ -z "$onedrive_sync" ]; then
    printf "${RED}ERROR: userdict_sync.onedrive.darwin not configured in frontends.yaml${NC}\n" >&2
    return 1
  fi

  _check_dir "$icloud_sync" "iCloud" || return 1
  _check_dir "$onedrive_sync" "OneDrive" || return 1

  printf "${GREEN}=== Sync userdict: iCloud ↔ OneDrive ===${NC}\n" >&2
  printf "  iCloud:   %s\n" "$icloud_sync" >&2
  printf "  OneDrive: %s\n" "$onedrive_sync" >&2

  # Unison options
  local -a unison_opts=(
    -times                    # sync modification times
    -perms 0                  # ignore permission differences (cross-platform)
    -prefer newer             # on conflict, prefer newer file
    -ignore 'Name .DS_Store'  # ignore macOS metadata
    -ignore 'Name *.tmp'      # ignore temp files
  )

  if [ "$FORCE" -eq 1 ]; then
    unison_opts+=(-confirmbigdel=false)
  fi

  if [ "$DEBUG" -eq 1 ]; then
    printf "DEBUG: unison opts: %s\n" "${unison_opts[*]}" >&2
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    printf "${YELLOW}--- Dry run (preview only) ---${NC}\n" >&2
    # Show plan then quit without executing
    (sleep 1; printf '\nq\n') | timeout 30 unison "$icloud_sync" "$onedrive_sync" \
      "${unison_opts[@]}" -ui text 2>&1 \
      | grep -Ev "(No default command|^Proceed with|Failure reading)" \
      || true
    printf "${YELLOW}(dry-run: no changes made)${NC}\n" >&2
  else
    if [ "$VERBOSE" -eq 1 ]; then
      unison "$icloud_sync" "$onedrive_sync" "${unison_opts[@]}" -batch -auto
    else
      unison "$icloud_sync" "$onedrive_sync" "${unison_opts[@]}" -batch -auto -terse
    fi
  fi

  printf "${GREEN}=== Sync complete ===${NC}\n" >&2
}

main() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      --verbose) VERBOSE=1 ;;
      --debug) DEBUG=1 ;;
      --force) FORCE=1 ;;
      --help|-h) usage; exit 0 ;;
      *) printf "${RED}ERROR: Unknown option: %s${NC}\n" "$1" >&2; usage; exit 1 ;;
    esac
    shift
  done

  sync_userdict
}

main "$@"
