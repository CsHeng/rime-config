#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_DIR=$(cd "$SCRIPT_DIR/.." && pwd)

TARGET_DIR=""
CONFIG_ARG=""
RUN_INIT=0

DEBUG=0
DRY_RUN=0
NO_DOWNLOAD=0
RSYNC_DELETE=0
REDEPLOY=1
SYNC=1
SYNC_ONLY=0
CLOUD_SYNC=0

# 75: 云桥链路停在「已提交」——Squirrel --sync 无完成信号，后桥接需人工执行
SYNC_CHAIN_PENDING=75

BUILD_DIR="$REPO_DIR/build"
TMP_DIR="$BUILD_DIR/tmp"
MARKERS_DIR="$BUILD_DIR/markers"
CACHE_DIR="$BUILD_DIR/cache"
UPSTREAM_DIR="$BUILD_DIR/upstream"
STAGE_ROOT="$BUILD_DIR/stage"

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

log() {
  local level="$1"
  shift
  local message="$*"

  case "$level" in
    info) printf "${GREEN}%s${NC}\n" "$message" >&2 ;;
    warn) printf "${YELLOW}%s${NC}\n" "$message" >&2 ;;
    error) printf "${RED}ERROR: %s${NC}\n" "$message" >&2 ;;
    debug)
      if [ "$DEBUG" -eq 1 ]; then
        printf "DEBUG: %s\n" "$message" >&2
      fi
      ;;
    *) printf "%s\n" "$message" >&2 ;;
  esac
}

usage() {
  cat <<USAGE
Usage: $0 [--config <file>] [--sync-only] [--target <dir>] [--init] [--dry-run]
          [--no-download] [--delete|--no-delete] [--[no-]redeploy] [--[no-]sync]
          [--cloud-sync] [--debug]

Flow:
- Download once -> build/upstream/
- Merge upstream + local/frontend overlays -> build/stage/<frontend>/
- rsync(filter) stage -> target

Active frontends are controlled by cmd/frontends.json (copy from frontends.json.tmpl):
  - "active": "auto" (default) - run if system detects the platform
  - "active": true - always run
  - "active": false - never run

Options:
  --config <file>   指定 frontends.json（默认 <repo>/cmd/frontends.json；相对路径相对 cwd）
  --sync-only       只调用桌面前端的 Rime 同步命令；跳过下载/stage/复制/redeploy
  --cloud-sync      用户词库云桥接（macOS only）：前桥接 -> Rime 同步 -> (后桥接)
                    Squirrel --sync 无完成信号，链路停在「已提交」，后桥接需手动执行
                    ./cmd/sync-userdict.sh（退出码 75）
  --target <dir>    覆盖目标目录；仅允许单一 active 前端，且非 dry-run 时必须
                    同时 --no-redeploy --no-sync
  --init            只补缺失的初始化模板（installation.yaml/user.yaml）
  --dry-run         预览；不写目标、不生成用户短语文件、不调用任何 hook/桥接
  --no-download     不检查上游更新（要求 build/upstream 已存在）

Environment:
  GITHUB_TOKEN     # GitHub API 认证（可选，避免 API 限流）；只从配置目录的 .env 读取
USAGE
}

require_cmd() {
  local c="$1"
  if ! command -v "$c" >/dev/null 2>&1; then
    log error "Missing dependency: $c"
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# rsync runtime helpers (unchanged behavior)
# ---------------------------------------------------------------------------
RSYNC_RUNTIME=""
RSYNC_EXE_PATH=""

detect_rsync_runtime() {
  if [ -n "${RSYNC_RUNTIME:-}" ]; then
    return 0
  fi

  RSYNC_EXE_PATH="$(command -v rsync 2>/dev/null || true)"
  RSYNC_RUNTIME="posix"

  local os
  os=$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo "")
  case "$os" in
    msys*|mingw*|cygwin*)
      local exe_lower=""
      exe_lower="$(printf '%s' "${RSYNC_EXE_PATH:-}" | tr '[:upper:]' '[:lower:]')"
      if [[ "$exe_lower" == *cwrsync* ]]; then
        RSYNC_RUNTIME="cygwin"
      else
        if rsync --version 2>/dev/null | tr '[:upper:]' '[:lower:]' | grep -q 'cygwin'; then
          RSYNC_RUNTIME="cygwin"
        fi
      fi
      ;;
  esac

  if [ "$DEBUG" -eq 1 ]; then
    log debug "rsync: ${RSYNC_EXE_PATH:-<not found>}"
    log debug "rsync runtime: $RSYNC_RUNTIME"
    local ver_line
    ver_line="$(rsync --version 2>/dev/null | head -n1 || true)"
    [ -n "$ver_line" ] && log debug "$ver_line"
  fi
}

