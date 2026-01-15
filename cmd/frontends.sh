#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
CONFIG_YAML="$REPO_DIR/cmd/frontends.yaml"

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

_yq_f() {
  _require_yq >/dev/null
  local frontend="$1"
  shift
  F="$frontend" yq e "$@" "$CONFIG_YAML"
}

frontend_resolve_auto() {
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


frontend_ui_layer() {
  local frontend="$1"
  if [ ! -f "$CONFIG_YAML" ]; then
    echo "$frontend"
    return 0
  fi

  _yq_f "$frontend" -r '.frontends[strenv(F)].ui_layer // "none"'
}

frontend_rsync_filter_file() {
  local frontend="$1"
  if [ ! -f "$CONFIG_YAML" ]; then
    echo ""
    return 0
  fi

  _yq_f "$frontend" -r '.frontends[strenv(F)].rsync_filter // ""'
}

frontend_bootstrap_filter_file() {
  local frontend="$1"
  if [ ! -f "$CONFIG_YAML" ]; then
    echo ""
    return 0
  fi

  _yq_f "$frontend" -r '.frontends[strenv(F)].bootstrap_filter // ""'
}

frontend_target_dir() {
  local frontend="$1"

  if [ ! -f "$CONFIG_YAML" ]; then
    echo ""
    return 0
  fi

  local target_path
  target_path=$(_yq_f "$frontend" -r '.frontends[strenv(F)].target_dir // ""')

  # 展开 ~ 为 $HOME
  if [ -n "$target_path" ]; then
    target_path="${target_path/#\~/$HOME}"
  fi

  echo "$target_path"
}

frontend_redeploy_cmd() {
  local frontend="$1"
  if [ ! -f "$CONFIG_YAML" ]; then
    echo ""
    return 0
  fi
  local cmd
  cmd="$(_yq_f "$frontend" -r '.frontends[strenv(F)].redeploy_cmd // ""')"
  [ -n "$cmd" ] && echo "$cmd" || echo ""
}

frontend_sync_cmd() {
  local frontend="$1"
  if [ ! -f "$CONFIG_YAML" ]; then
    echo ""
    return 0
  fi
  local cmd
  cmd="$(_yq_f "$frontend" -r '.frontends[strenv(F)].sync_cmd // ""')"
  [ -n "$cmd" ] && echo "$cmd" || echo ""
}

frontend_active_list() {
  if [ ! -f "$CONFIG_YAML" ]; then
    echo "none"
    return 0
  fi

  local active_frontends=()
  local auto_frontend
  auto_frontend="$(frontend_resolve_auto)"

  # Get all frontends with active: true
  local true_list
  true_list=$(_yq -r '.frontends | to_entries[] | select(.value.active == true) | .key' "$CONFIG_YAML" 2>/dev/null | grep -v '^---$' | grep -v '^$' || true)

  # Get all frontends with active: auto
  local auto_list
  auto_list=$(_yq -r '.frontends | to_entries[] | select(.value.active == "auto") | .key' "$CONFIG_YAML" 2>/dev/null | grep -v '^---$' | grep -v '^$' || true)

  # Add all active: true frontends
  while IFS= read -r f; do
    [ -n "$f" ] && active_frontends+=("$f")
  done <<< "$true_list"

  # Add auto-detected frontend if it exists and has active: auto
  if [ -n "$auto_frontend" ] && [ "$auto_frontend" != "none" ]; then
    while IFS= read -r f; do
      if [ "$f" = "$auto_frontend" ]; then
        active_frontends+=("$f")
        break
      fi
    done <<< "$auto_list"
  fi

  if [ ${#active_frontends[@]} -eq 0 ]; then
    echo "none"
  else
    # Deduplicate and output
    printf '%s\n' "${active_frontends[@]}" | sort -u
  fi
}
