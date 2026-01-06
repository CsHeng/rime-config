#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_DIR=$(cd "$SCRIPT_DIR/.." && pwd)

# Source .env if present
if [ -f "$SCRIPT_DIR/.env" ]; then
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/.env"
fi

TARGET_DIR=${RIME_TARGET_DIR:-""}
PLATFORM=${RIME_PLATFORM:-auto}

usage() {
  cat <<USAGE
Usage: $0 --platform <squirrel|weasel|hamster|hamster3|auto|none> [--target <dir>]

Bootstraps into <target> (only if missing, via rsync):
- cmd/<platform>/{installation.yaml,user.yaml} -> <target>/{installation.yaml,user.yaml}

Notes:
- This script is optional; day-to-day you typically run cmd/update.sh
- It only bootstraps per-device templates (no upstream download, no local layer)

Environment:
  RIME_TARGET_DIR, RIME_PLATFORM
USAGE
}

resolve_platform() {
  local p="$1"
  if [ "$p" != "auto" ]; then
    echo "$p"; return 0
  fi
  local mapping="$REPO_DIR/cmd/platforms.sh"
  if [ -f "$mapping" ]; then
    # shellcheck disable=SC1090
    source "$mapping"
    platform_resolve_auto
    return 0
  fi
  echo "none"
}

rsync_bootstrap_templates() {
  local resolved="$1"
  local target="$2"

  if [ "$resolved" = "none" ]; then
    return 0
  fi

  local tpl_dir="$REPO_DIR/cmd/$resolved/"
  if [ ! -d "$tpl_dir" ]; then
    return 0
  fi

  mkdir -p "$target"
  rsync -a --ignore-existing \
    --include='installation.yaml' \
    --include='user.yaml' \
    --exclude='*' \
    "$tpl_dir" "$target/"
}

main() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --platform)
        shift; PLATFORM="$1" ;;
      --target)
        shift; TARGET_DIR="$1" ;;
      --help|-h)
        usage; exit 0 ;;
      *)
        echo "Unknown option: $1" >&2
        usage; exit 1 ;;
    esac
    shift
  done

  local resolved
  resolved=$(resolve_platform "$PLATFORM")

  local target="$TARGET_DIR"
  if [ -z "$target" ] && [ -f "$REPO_DIR/cmd/platforms.sh" ]; then
    # shellcheck disable=SC1090
    source "$REPO_DIR/cmd/platforms.sh"
    target="$(platform_target_dir "$resolved")"
  fi

  if [ -z "$target" ]; then
    echo "Missing --target (and no default target for platform '$resolved')" >&2
    usage
    exit 1
  fi

  rsync_bootstrap_templates "$resolved" "$target"
  echo "Initialized templates: $resolved -> $target" >&2
}

main "$@"