rsync_path_normalize() {
  local p="$1"
  detect_rsync_runtime

  # For Git Bash/MSYS with native Windows rsync, convert /d/... to /cygdrive/d/...
  local os
  os=$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo "")
  if [[ "$os" =~ msys*|mingw* ]] && [ "$RSYNC_RUNTIME" != "cygwin" ]; then
    if [[ "$p" =~ ^/([a-zA-Z])/(.*)$ ]]; then
      local drive="${BASH_REMATCH[1]}"
      local rest="${BASH_REMATCH[2]}"
      printf '/cygdrive/%s/%s' "$drive" "$rest"
      return 0
    fi
  fi

  # For cygwin rsync runtime, convert /d/... to /cygdrive/d/...
  if [ "$RSYNC_RUNTIME" = "cygwin" ]; then
    if [[ "$p" =~ ^/([a-zA-Z])/(.*)$ ]]; then
      local drive="${BASH_REMATCH[1]}"
      local rest="${BASH_REMATCH[2]}"
      printf '/cygdrive/%s/%s' "$drive" "$rest"
      return 0
    fi
  fi

  printf '%s' "$p"
}

strip_trailing_slashes() {
  local p="$1"
  while [[ "$p" == */ ]]; do
    p="${p%/}"
  done
  printf '%s' "$p"
}

