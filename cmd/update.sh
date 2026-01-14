#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_DIR=$(cd "$SCRIPT_DIR/.." && pwd)

# Source .env if present for GITHUB_TOKEN (never tracked)
if [ -f "$SCRIPT_DIR/.env" ]; then
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/.env"
fi

TARGET_DIR=""
FRONTEND="auto"
RUN_INIT=0

DEBUG=0
DRY_RUN=0
NO_DOWNLOAD=0
RSYNC_DELETE=0
REDEPLOY=1
SYNC=1

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
    info) echo -e "${GREEN}[INFO]${NC} $message" >&2 ;;
    warn) echo -e "${YELLOW}[WARN]${NC} $message" >&2 ;;
    error) echo -e "${RED}[ERROR]${NC} $message" >&2 ;;
    debug)
      if [ "$DEBUG" -eq 1 ]; then
        echo -e "[DEBUG] $message" >&2
      fi
      ;;
    *) echo "$message" >&2 ;;
  esac
}

usage() {
  cat <<USAGE
Usage: $0 [--frontend <auto|squirrel|weasel|hamster|hamster3|none>] [--target <dir>] [--init] [--dry-run] [--no-download] [--delete|--no-delete] [--[no-]redeploy] [--[no-]sync] [--debug]

Flow:
- Download once -> build/upstream/
- Merge upstream + local/frontend overlays -> build/stage/<frontend>/
- rsync(filter) stage -> target

Environment:
  GITHUB_TOKEN     # GitHub API 认证（可选，避免 API 限流）
USAGE
}

require_cmd() {
  local c="$1"
  if ! command -v "$c" >/dev/null 2>&1; then
    log error "Missing dependency: $c"
    exit 1
  fi
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

  # Get bootstrap filter file
  if [ ! -f "$REPO_DIR/cmd/frontends.sh" ]; then
    log error "Missing mapping: cmd/frontends.sh"
    return 1
  fi

  # shellcheck disable=SC1090
  source "$REPO_DIR/cmd/frontends.sh"
  local filter_rel
  filter_rel="$(frontend_bootstrap_filter_file "$resolved")"
  if [ -z "$filter_rel" ] || [ ! -f "$REPO_DIR/$filter_rel" ]; then
    log error "Missing bootstrap filter for frontend '$resolved': $filter_rel"
    return 1
  fi

  mkdir -p "$target"
  rsync -a --ignore-existing \
    --filter="merge $REPO_DIR/$filter_rel" \
    "$tpl_dir" "$target/"

  log info "Initialized templates: $resolved -> $target"
}

resolve_frontend() {
  local p="$1"
  if [ "$p" != "auto" ]; then
    echo "$p"
    return 0
  fi
  if [ -f "$REPO_DIR/cmd/frontends.sh" ]; then
    # shellcheck disable=SC1090
    source "$REPO_DIR/cmd/frontends.sh"
    frontend_resolve_auto
    return 0
  fi
  echo "none"
}

github_releases_json() {
  local repo="$1"
  local out_file="$2"
  local api_url="https://api.github.com/repos/${repo}/releases"

  if [ -n "${GITHUB_TOKEN:-}" ]; then
    if ! curl -sS -H "Authorization: token ${GITHUB_TOKEN}" "$api_url" -o "$out_file"; then
    log error "Failed to fetch GitHub releases: $repo"
    return 1
  fi
  else
    if ! curl -sS "$api_url" -o "$out_file"; then
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

  find "$tmp" -type f -maxdepth 2 -print0 | while IFS= read -r -d '' f; do
    rsync -a "$f" "$dest/"
  done

  rm -rf "$tmp"
}

