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

platform_target_dir() {
  local platform="$1"

  if [ ! -f "$CONFIG_YAML" ]; then
    echo ""
    return 0
  fi

  local t
  t=$(_yq_p "$platform" -r '.platforms[strenv(P)].target.type // "unset"')

  case "$t" in
    home_subpath)
      local sub
      sub=$(_yq_p "$platform" -r '.platforms[strenv(P)].target.subpath // ""')
      if [ -z "$sub" ]; then
        echo ""
      else
        echo "${HOME}/${sub}"
      fi
      ;;
    icloud_docs)
      local env_key
      local def
      local sub
      env_key=$(_yq_p "$platform" -r '.platforms[strenv(P)].target.icloud_base_env // ""')
      def=$(_yq_p "$platform" -r '.platforms[strenv(P)].target.icloud_base_default // ""')
      sub=$(_yq_p "$platform" -r '.platforms[strenv(P)].target.subpath // ""')

      if [ -z "$env_key" ] || [ -z "$def" ] || [ -z "$sub" ]; then
        echo ""
        return 0
      fi

      local base="${!env_key:-$def}"
      echo "${HOME}/Library/Mobile Documents/${base}/${sub}"
      ;;
    unset|none|"")
      echo ""
      ;;
    *)
      echo ""
      ;;
  esac
}