# 词法规范化：去重斜杠、解析 . 与 ..（不要求路径存在；符号链接不解析，与 rsync 的同名保护同限）
normalize_path_lex() {
  local p="$1" out="" part
  case "$p" in
    /*) ;;
    *) p="$PWD/$p" ;;
  esac
  local IFS='/'
  for part in $p; do
    [ -z "$part" ] && continue
    case "$part" in
      ".") ;;
      "..") out="${out%/*}" ;;
      *) out="$out/$part" ;;
    esac
  done
  printf '%s' "${out:-/}"
}

# 目录相同或互为祖先/后代则返回 0（拒绝）
paths_overlap() {
  local a b
  a="$(strip_trailing_slashes "$(normalize_path_lex "$(rsync_path_normalize "$1")")")"
  b="$(strip_trailing_slashes "$(normalize_path_lex "$(rsync_path_normalize "$2")")")"
  [ "$a" = "$b" ] && return 0
  case "$a/" in
    "$b/"*) return 0 ;;
  esac
  case "$b/" in
    "$a/"*) return 0 ;;
  esac
  return 1
}

assert_not_same_dir() {
  if paths_overlap "$1" "$2"; then
    log error "Refusing to rsync: source and destination resolve to overlapping paths"
    log error "  src: $1"
    log error "  dst: $2"
    return 1
  fi
}

rsync_run() {
  detect_rsync_runtime

  local -a args=()
  local i=0
  local a
  for a in "$@"; do
    args+=("$a")
    i=$((i + 1))
  done

  # Normalize option-embedded paths (e.g. --filter=merge <file>)
  # Both Cygwin rsync and native Windows rsync in MSYS/MinGW need this
  local os
  os=$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo "")
  if [ "$RSYNC_RUNTIME" = "cygwin" ] || [[ "$os" =~ msys*|mingw* ]]; then
    for i in "${!args[@]}"; do
      if [[ "${args[$i]}" == --filter=merge\ * ]]; then
        local merge_path="${args[$i]#--filter=merge }"
        local merge_norm
        merge_norm="$(rsync_path_normalize "$merge_path")"
        args[$i]="--filter=merge $merge_norm"
        if [ "$DEBUG" -eq 1 ] && [ "$merge_path" != "$merge_norm" ]; then
          log debug "rsync filter: $merge_path -> $merge_norm"
        fi
      fi
    done
  fi

  local -a operand_idx=()
  for i in "${!args[@]}"; do
    if [[ "${args[$i]}" != -* ]]; then
      operand_idx+=("$i")
    fi
  done

  if [ "${#operand_idx[@]}" -ge 2 ]; then
    for i in "${operand_idx[@]}"; do
      local orig="${args[$i]}"
      local norm
      # Always normalize paths (don't convert to Windows format)
      # rsync works better when both paths are in POSIX format
      norm="$(rsync_path_normalize "$orig")"
      args[$i]="$norm"
      if [ "$DEBUG" -eq 1 ] && [ "$orig" != "$norm" ]; then
        log debug "rsync path: $orig -> $norm"
      fi
    done
  fi

  # Run rsync - prevent MSYS2 from converting paths for native Windows rsync
  # MSYS2_ARG_CONV_EXCL='*' prevents argument conversion, preserving /cygdrive/d/... format
  if [ "$DEBUG" -eq 1 ]; then
    log debug "rsync args: ${args[*]}"
  fi
  MSYS2_ARG_CONV_EXCL='*' rsync "${args[@]}"
}

ensure_dirs() {
  mkdir -p "$TMP_DIR" "$MARKERS_DIR" "$CACHE_DIR" "$UPSTREAM_DIR" "$STAGE_ROOT"
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

  local filter_file
  filter_file="$(frontend_bootstrap_filter_file "$resolved")"
  if [ ! -f "$filter_file" ]; then
    log error "Missing bootstrap filter for frontend '$resolved': $filter_file"
    return 1
  fi

  if [ "$DRY_RUN" -eq 0 ]; then
    mkdir -p "$target"
    rsync_run -a --ignore-existing \
      --filter="merge $filter_file" \
      "$tpl_dir" "$target/"
    log info "Initialized templates: $resolved -> $target"
  else
    log info "(dry-run) init templates: $resolved -> $target"
    rsync_run -n -i -a --ignore-existing \
      --filter="merge $filter_file" \
      "$tpl_dir" "$target/"
  fi
}

github_releases_json() {
  local repo="$1"
  local out_file="$2"
  local api_url="https://api.github.com/repos/${repo}/releases"

  if [ -n "${GITHUB_TOKEN:-}" ]; then
    if ! curl -L -sS -H "Authorization: token ${GITHUB_TOKEN}" "$api_url" -o "$out_file"; then
    log error "Failed to fetch GitHub releases: $repo"
    return 1
  fi
  else
    if ! curl -L -sS "$api_url" -o "$out_file"; then
    log error "Failed to fetch GitHub releases: $repo"
    return 1
  fi
  fi

  if [ ! -s "$out_file" ] || ! jq empty "$out_file" >/dev/null 2>&1; then
    log error "Invalid GitHub API response: $repo"
    return 1
  fi

  if jq -e 'type=="object" and has("message")' "$out_file" >/dev/null 2>&1; then
    local msg
    msg="$(jq -r '.message' "$out_file" 2>/dev/null || true)"
    log error "GitHub API error ($repo): ${msg}"
    return 1
  fi

  return 0
}

github_find_asset() {
  # Prints: tag_name|version|url
  local repo="$1"
  local tag_prefix="$2"
  local asset_name="$3"
  local version_mode="$4" # tag|asset_updated_at

  local json="$TMP_DIR/${repo//\//_}.releases.json"
  github_releases_json "$repo" "$json" || return 1

  local tag
  tag="$(jq -r --arg pfx "$tag_prefix" '.[] | select(.tag_name | startswith($pfx)) | .tag_name' "$json" | head -1)"
  if [ -z "$tag" ] || [ "$tag" = "null" ]; then
    log error "No release tag starting with '$tag_prefix' in $repo"
    return 1
  fi

  local url
  url="$(jq -r --arg tag "$tag" --arg file "$asset_name" '.[] | select(.tag_name==$tag) | .assets[] | select(.name==$file) | .browser_download_url' "$json" | head -1)"
  if [ -z "$url" ] || [ "$url" = "null" ]; then
    log error "Asset not found in $repo@$tag: $asset_name"
    return 1
  fi

  local version=""
  case "$version_mode" in
    tag) version="$tag" ;;
    asset_updated_at)
      version="$(jq -r --arg tag "$tag" --arg file "$asset_name" '.[] | select(.tag_name==$tag) | .assets[] | select(.name==$file) | .updated_at' "$json" | head -1)"
      ;;
    *)
      log error "Unknown version mode: $version_mode"
      return 1
      ;;
  esac

  if [ -z "$version" ] || [ "$version" = "null" ]; then
    version="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  fi

  echo "${tag}|${version}|${url}"
}

marker_get() {
  local f="$1"
  if [ -f "$f" ]; then
    tr -d '[:space:]' <"$f"
  fi
}

marker_set() {
  local f="$1"
  local v="$2"
  printf '%s' "$v" >"$f"
}

download_to_cache() {
  local url="$1"
  local out_file="$2"
  local tmp_file="$out_file.tmp"

  log info "Downloading: $(basename "$out_file")"
  if ! curl -L -sS "$url" -o "$tmp_file"; then
    rm -f "$tmp_file"
    log error "Download failed: $url"
    return 1
  fi
  mv -f "$tmp_file" "$out_file"
}

unzip_into_dir() {
  local zip="$1"
  local dest="$2"
  mkdir -p "$dest"
  unzip -o "$zip" -d "$dest" >/dev/null
}

extract_zip_flatten() {
  local zip="$1"
  local dest="$2"
  local tmp="$TMP_DIR/extract_$$"

  rm -rf "$tmp"
  mkdir -p "$tmp" "$dest"
  unzip -o "$zip" -d "$tmp" >/dev/null

  find "$tmp" -maxdepth 2 -type f -print0 | while IFS= read -r -d '' f; do
    rsync_run -a "$f" "$dest/"
  done

  rm -rf "$tmp"
}

update_upstream_cache() {
  ensure_dirs
  require_cmd rsync
  require_cmd curl
  require_cmd jq
  require_cmd unzip

  local schema_repo="amzxyz/rime-wanxiang"

  # schema
  local schema_asset="rime-wanxiang-base.zip"
  local schema_marker="$MARKERS_DIR/schema_version"
  local schema_zip="$CACHE_DIR/$schema_asset"

  local schema_info
  schema_info="$(github_find_asset "$schema_repo" "v" "$schema_asset" "tag")"
  local schema_version
  schema_version="$(echo "$schema_info" | cut -d'|' -f2)"
  local schema_url
  schema_url="$(echo "$schema_info" | cut -d'|' -f3-)"

  local schema_stored
  schema_stored="$(marker_get "$schema_marker" || true)"

  if [ "$schema_version" != "$schema_stored" ] || [ -z "$(ls -A "$UPSTREAM_DIR" 2>/dev/null || true)" ]; then
    download_to_cache "$schema_url" "$schema_zip"
    rm -rf "$UPSTREAM_DIR"
    mkdir -p "$UPSTREAM_DIR"
    log info "Extracting schema -> build/upstream/"
    unzip_into_dir "$schema_zip" "$UPSTREAM_DIR"
    marker_set "$schema_marker" "$schema_version"
  else
    log info "Schema up to date: $schema_version"
  fi

  # dicts
  local dicts_asset="base-dicts.zip"
  local dicts_marker="$MARKERS_DIR/dicts_version"
  local dicts_zip="$CACHE_DIR/$dicts_asset"

  local dicts_info
  dicts_info="$(github_find_asset "$schema_repo" "dict-nightly" "$dicts_asset" "asset_updated_at")"
  local dicts_version
  dicts_version="$(echo "$dicts_info" | cut -d'|' -f2)"
  local dicts_url
  dicts_url="$(echo "$dicts_info" | cut -d'|' -f3-)"

  local dicts_stored
  dicts_stored="$(marker_get "$dicts_marker" || true)"

  if [ "$dicts_version" != "$dicts_stored" ] || [ ! -d "$UPSTREAM_DIR/dicts" ]; then
    download_to_cache "$dicts_url" "$dicts_zip"
    rm -rf "$UPSTREAM_DIR/dicts"
    mkdir -p "$UPSTREAM_DIR/dicts"
    log info "Extracting dicts -> build/upstream/dicts/"
    extract_zip_flatten "$dicts_zip" "$UPSTREAM_DIR/dicts"
    marker_set "$dicts_marker" "$dicts_version"
  else
    log info "Dicts up to date: $dicts_version"
  fi

  # grammar (data repo renamed from amzxyz/RIME-LMDG)
  local grammar_repo="amzxyz/rime-wanxiang-data"
  local grammar_asset="wanxiang-lts-zh-hans.gram"
  local grammar_marker="$MARKERS_DIR/grammar_version"
  local grammar_file="$CACHE_DIR/$grammar_asset"

  local grammar_info
  grammar_info="$(github_find_asset "$grammar_repo" "LTS" "$grammar_asset" "asset_updated_at")"
  local grammar_version
  grammar_version="$(echo "$grammar_info" | cut -d'|' -f2)"
  local grammar_url
  grammar_url="$(echo "$grammar_info" | cut -d'|' -f3-)"

  local grammar_stored
  grammar_stored="$(marker_get "$grammar_marker" || true)"

  if [ "$grammar_version" != "$grammar_stored" ] || [ ! -f "$UPSTREAM_DIR/$grammar_asset" ]; then
    download_to_cache "$grammar_url" "$grammar_file"
    log info "Updating grammar -> build/upstream/$grammar_asset"
    rsync_run -a "$grammar_file" "$UPSTREAM_DIR/$grammar_asset"
    marker_set "$grammar_marker" "$grammar_version"
  else
    log info "Grammar up to date: $grammar_version"
  fi
}

build_stage_dir() {
  # upstream + local/frontend overlays -> build/stage/<frontend>/
  local frontend="$1"
  local ui_layer="$2" # none|<frontend>

  local stage="$STAGE_ROOT/$frontend"
  rm -rf "$stage"
  mkdir -p "$stage"

  if [ "$frontend" != "none" ]; then
    # Stage 只做合并（upstream + overlays）；最终写入 target 的过滤由 cmd/<frontend>/rsync.filter 负责。
    rsync_run -a --exclude='.DS_Store' "$UPSTREAM_DIR/" "$stage/"
  fi

  # local layer (repo tracked)
  # 自定义置顶短语词库（gitignored）；缺失时用模板生成，保证 custom_phrase_user 始终可编译。
  # dry-run 只把示例放进 stage，不在仓库生成用户副本；实际执行才生成。
  local phrase_dict="$REPO_DIR/custom_phrase_user.dict.yaml"
  local phrase_example="$REPO_DIR/custom_phrase_user.dict.yaml.example"
  if [ ! -f "$phrase_dict" ] && [ -f "$phrase_example" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
      rsync_run -a "$phrase_example" "$stage/custom_phrase_user.dict.yaml"
      log info "(dry-run) stage 使用示例短语模板；未生成 custom_phrase_user.dict.yaml"
    else
      cp "$phrase_example" "$phrase_dict"
      log warn "Created custom_phrase_user.dict.yaml from template (edit it to add your phrases)"
    fi
  fi
  if [ -f "$phrase_dict" ]; then
    rsync_run -a "$phrase_dict" "$stage/"
  fi

  shopt -s nullglob
  local f
  for f in "$REPO_DIR"/*.custom.yaml; do
    rsync_run -a "$f" "$stage/"
  done
  shopt -u nullglob

  # UI overlays (only when enabled)
  if [ -n "$ui_layer" ] && [ "$ui_layer" != "none" ]; then
    if [ -f "$REPO_DIR/cmd/common/default.custom.yaml" ]; then
      rsync_run -a "$REPO_DIR/cmd/common/default.custom.yaml" "$stage/default.custom.yaml"
    fi

    local tpl_dir="$REPO_DIR/cmd/$ui_layer"
    if [ -d "$tpl_dir" ]; then
      shopt -s nullglob
      # UI 层只取 patch 与 Hamster3 的 include_keyboard_rime_files.txt（键盘→应用 包含规则）
      local files=("$tpl_dir"/*.custom.yaml "$tpl_dir"/*.txt)
      shopt -u nullglob
      if [ "${#files[@]}" -gt 0 ]; then
        rsync_run -a "${files[@]}" "$stage/"
      fi
    fi
  fi

  echo "$stage"
}

rsync_stage_to_target() {
  local frontend="$1"
  local stage="$2"
  local target="$3"

  local filter_file
  filter_file="$(frontend_rsync_filter_file "$frontend")"
  if [ -z "$filter_file" ] || [ ! -f "$filter_file" ]; then
    log error "Missing rsync filter for frontend '$frontend': $filter_file"
    return 1
  fi

  if [ "$DRY_RUN" -eq 0 ]; then
    mkdir -p "$target"
  fi

  local rsync_opts=(-a)
  if [ "$RSYNC_DELETE" -eq 1 ]; then
    rsync_opts+=(--delete)
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    rsync_opts+=(-n -i)
  fi

  log info "Stage -> $frontend : $target"
  assert_not_same_dir "$stage" "$target"
  if [ "$DEBUG" -eq 1 ]; then
    log debug "Stage(rsync): $(rsync_path_normalize "$stage/")"
    log debug "Target(rsync): $(rsync_path_normalize "$target/")"
  fi
  rsync_run "${rsync_opts[@]}" \
    --filter="merge $filter_file" \
    --exclude='.DS_Store' \
    "$stage/" "$target/"
}

# ---------------------------------------------------------------------------
# 前端命令（{executable, args} 对象；数组执行，不做 shell 字符串解析）
# ---------------------------------------------------------------------------

# 从 frontend_*_cmd 的 NUL 分隔流读取为 CMD_EXE + CMD_ARGS 数组。
# 必须用进程替换直读（read -rd ''）；空字符串参数与内嵌换行完整保留。
# 用法: read_cmd_fields < <(frontend_sync_cmd "$frontend")
read_cmd_fields() {
  CMD_EXE=""
  CMD_ARGS=()
  local item first=1
  while IFS= read -rd '' item; do
    if [ "$first" -eq 1 ]; then
      CMD_EXE="$item"
      first=0
    else
      CMD_ARGS+=("$item")
    fi
  done
}

# 解析可执行文件：带路径分隔符时相对配置目录解析并要求存在；裸名称走 PATH
resolve_executable() {
  local exe="$1"
  if [[ "$exe" == */* ]]; then
    local resolved
    resolved="$(config_resolve_path "$exe")"
    if [ -x "$resolved" ]; then
      echo "$resolved"
      return 0
    fi
    printf "${RED}ERROR: executable not found or not executable: %s (resolved: %s)${NC}\n" "$exe" "$resolved" >&2
    return 1
  fi
  local found
  found="$(command -v "$exe" 2>/dev/null || true)"
  if [ -n "$found" ]; then
    echo "$found"
    return 0
  fi
  printf "${RED}ERROR: executable not found in PATH: %s${NC}\n" "$exe" >&2
  return 1
}

