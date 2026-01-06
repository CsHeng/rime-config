#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
CONFIG_YAML="$REPO_DIR/cmd/platforms.yaml"

_require_yq() {
  if ! command -v yq >/dev/null 2>&1; then
    echo "Missing dependency: yq (mikefarah/yq v4)" >&2
    return 1
  fi
}

_yq() {
  _require_yq >/dev/null
  yq e "$@" "$CONFIG_YAML"
}

_yq_p() {
  _require_yq >/dev/null
  local platform="$1"
  shift
  P="$platform" yq e "$@" "$CONFIG_YAML"
}

platform_resolve_auto() {
  if [ ! -f "$CONFIG_YAML" ]; then
    echo "none"
    return 0
  fi

  local os
  os=$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo "")
  case "$os" in
    darwin*) _yq -r '.auto.darwin // "none"' ;;
    msys*|mingw*|cygwin*) _yq -r '.auto.windows // "none"' ;;
    *) echo "none" ;;
  esac
}


platform_ui_layer() {
  local platform="$1"
  if [ ! -f "$CONFIG_YAML" ]; then
    echo "$platform"
    return 0
  fi

  _yq_p "$platform" -r '.platforms[strenv(P)].ui_layer // "none"'
}

platform_rsync_filter_file() {
  local platform="$1"
  if [ ! -f "$CONFIG_YAML" ]; then
    echo ""
    return 0
  fi

  _yq_p "$platform" -r '.platforms[strenv(P)].rsync_filter // ""'
}

platform_bootstrap_filter_file() {
  local platform="$1"
  if [ ! -f "$CONFIG_YAML" ]; then
    echo ""
    return 0
  fi

  _yq_p "$platform" -r '.platforms[strenv(P)].bootstrap_filter // ""'
}

platform_target_dir() {
  local platform="$1"

  if [ ! -f "$CONFIG_YAML" ]; then
    echo ""
    return 0
  fi

  local target_path
  target_path=$(_yq_p "$platform" -r '.platforms[strenv(P)].target_dir // ""')

  # 展开 ~ 为 $HOME
  if [ -n "$target_path" ]; then
    target_path="${target_path/#\~/$HOME}"
  fi

  echo "$target_path"
}
