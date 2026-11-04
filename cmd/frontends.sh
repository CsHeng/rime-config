#!/bin/bash
# frontends.sh — cmd/frontends.json 读取薄封装（bash 函数）
#
# 依赖: jq。配置文件路径可用 FRONTENDS_CONFIG 覆盖（默认 <repo>/cmd/frontends.json）。
# redeploy_cmd / sync_cmd 为 {"executable": "...", "args": [...]} 对象；
# frontend_*_cmd 以 NUL 分隔流输出 executable 与各参数（空参数与内嵌换行原样保留），
# 调用方用 `read -rd ''` 直读进程替换输出并以数组直接执行，不拼接 shell 字符串。

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd "$SCRIPT_DIR/.." && pwd)

# Color codes (exported for external use)
export GREEN='\033[0;32m'
export YELLOW='\033[0;33m'
export RED='\033[0;31m'
export NC='\033[0m'

_require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    printf "${RED}ERROR: Missing dependency: jq${NC}\n" >&2
    return 1
  fi
}

_config_file() {
  if [ -n "${FRONTENDS_CONFIG:-}" ]; then
    printf '%s' "$FRONTENDS_CONFIG"
  else
    printf '%s' "$REPO_DIR/cmd/frontends.json"
  fi
}

# 配置内相对路径相对配置文件目录解释；~ 展开为 $HOME。
config_resolve_path() {
  local p="$1"
  # shellcheck disable=SC2088  # pattern '\~/' strips the literal '~/'; expansion is via $HOME
  case "$p" in
    "~") p="$HOME" ;;
    "~/"*) p="$HOME/${p#\~/}" ;;
  esac
  local cfg_dir
  cfg_dir="$(dirname "$(_config_file)")"
  case "$p" in
    /*) printf '%s' "$p" ;;
    *) printf '%s' "$cfg_dir/$p" ;;
  esac
}

# 用法: _jq '<jq 表达式>' [jq 额外参数...]
# 配置缺失 / JSON 解析失败时打印明确错误并返回非零。
_jq() {
  local expr="$1"
  shift
  _require_jq || return 1

  local cfg
  cfg="$(_config_file)"
  if [ ! -f "$cfg" ]; then
    printf "${RED}ERROR: frontends config not found: %s${NC}\n" "$cfg" >&2
    printf "  cp cmd/frontends.json.tmpl cmd/frontends.json 并按需修改\n" >&2
    return 1
  fi

  local out rc=0
  out=$(jq -r "$@" "$expr" "$cfg" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf "${RED}ERROR: invalid JSON in %s:${NC}\n" "$cfg" >&2
    printf '%s\n' "$out" | sed 's/^/  /' >&2
    return 1
  fi
  printf '%s\n' "$out"
}

# 结构校验：active 取值、路径字段类型、命令对象形状。
# 出错时打印具体字段并返回非零，供 update.sh / sync-userdict.sh 在副作用前调用。
frontends_validate() {
  local problems="" bad t

  t=$(_jq '.frontends | type') || return 1
  if [ "$t" != "object" ]; then
    problems="${problems}  frontends: must be an object mapping frontend name -> settings"$'\n'
  else
    local n
    n=$(_jq '.frontends | length') || return 1
    if [ "$n" = "0" ]; then
      problems="${problems}  frontends: must contain at least one frontend"$'\n'
    fi
  fi

  bad=$(_jq '.frontends // {} | to_entries[]
      | select((.value.active != null) and (((.value.active == true) or (.value.active == false) or (.value.active == "auto")) | not))
      | "  frontends.\(.key).active: must be true, false, or \"auto\" (got \(.value.active | tojson))"') || return 1
  if [ -n "$bad" ]; then problems="${problems}${bad}"$'\n'; fi

  bad=$(_jq '.frontends // {} | to_entries[]
      | select((.value.target_dir != null) and ((.value.target_dir | type) != "string"))
      | "  frontends.\(.key).target_dir: must be a string"') || return 1
  if [ -n "$bad" ]; then problems="${problems}${bad}"$'\n'; fi

  bad=$(_jq '.frontends // {} | to_entries[] | .key as $k | .value as $v
      | ($v | keys[] | select(. == "redeploy_cmd" or . == "sync_cmd")) as $c
      | ($v[$c]) as $cmd
      | if ($cmd | type) != "object" then "  frontends.\($k).\($c): must be an object {\"executable\", \"args\"}"
        elif (($cmd.executable // null) | type) != "string" then "  frontends.\($k).\($c).executable: must be a string"
        elif (($cmd.executable // "") | length) == 0 then "  frontends.\($k).\($c).executable: must be a non-empty string"
        elif (($cmd.args // []) | type) != "array" then "  frontends.\($k).\($c).args: must be an array of strings"
        elif (($cmd.args // []) | map(select(type != "string")) | length) > 0 then "  frontends.\($k).\($c).args: must be an array of strings"
        else empty end') || return 1
  if [ -n "$bad" ]; then problems="${problems}${bad}"$'\n'; fi

  t=$(_jq '.auto // {} | type') || return 1
  if [ "$t" != "object" ]; then
    problems="${problems}  auto: must be an object like {\"darwin\": ..., \"windows\": ...}"$'\n'
  else
    bad=$(_jq '.auto // {} | to_entries[]
        | select((.value != null) and ((.value | type) != "string"))
        | "  auto.\(.key): must be a string (frontend name)"') || return 1
    if [ -n "$bad" ]; then problems="${problems}${bad}"$'\n'; fi
  fi

  t=$(_jq '.userdict_sync // {} | type') || return 1
  if [ "$t" != "object" ]; then
    problems="${problems}  userdict_sync: must be an object {\"icloud\", \"onedrive\"}"$'\n'
  else
    bad=$(_jq '.userdict_sync.icloud // null | select(. != null and (type != "string")) | "  userdict_sync.icloud: must be a string"') || return 1
    if [ -n "$bad" ]; then problems="${problems}${bad}"$'\n'; fi
    t=$(_jq '.userdict_sync.onedrive // {} | type') || return 1
    if [ "$t" != "object" ]; then
      problems="${problems}  userdict_sync.onedrive: must be an object {\"darwin\"}"$'\n'
    else
      bad=$(_jq '.userdict_sync.onedrive // {} | to_entries[]
          | select((.value != null) and ((.value | type) != "string"))
          | "  userdict_sync.onedrive.\(.key): must be a string"') || return 1
      if [ -n "$bad" ]; then problems="${problems}${bad}"$'\n'; fi
    fi
  fi

  if [ -n "$problems" ]; then
    printf "${RED}ERROR: invalid frontends config: %s${NC}\n" "$(_config_file)" >&2
    printf '%s' "$problems" >&2
    return 1
  fi
  return 0
}

frontend_resolve_auto() {
  local os
  os=$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo "")
  case "$os" in
    darwin*) _jq '.auto.darwin // "none"' ;;
    msys*|mingw*|cygwin*) _jq '.auto.windows // "none"' ;;
    *) echo "none" ;;
  esac
}

frontend_ui_layer() {
  local frontend="$1"
  _jq '.frontends[$f].ui_layer // "none"' --arg f "$frontend"
}

frontend_rsync_filter_file() {
  local frontend="$1"
  local rel
  rel=$(_jq '.frontends[$f].rsync_filter // ""' --arg f "$frontend") || return 1
  [ -n "$rel" ] && config_resolve_path "$rel" || echo ""
}

frontend_bootstrap_filter_file() {
  local frontend="$1"
  local rel
  rel=$(_jq '.frontends[$f].bootstrap_filter // ""' --arg f "$frontend") || return 1
  [ -n "$rel" ] && config_resolve_path "$rel" || echo ""
}

frontend_target_dir() {
  local frontend="$1"
  local target_path
  target_path=$(_jq '.frontends[$f].target_dir // ""' --arg f "$frontend") || return 1
  [ -z "$target_path" ] && { echo ""; return 0; }

  # 展开 ~ / 解析配置相对路径
  target_path="$(config_resolve_path "$target_path")"

  # Windows (Git Bash): only accept /c/... style paths (avoid rsync's remote syntax and argv path conversion issues)
  local os
  os=$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo "")
  case "$os" in
    msys*|mingw*|cygwin*)
      if [[ "$target_path" == *:* ]] || [[ "$target_path" == *\\* ]]; then
        printf "${RED}ERROR: Windows target_dir must use /c/... style paths (do not use C:\\\\... or C:...)${NC}\n" >&2
        printf "  got: %s\n" "$target_path" >&2
        printf "  example: /c/Users/<User>/AppData/Roaming/Rime\n" >&2
        return 1
      fi
      if [[ ! "$target_path" =~ ^/[a-zA-Z]/ ]]; then
        printf "${RED}ERROR: Windows target_dir must start with /<drive>/ (e.g. /c/...)${NC}\n" >&2
        printf "  got: %s\n" "$target_path" >&2
        printf "  example: /c/Users/<User>/AppData/Roaming/Rime\n" >&2
        return 1
      fi
      ;;
  esac

  echo "$target_path"
}

# 以 NUL 分隔流输出：executable、随后每个参数各占一个 NUL 记录；未配置时输出为空。
# 空字符串参数与内嵌换行完整保留（P1.3 参数边界）；调用方须用 `read -rd ''` 直读
# 进程替换输出，不经命令替换（$() 会剥除 NUL）。
# 命令对象形状由 frontends_validate 保证（要求先于本函数调用）。
# 注：本函数不经 _jq（其命令替换会剥除 NUL）；配置缺失时在 stderr 报错并返回 1。
_frontend_cmd_nul() {
  local frontend="$1" field="$2"
  _require_jq || return 1

  local cfg
  cfg="$(_config_file)"
  if [ ! -f "$cfg" ]; then
    printf "${RED}ERROR: frontends config not found: %s${NC}\n" "$cfg" >&2
    printf "  cp cmd/frontends.json.tmpl cmd/frontends.json 并按需修改\n" >&2
    return 1
  fi

  jq -rj --arg f "$frontend" --arg c "$field" '
    .frontends[$f][$c] // empty |
    if (type == "object") and ((.executable // null | type) == "string")
    then ([.executable] + (.args // [])) | join("\u0000") | . + "\u0000"
    else empty end' "$cfg"
}

frontend_redeploy_cmd() {
  _frontend_cmd_nul "$1" "redeploy_cmd"
}

frontend_sync_cmd() {
  _frontend_cmd_nul "$1" "sync_cmd"
}

frontend_active_list() {
  frontends_validate || return 1

  local true_list auto_list auto_frontend
  true_list=$(_jq '.frontends | to_entries[] | select(.value.active == true) | .key') || return 1
  auto_list=$(_jq '.frontends | to_entries[] | select(.value.active == "auto") | .key') || return 1
  auto_frontend="$(frontend_resolve_auto)" || return 1

  local -a active_frontends=()
  local f
  while IFS= read -r f; do
    [ -n "$f" ] && active_frontends+=("$f")
  done <<< "$true_list"

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
    printf '%s\n' "${active_frontends[@]}" | sort -u
  fi
}

userdict_icloud_path() {
  local raw
  raw=$(_jq '.userdict_sync.icloud // ""') || return 1
  [ -n "$raw" ] && config_resolve_path "$raw" || echo ""
}

userdict_onedrive_path() {
  local raw
  raw=$(_jq '.userdict_sync.onedrive.darwin // ""') || return 1
  [ -n "$raw" ] && config_resolve_path "$raw" || echo ""
}