HOOK_FAILURES=""

# 执行前端命令；失败记录 frontend/stage/exit code 并返回非零（调用方决定是否继续）
run_frontend_cmd() {
  local frontend="$1" stage_label="$2" exe="$3"
  shift 3

  log info "Running [$stage_label] frontend '$frontend': $exe $*"
  local rc=0
  "$exe" "$@" || rc=$?
  if [ "$rc" -ne 0 ]; then
    HOOK_FAILURES="${HOOK_FAILURES}${frontend}|${stage_label}|${rc}
"
    log error "frontend '$frontend' stage '$stage_label' failed with exit code $rc (cmd: $exe $*)"
  fi
  return "$rc"
}

report_hook_summary_and_exit() {
  if [ -n "$HOOK_FAILURES" ]; then
    log error "失败的阶段 (frontend|stage|exit):"
    printf '%s' "$HOOK_FAILURES" | sed 's/^/  /' >&2
    exit 1
  fi
  exit 0
}

# Squirrel --sync 是异步通知（上游 Main.swift 仅 post 通知后退出，无完成信号）；
# Weasel /sync 同步等待维护线程结束，退出码即完成结果。
report_sync_submission() {
  local exe="$1"
  case "$(basename "$exe")" in
    Squirrel*)
      log info "已提交（异步通知）：进程退出不代表 Rime 同步完成，本工具无法观察其完成时机"
      ;;
    *)
      log info "同步命令已退出（退出码 0）。WeaselDeployer /sync 会等待同步完成；其他可执行文件的完成语义以其自身实现为准"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# 云桥接（macOS，Unison；由 cmd/sync-userdict.sh 执行）