update_upstream_cache() {
  ensure_dirs
  require_cmd rsync
  require_cmd curl
  require_cmd jq
  require_cmd unzip

  local schema_repo="amzxyz/rime_wanxiang"

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

  # grammar
  local grammar_repo="amzxyz/RIME-LMDG"
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
    rsync -a "$grammar_file" "$UPSTREAM_DIR/$grammar_asset"
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
    rsync -a --exclude='.DS_Store' "$UPSTREAM_DIR/" "$stage/"
  fi

  # local layer (repo tracked)
  if [ -f "$REPO_DIR/custom_phrase_user.txt" ]; then
    rsync -a "$REPO_DIR/custom_phrase_user.txt" "$stage/"
  fi

  shopt -s nullglob
  local f
  for f in "$REPO_DIR"/*.custom.yaml; do
    rsync -a "$f" "$stage/"
  done
  shopt -u nullglob

  # UI overlays (only when enabled)
  if [ -n "$ui_layer" ] && [ "$ui_layer" != "none" ]; then
    if [ -f "$REPO_DIR/cmd/common/default.custom.yaml" ]; then
      rsync -a "$REPO_DIR/cmd/common/default.custom.yaml" "$stage/default.custom.yaml"
    fi

    local tpl_dir="$REPO_DIR/cmd/$ui_layer"
    if [ -d "$tpl_dir" ]; then
      shopt -s nullglob
      local files=("$tpl_dir"/*.custom.yaml)
      shopt -u nullglob
      if [ "${#files[@]}" -gt 0 ]; then
        rsync -a "${files[@]}" "$stage/"
      fi
    fi
  fi

  echo "$stage"
}

rsync_stage_to_target() {
  local frontend="$1"
  local stage="$2"
  local target="$3"

  if [ ! -f "$REPO_DIR/cmd/frontends.sh" ]; then
    log error "Missing mapping: cmd/frontends.sh"
    return 1
  fi

  # shellcheck disable=SC1090
  source "$REPO_DIR/cmd/frontends.sh"

  local filter_rel
  filter_rel="$(frontend_rsync_filter_file "$frontend")"
  if [ -z "$filter_rel" ] || [ ! -f "$REPO_DIR/$filter_rel" ]; then
    log error "Missing rsync filter for frontend '$frontend': $filter_rel"
    return 1
  fi

  mkdir -p "$target"

  local rsync_opts=(-a)
  if [ "$RSYNC_DELETE" -eq 1 ]; then
    rsync_opts+=(--delete)
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    rsync_opts+=(-n -i)
  fi

  log info "Stage -> $frontend : $target"
  rsync "${rsync_opts[@]}" \
    --filter="merge $REPO_DIR/$filter_rel" \
    --exclude='.DS_Store' \
    "$stage/" "$target/"
}

main() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --frontend) shift; FRONTEND="${1:-}" ;;
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
      --help|-h) usage; exit 0 ;;
      *) log error "Unknown option: $1"; usage; exit 1 ;;
    esac
    shift
  done

  local resolved
  resolved="$(resolve_frontend "$FRONTEND")"

  local frontend="$resolved"
  local target="$TARGET_DIR"
  local ui_layer="$frontend"

  if [ -f "$REPO_DIR/cmd/frontends.sh" ]; then
    # shellcheck disable=SC1090
    source "$REPO_DIR/cmd/frontends.sh"
    ui_layer="$(frontend_ui_layer "$frontend")"
    if [ -z "$target" ]; then
      target="$(frontend_target_dir "$frontend")"
    fi
  fi

  if [ -z "$target" ]; then
    log error "Missing target for frontend '$frontend' (use --target or set cmd/frontends.yaml)"
    exit 1
  fi

  ensure_dirs
  require_cmd rsync

  if [ "$NO_DOWNLOAD" -eq 0 ]; then
    update_upstream_cache
  else
    if [ -z "$(ls -A "$UPSTREAM_DIR" 2>/dev/null || true)" ]; then
      log error "--no-download set but build/upstream is empty"
      exit 1
    fi
  fi

  if [ "$RUN_INIT" -eq 1 ]; then
    rsync_bootstrap_templates "$frontend" "$target"
  fi

  local stage
  stage="$(build_stage_dir "$frontend" "$ui_layer")"
  rsync_stage_to_target "$frontend" "$stage" "$target"

  # Post-update hooks (Redeploy / Sync)
  if [ "$DRY_RUN" -eq 0 ] && [ -f "$REPO_DIR/cmd/frontends.sh" ]; then
    local redeploy_cmd
    local sync_cmd
    redeploy_cmd="$(frontend_redeploy_cmd "$frontend")"
    sync_cmd="$(frontend_sync_cmd "$frontend")"

    if [ "$REDEPLOY" -eq 1 ] && [ -n "$redeploy_cmd" ]; then
      log info "Triggering redeploy: $redeploy_cmd"
      sh -c "$redeploy_cmd" || log warn "Redeploy command failed"
    fi

    if [ "$SYNC" -eq 1 ] && [ -n "$sync_cmd" ]; then
      log info "Triggering sync: $sync_cmd"
      sh -c "$sync_cmd" || log warn "Sync command failed"
    fi
  fi
}

main "$@"
