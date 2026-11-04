#!/bin/bash
set -euo pipefail

# 用户词库云同步脚本 (Unison 双向同步)
# macOS 作为中转站，双向同步 iCloud ↔ OneDrive
#
# 同步拓扑:
#   Windows (weasel) ←→ OneDrive ←→ macOS (squirrel) ←→ iCloud ←→ iOS (hamster/hamster3)
#
# 说明:
#   - Rime 的词条合并由各设备自己的 Rime 同步完成；本脚本只搬运快照文件。
#   - --dry-run 不启动 Unison，仅输出目录、策略与待执行步骤；
#     它不是云端文件差异的精确预览。

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

DRY_RUN=0
DEBUG=0
VERBOSE=0
FORCE=0
CONFIG_ARG=""

usage() {
  cat <<USAGE
Usage: $0 [--config <file>] [--dry-run] [--verbose] [--debug] [--force]

Sync user dictionaries between iCloud and OneDrive (macOS only).
Uses Unison for true bidirectional sync with conflict detection.

Options:
  --config <file>  使用指定的 frontends.json（默认与本脚本同目录的 frontends.json）
  --dry-run        只输出目录、策略与待执行步骤，不启动 Unison，不做任何修改
  --verbose        显示 Unison 详细输出
  --debug          启用调试日志
  --force          跳过大量删除确认 (unison -confirmbigdel=false)

Requires: jq, unison (brew install unison)
USAGE
}

_require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    printf "${RED}ERROR: Missing dependency: jq${NC}\n" >&2
    return 1
  fi
}

_check_macos() {
  local os
  os=$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo "")
  case "$os" in
    darwin*) return 0 ;;
    *)
      printf "${RED}ERROR: This script runs on macOS only (current: %s)${NC}\n" "$os" >&2
      printf "  Windows 端没有云桥：小狼毫直接同步到本机 OneDrive 目录（见 README）\n" >&2
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

  # shellcheck disable=SC1090
  source "$SCRIPT_DIR/frontends.sh"
  frontends_validate || return 1

  local icloud_sync onedrive_sync
  icloud_sync="$(userdict_icloud_path)"
  onedrive_sync="$(userdict_onedrive_path)"

  if [ -z "$icloud_sync" ]; then
    printf "${RED}ERROR: userdict_sync.icloud not configured in %s${NC}\n" "$(_config_file)" >&2
    return 1
  fi
  if [ -z "$onedrive_sync" ]; then
    printf "${RED}ERROR: userdict_sync.onedrive.darwin not configured in %s${NC}\n" "$(_config_file)" >&2
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
    printf "  待执行: unison \"%s\" \"%s\" %s -batch -auto\n" \
      "$icloud_sync" "$onedrive_sync" "${unison_opts[*]}" >&2
    printf "  注意: 预览不启动 Unison，也不构成云端文件差异的精确预览；实际执行才进行双向同步。\n" >&2
    return 0
  fi

  local rc=0
  if [ "$VERBOSE" -eq 1 ]; then
    unison "$icloud_sync" "$onedrive_sync" "${unison_opts[@]}" -batch -auto || rc=$?
  else
    unison "$icloud_sync" "$onedrive_sync" "${unison_opts[@]}" -batch -auto -terse || rc=$?
  fi

  if [ "$rc" -ne 0 ]; then
    printf "${RED}ERROR: userdict sync (Unison) failed with exit code %s${NC}\n" "$rc" >&2
    printf "  iCloud:   %s\n" "$icloud_sync" >&2
    printf "  OneDrive: %s\n" "$onedrive_sync" >&2
    return "$rc"
  fi

  printf "${GREEN}=== Sync complete ===${NC}\n" >&2
}

main() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --config) shift; CONFIG_ARG="${1:-}" ;;
      --dry-run) DRY_RUN=1 ;;
      --verbose) VERBOSE=1 ;;
      --debug) DEBUG=1 ;;
      --force) FORCE=1 ;;
      --help|-h) usage; exit 0 ;;
      *) printf "${RED}ERROR: Unknown option: %s${NC}\n" "$1" >&2; usage; exit 1 ;;
    esac
    shift
  done

  # 显式 --config 相对调用者 cwd 解析（与 update.sh 一致）
  if [ -n "$CONFIG_ARG" ]; then
    case "$CONFIG_ARG" in
      /*) FRONTENDS_CONFIG="$CONFIG_ARG" ;;
      *) FRONTENDS_CONFIG="$PWD/$CONFIG_ARG" ;;
    esac
    export FRONTENDS_CONFIG
  fi

  _require_jq || exit 1

  sync_userdict
}

main "$@"