# ---------------------------------------------------------------------------

run_cloud_bridge() {
  local label="$1"
  local -a opts=()
  [ "$DRY_RUN" -eq 1 ] && opts+=(--dry-run)
  [ "$DEBUG" -eq 1 ] && opts+=(--debug)

  log info "[cloud-bridge] $label ..."
  if ! "$SCRIPT_DIR/sync-userdict.sh" ${opts[@]+"${opts[@]}"}; then
    log error "[cloud-bridge] $label 失败（frontend: cloud-bridge, stage: $label）"
    return 1
  fi
  return 0
}

# Squirrel --sync 无完成信号：链路不能自动闭环，明确缺口与人工步骤。
# 后桥接提示包含桥脚本绝对路径与 --config 绝对路径（printf %q 引用，可直接复制到任意 cwd 执行；
# 子进程导出的 FRONTENDS_CONFIG 不会持久化到用户 shell，不显式传 --config 会桥接默认配置的另一对目录）
print_postbridge_gap_and_exit() {
  local bridge_cmd
  bridge_cmd="$(printf '%q' "$SCRIPT_DIR/sync-userdict.sh") --config $(printf '%q' "$FRONTENDS_CONFIG")"
  log warn "[cloud-bridge] 后桥接未自动执行：Squirrel --sync 为异步通知，本工具没有可信完成信号"
  log warn "[cloud-bridge] 待 Rime 同步完成后，手动执行后桥接（可直接复制）：$bridge_cmd"
  log warn "[cloud-bridge] 本次链路状态：前桥接完成 + Rime 同步已提交（未确认完成）"
  exit "$SYNC_CHAIN_PENDING"
}

# ---------------------------------------------------------------------------
# 目标校验（在任何目标写入/目录创建之前）
# ---------------------------------------------------------------------------
FRONTEND_LIST=()
TARGET_LIST=()

resolve_all_targets() {
  local frontend target
  while IFS= read -r frontend; do
    [ -z "$frontend" ] && continue
    target="$TARGET_DIR"
    if [ -z "$target" ]; then
      target="$(frontend_target_dir "$frontend")"
    fi
    if [ -z "$target" ]; then
      log error "Missing target for frontend '$frontend' (use --target or set target_dir in the config)"
      return 1
    fi
    FRONTEND_LIST+=("$frontend")
    TARGET_LIST+=("$target")
  done <<< "$ACTIVE_FRONTENDS"
  return 0
}

validate_targets() {
  local n=${#TARGET_LIST[@]}
  local i j

  if [ -n "$TARGET_DIR" ] && [ "$n" -gt 1 ]; then
    log error "--target 只允许单一 active 前端（当前 active: ${FRONTEND_LIST[*]}）"
    return 1
  fi

  if [ -n "$TARGET_DIR" ] && [ "$DRY_RUN" -eq 0 ]; then
    if [ "$REDEPLOY" -eq 1 ] || [ "$SYNC" -eq 1 ]; then
      log error "非 dry-run 使用 --target 覆盖目标时必须同时 --no-redeploy --no-sync（避免复制到沙盒目标却触发真实输入法）"
      return 1
    fi
  fi

  for ((i = 0; i < n; i++)); do
    for ((j = i + 1; j < n; j++)); do
      if [ "$(normalize_path_lex "$(strip_trailing_slashes "${TARGET_LIST[$i]}")")" = "$(normalize_path_lex "$(strip_trailing_slashes "${TARGET_LIST[$j]}")")" ]; then
        log error "frontends '${FRONTEND_LIST[$i]}' 与 '${FRONTEND_LIST[$j]}' 解析到同一目标目录：${TARGET_LIST[$i]}"
        return 1
      fi
    done
  done

  for ((i = 0; i < n; i++)); do
    local stage="$STAGE_ROOT/${FRONTEND_LIST[$i]}"
    local tpl_dir="$REPO_DIR/cmd/${FRONTEND_LIST[$i]}"
    if paths_overlap "$stage" "${TARGET_LIST[$i]}"; then
      log error "拒绝：stage 目录与目标重叠 (stage: $stage, target: ${TARGET_LIST[$i]})"
      return 1
    fi
    if paths_overlap "$tpl_dir" "${TARGET_LIST[$i]}"; then
      log error "拒绝：前端模板目录与目标重叠 (tpl: $tpl_dir, target: ${TARGET_LIST[$i]})"
      return 1
    fi
    if paths_overlap "$UPSTREAM_DIR" "${TARGET_LIST[$i]}"; then
      log error "拒绝：upstream 目录与目标重叠 (upstream: $UPSTREAM_DIR, target: ${TARGET_LIST[$i]})"
      return 1
    fi
  done
  return 0
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

# R2：对本次实际启用的 hooks 一次性预检可执行文件（在任何写入/云桥之前）；
# 关闭的 hook 不要求存在。结果存入并行数组供主循环复用。
REDEPLOY_EXES=()
SYNC_EXES=()

preflight_hook_executables() {
  local i frontend
  for ((i = 0; i < ${#FRONTEND_LIST[@]}; i++)); do
    frontend="${FRONTEND_LIST[$i]}"
    REDEPLOY_EXES[$i]=""
    SYNC_EXES[$i]=""
    [ "$DRY_RUN" -eq 1 ] && continue
    if [ "$REDEPLOY" -eq 1 ]; then
      read_cmd_fields < <(frontend_redeploy_cmd "$frontend")
      if [ -n "$CMD_EXE" ]; then
        REDEPLOY_EXES[$i]="$(resolve_executable "$CMD_EXE")" || exit 1
      fi
    fi
    if [ "$SYNC" -eq 1 ]; then
      read_cmd_fields < <(frontend_sync_cmd "$frontend")
      if [ -n "$CMD_EXE" ]; then
        SYNC_EXES[$i]="$(resolve_executable "$CMD_EXE")" || exit 1
      fi
    fi
  done
  return 0
}

validate_option_conflicts() {
  if [ "$SYNC_ONLY" -eq 1 ]; then
    local -a bad=()
    [ "$RUN_INIT" -eq 1 ] && bad+=(--init)
    [ "$RSYNC_DELETE" -eq 1 ] && bad+=(--delete)
    [ -n "$TARGET_DIR" ] && bad+=(--target)
    [ "$NO_DOWNLOAD" -eq 1 ] && bad+=(--no-download)
    [ "$SYNC" -eq 0 ] && bad+=(--no-sync)
    if [ "${#bad[@]}" -gt 0 ]; then
      log error "--sync-only 不能与更新专用选项组合: ${bad[*]}"
      return 1
    fi
  fi

  if [ "$CLOUD_SYNC" -eq 1 ] && [ "$SYNC" -eq 0 ]; then
    log error "--cloud-sync 需要 Rime 同步（云桥链路包含 Rime 同步），不能与 --no-sync 组合"
    return 1
  fi

  return 0
}

check_cloud_sync_platform() {
  local os
  os=$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo "")
  case "$os" in
    darwin*) return 0 ;;
    *)
      log error "--cloud-sync 仅在 macOS 上可用（iCloud ↔ OneDrive 桥接依赖 Unison）；当前系统: ${os:-unknown}"
      return 1
      ;;
  esac
}

sync_only_flow() {
  # 桌面前端 = 配置了 sync_cmd 的 active 前端；仅 iOS 前端（无 sync_cmd）不算完成
  local -a desktop=()
  local frontend
  while IFS= read -r frontend; do
    [ -z "$frontend" ] && continue
    read_cmd_fields < <(frontend_sync_cmd "$frontend")
    if [ -n "$CMD_EXE" ]; then
      desktop+=("$frontend")
    fi
  done <<< "$ACTIVE_FRONTENDS"

  if [ "${#desktop[@]}" -eq 0 ]; then
    log error "没有可调用的桌面 Rime 同步命令（active 前端均未配置 sync_cmd）；sync-only 未完成"
    exit 1
  fi

  # 预检：所有可执行文件必须可解析（在任何副作用前）
  for frontend in "${desktop[@]}"; do
    read_cmd_fields < <(frontend_sync_cmd "$frontend")
    resolve_executable "$CMD_EXE" >/dev/null || exit 1
  done

  if [ "$CLOUD_SYNC" -eq 1 ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
      log info "[cloud-bridge] (dry-run) 前桥接计划："
      run_cloud_bridge "前桥接(预览)" || exit 1
    else
      run_cloud_bridge "前桥接" || exit 1
    fi
  fi

  for frontend in "${desktop[@]}"; do
    read_cmd_fields < <(frontend_sync_cmd "$frontend")
    local exe
    exe="$(resolve_executable "$CMD_EXE")" || exit 1

    if [ "$DRY_RUN" -eq 1 ]; then
      log info "(dry-run) 将调用 [$frontend]: $exe ${CMD_ARGS[*]}"
      continue
    fi

    if ! run_frontend_cmd "$frontend" "Rime 同步" "$exe" ${CMD_ARGS[@]+"${CMD_ARGS[@]}"}; then
      continue
    fi
    report_sync_submission "$exe"
  done

  if [ "$DRY_RUN" -eq 1 ]; then
    if [ "$CLOUD_SYNC" -eq 1 ]; then
      log info "(dry-run) 后桥接不会自动执行（Squirrel --sync 无完成信号）；实际链路：前桥接 -> Rime 同步 -> 手动后桥接"
    fi
    report_hook_summary_and_exit
  fi

  if [ -n "$HOOK_FAILURES" ]; then
    report_hook_summary_and_exit
  fi

  if [ "$CLOUD_SYNC" -eq 1 ]; then
    print_postbridge_gap_and_exit
  fi
  exit 0
}

main() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --config) shift; CONFIG_ARG="${1:-}" ;;
      --target) shift; TARGET_DIR="${1:-}" ;;
      --init) RUN_INIT=1 ;;
      --debug) DEBUG=1 ;;
      --dry-run) DRY_RUN=1 ;;
      --no-download) NO_DOWNLOAD=1 ;;
      --no-delete) RSYNC_DELETE=0 ;;
      --delete) RSYNC_DELETE=1 ;;
      --redeploy) REDEPLOY=1 ;;
      --no-redeploy) REDEPLOY=0 ;;
      --sync) SYNC=1 ;;
      --no-sync) SYNC=0 ;;
      --sync-only) SYNC_ONLY=1 ;;
      --cloud-sync) CLOUD_SYNC=1 ;;
      --help|-h) usage; exit 0 ;;
      *) log error "Unknown option: $1"; usage; exit 1 ;;
    esac
    shift
  done

  validate_option_conflicts

  # 配置路径：显式 --config 相对调用者 cwd；默认本仓库 cmd/frontends.json
  local config_file="$REPO_DIR/cmd/frontends.json"
  if [ -n "$CONFIG_ARG" ]; then
    case "$CONFIG_ARG" in
      /*) config_file="$CONFIG_ARG" ;;
      *) config_file="$PWD/$CONFIG_ARG" ;;
    esac
  fi
  export FRONTENDS_CONFIG="$config_file"

  # .env 只从配置目录加载（GITHUB_TOKEN 等）；set -a 使变量同时导出给子进程
  local config_dir
  config_dir="$(dirname "$config_file")"
  if [ -f "$config_dir/.env" ]; then
    set -a
    # shellcheck disable=SC1090
    source "$config_dir/.env"
    set +a
  fi

  # shellcheck disable=SC1090
  source "$SCRIPT_DIR/frontends.sh"

  require_cmd jq

  # --target: ~ 展开并相对 cwd 转绝对（pattern '\~' 避免波浪号被展开）
  if [ -n "$TARGET_DIR" ]; then
    TARGET_DIR="${TARGET_DIR/#\~/$HOME}"
    case "$TARGET_DIR" in
      /*) ;;
      *) TARGET_DIR="$PWD/$TARGET_DIR" ;;
    esac
  fi

  local active_frontends
  active_frontends="$(frontend_active_list)"
  ACTIVE_FRONTENDS="$active_frontends"

  if [ -z "$ACTIVE_FRONTENDS" ] || [ "$ACTIVE_FRONTENDS" = "none" ]; then
    log error "No active frontends found. Set \"active\": true in $config_file"
    exit 1
  fi

  log info "Active frontends: $(echo "$ACTIVE_FRONTENDS" | tr '\n' ' ')"

  if [ "$CLOUD_SYNC" -eq 1 ]; then
    check_cloud_sync_platform
  fi

  if [ "$SYNC_ONLY" -eq 1 ]; then
    sync_only_flow
  fi

  require_cmd rsync
  # 在主 shell 初始化缓存；路径校验/stage 内的 $(...) 无法把探测结果传回父 shell。
  # 放在 sync-only 分支之后，保持纯同步流程不依赖 rsync。
  detect_rsync_runtime

  # P3.4：目标解析/冲突/重叠校验在任何 build 目录创建、下载、云桥或目标写入之前完成
  resolve_all_targets
  validate_targets

  # R2：本次启用的 hooks 先预检可执行文件（在任何写入/云桥之前，失败不进入后续阶段）
  preflight_hook_executables

  if [ "$CLOUD_SYNC" -eq 1 ]; then
    # 前桥接在任何上游检查/写入之前执行（自身含配置、目录、Unison 预检）
    run_cloud_bridge "前桥接" || exit 1
  fi

  ensure_dirs

  if [ "$NO_DOWNLOAD" -eq 0 ]; then
    update_upstream_cache
  else
    if [ -z "$(ls -A "$UPSTREAM_DIR" 2>/dev/null || true)" ]; then
      log error "--no-download set but build/upstream is empty"
      exit 1
    fi
  fi

  # Process each active frontend
  local idx
  for ((idx = 0; idx < ${#FRONTEND_LIST[@]}; idx++)); do
    local frontend="${FRONTEND_LIST[$idx]}"
    local target="${TARGET_LIST[$idx]}"

    log info "=== Processing frontend: $frontend ==="

    local ui_layer
    ui_layer="$(frontend_ui_layer "$frontend")"

    if [ "$RUN_INIT" -eq 1 ]; then
      rsync_bootstrap_templates "$frontend" "$target"
    fi

    local stage
    stage="$(build_stage_dir "$frontend" "$ui_layer")"
    rsync_stage_to_target "$frontend" "$stage" "$target"

    # Post-update hooks（可执行文件已在 preflight_hook_executables 预检并复用）
    if [ "$DRY_RUN" -eq 0 ]; then
      if [ "$REDEPLOY" -eq 1 ] && [ -n "${REDEPLOY_EXES[$idx]}" ]; then
        read_cmd_fields < <(frontend_redeploy_cmd "$frontend")
        run_frontend_cmd "$frontend" "redeploy" "${REDEPLOY_EXES[$idx]}" ${CMD_ARGS[@]+"${CMD_ARGS[@]}"} || true
      fi

      if [ "$SYNC" -eq 1 ] && [ -n "${SYNC_EXES[$idx]}" ]; then
        read_cmd_fields < <(frontend_sync_cmd "$frontend")
        if run_frontend_cmd "$frontend" "Rime 同步" "${SYNC_EXES[$idx]}" ${CMD_ARGS[@]+"${CMD_ARGS[@]}"}; then
          report_sync_submission "${SYNC_EXES[$idx]}"
        fi
      fi
    fi

    log info "=== Completed: $frontend ==="
  done

  if [ "$DRY_RUN" -eq 1 ]; then
    log info "(dry-run) 未写入目标、未生成用户短语文件、未调用 redeploy/sync/云桥"
    report_hook_summary_and_exit
  fi

  # Rime/部署失败优先于链路缺口上报（失败不因云桥缺口被掩盖）
  if [ -n "$HOOK_FAILURES" ]; then
    report_hook_summary_and_exit
  fi

  if [ "$CLOUD_SYNC" -eq 1 ]; then
    print_postbridge_gap_and_exit
  fi

  report_hook_summary_and_exit
}

main "$@"
