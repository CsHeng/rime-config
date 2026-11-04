#!/bin/bash
# cmd/tests/run-tests.sh — bash 侧场景测试
# 在临时沙盒（含空格与中文路径）中运行真实入口脚本，验证：
#   - 配置选择一致性（bash frontends.sh vs pwsh update.ps1）
#   - --sync-only 离线可用（无 yq/上游缓存，不请求网络）
#   --sync-only / --cloud-sync 冲突拒绝与失败可见
#   - 云桥链路：前桥接 -> Rime 同步 -> 后桥接缺口（Squirrel 无完成信号）
#   - sync-userdict.sh dry-run 不启动 Unison；真实 Unison 场景（本地目录对）
#   - --target 覆盖与目标重叠校验；dry-run 不生成用户短语文件
# 运行: bash cmd/tests/run-tests.sh   （依赖: jq, rsync, pwsh, unison[部分场景]）
set -u

# 防止宿主继承的 BASH_ENV 在非交互 bash 启动时重置 PATH/环境，破坏隐藏 PATH 类断言
unset BASH_ENV ENV

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd "$TESTS_DIR/../.." && pwd)
PWSH="${PWSH:-$(command -v pwsh || true)}"
FAKE="$TESTS_DIR/fake-cmd.sh"

PASS=0 FAIL=0
FAILED=()

ok()  { PASS=$((PASS+1)); echo "  ok: $1"; }
nok() { FAIL=$((FAIL+1)); FAILED+=("$1"); echo "  FAIL: $1"; }
assert_rc() { if [ "$1" -eq "$2" ]; then ok "$3"; else nok "$3 (rc=$1, want $2)"; fi; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else nok "$1 (got [$2], want [$3])"; fi; }
assert_contains() { if grep -qF -- "$2" "$1" 2>/dev/null; then ok "$3"; else nok "$3 (missing [$2] in $1)"; fi; }
assert_no_file() { if [ ! -e "$1" ]; then ok "$2"; else nok "$2 ($1 exists)"; fi; }
assert_file() { if [ -f "$1" ]; then ok "$2"; else nok "$2 ($1 missing)"; fi; }
assert_no_line() { if grep -qF -- "$2" "$1" 2>/dev/null; then nok "$3 (unexpected [$2])"; else ok "$3"; fi; }

# 沙盒基路径包含空格与中文（覆盖 P1 的路径证据）
WORK=$(mktemp -d "${TMPDIR:-/tmp}/rime tests 空格.中文.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# 隐藏 yq（及 homebrew 工具）的最小 PATH：bash sync-only 只需要 jq + 系统工具
HIDDEN_BIN="$WORK/hidden-bin"
mkdir -p "$HIDDEN_BIN"
ln -sf "$(command -v jq)" "$HIDDEN_BIN/jq"

make_sandbox() {
  local sb="$WORK/$1"
  mkdir -p "$sb/cmd"
  cp "$REPO_DIR/cmd/update.sh" "$REPO_DIR/cmd/update.ps1" "$REPO_DIR/cmd/frontends.sh" "$REPO_DIR/cmd/sync-userdict.sh" "$sb/cmd/"
  cp -R "$REPO_DIR/cmd/weasel" "$REPO_DIR/cmd/squirrel" "$REPO_DIR/cmd/hamster3" "$REPO_DIR/cmd/hamster" "$REPO_DIR/cmd/common" "$sb/cmd/"
  cp "$REPO_DIR/custom_phrase_user.dict.yaml.example" "$sb/"
  find "$REPO_DIR" -maxdepth 1 -name '*.custom.yaml' -exec cp {} "$sb/" \;
  echo "$sb"
}

seed_upstream() {
  mkdir -p "$1/build/upstream/dicts"
  printf 'upstream-schema-v1\n' > "$1/build/upstream/wanxiang.schema.yaml"
  printf 'upstream-dict-data\n' > "$1/build/upstream/dicts/base.txt"
}

squirrel_cfg() { # $1 config file, $2 target, $3 icloud, $4 onedrive
  cat > "$1" <<EOF
{
  "auto": {"darwin": "squirrel", "windows": "weasel"},
  "frontends": {
    "squirrel": {
      "active": true,
      "target_dir": "$2",
      "ui_layer": "squirrel",
      "rsync_filter": "squirrel/update-rsync.filter",
      "bootstrap_filter": "squirrel/bootstrap-rsync.filter",
      "redeploy_cmd": {"executable": "$FAKE", "args": ["--reload"]},
      "sync_cmd": {"executable": "$FAKE", "args": ["--sync"]}
    }
  },
  "userdict_sync": {"icloud": "$3", "onedrive": {"darwin": "$4"}}
}
EOF
}

# ===========================================================================
echo "== b1: 前端选择一致性（bash frontends.sh vs pwsh update.ps1，同一份 auto/true/false 配置）"
SB1=$(make_sandbox parity-bash)
mkdir -p "$WORK/parity"
cat > "$WORK/parity/frontends.json" <<EOF
{
  "auto": {"darwin": "squirrel", "windows": "weasel"},
  "frontends": {
    "squirrel": {"active": "auto", "target_dir": "$SB1/t-sq"},
    "weasel": {"active": true, "target_dir": "$SB1/t-ws"},
    "hamster": {"active": false, "target_dir": "$SB1/t-ham"},
    "hamster3": {"active": "auto", "target_dir": "$SB1/t-ham3"}
  }
}
EOF
BASH_SEL=$(FRONTENDS_CONFIG="$WORK/parity/frontends.json" bash -c '
  source "$1/cmd/frontends.sh"; frontend_active_list' _ "$SB1" | sort | tr '\n' ' ' | sed 's/ $//')
assert_eq "bash selection" "$BASH_SEL" "squirrel weasel"

if [ -n "$PWSH" ]; then
  PWSH_OUT=$("$PWSH" -NoProfile -File "$SB1/cmd/update.ps1" -Config "$WORK/parity/frontends.json" -DryRun -NoDownload 2>&1 || true)
  PWSH_SEL=$(printf '%s\n' "$PWSH_OUT" | sed -n 's/^Active frontends: //p' | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')
  assert_eq "pwsh selection" "$PWSH_SEL" "squirrel weasel"
  assert_eq "selection parity (bash==pwsh)" "$BASH_SEL" "$PWSH_SEL"
else
  echo "  SKIP: pwsh not found"
fi

# ===========================================================================
echo "== b2: --sync-only 离线运行（无 build/、隐藏 yq、阻断代理、假进程收到原样 /sync）"
SB2=$(make_sandbox sync-only)
T2="$SB2/target 目录"   # 空格+中文目标
squirrel_cfg "$SB2/cmd/frontends.json" "$T2" "$SB2/icloud" "$SB2/onedrive"
rm -rf "$SB2/build"     # 无上游缓存
LOG2="$SB2/fake.log"; rm -f "$LOG2"
OUT2="$SB2/out.txt"
rc=0
( cd "$SB2" && env PATH="$HIDDEN_BIN:/bin:/usr/bin" \
    HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 \
    FAKE_LOG="$LOG2" ./cmd/update.sh --sync-only --debug ) >"$OUT2" 2>&1 || rc=$?
assert_rc "$rc" 0 "sync-only exit 0"
assert_contains "$LOG2" "ARGV[0]:--sync" "fake 收到原样参数 --sync"
assert_no_file "$SB2/build" "未创建 build/（无上游/缓存依赖）"
assert_contains "$OUT2" "Rime 同步" "输出包含同步阶段信息"
assert_contains "$LOG2" "CMD:fake-cmd.sh" "调用了配置中的可执行文件"
assert_no_line "$OUT2" "DEBUG: rsync" "sync-only 不探测 rsync"

# ===========================================================================
echo "== b2b: --sync-only 仅有 iOS 前端（无 sync_cmd）时不得报完成"
SB2B=$(make_sandbox ios-only)
cat > "$SB2B/cmd/frontends.json" <<EOF
{"frontends": {"hamster3": {"active": true, "target_dir": "$SB2B/t"}}}
EOF
OUT2B="$SB2B/out.txt"
rc=0
( cd "$SB2B" && env PATH="$HIDDEN_BIN:/bin:/usr/bin" ./cmd/update.sh --sync-only ) >"$OUT2B" 2>&1 || rc=$?
assert_rc "$rc" 1 "iOS-only sync-only exit 1"
assert_contains "$OUT2B" "sync-only 未完成" "明确报告未完成"

# ===========================================================================
echo "== b3: 选项冲突在副作用前拒绝"
SB3=$(make_sandbox conflicts)
T3="$SB3/target"
squirrel_cfg "$SB3/cmd/frontends.json" "$T3" "$SB3/icloud" "$SB3/onedrive"
for combo in "--sync-only --init" "--sync-only --delete" "--sync-only --no-download" "--sync-only --no-sync" "--cloud-sync --no-sync"; do
  OUT="$SB3/out.txt"; rm -f "$SB3/fake.log"
  rc=0
  ( cd "$SB3" && env PATH="$HIDDEN_BIN:/bin:/usr/bin" FAKE_LOG="$SB3/fake.log" \
      ./cmd/update.sh $combo --target "$SB3/t-x" ) >"$OUT" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then ok "拒绝组合: $combo"; else nok "组合未被拒绝: $combo"; fi
  assert_no_file "$SB3/fake.log" "组合 $combo 未调用任何命令"
done
# 单独 --sync-only --target 也应拒绝
rc=0
( cd "$SB3" && env PATH="$HIDDEN_BIN:/bin:/usr/bin" ./cmd/update.sh --sync-only --target "$SB3/t-x" ) >"$SB3/out.txt" 2>&1 || rc=$?
assert_rc "$rc" 1 "拒绝 --sync-only --target"

# ===========================================================================
echo "== b4: 云桥链路（正常）：前桥接 -> Rime 同步(提交) -> 后桥接缺口，退出 75"
SB4=$(make_sandbox chain-ok)
mkdir -p "$SB4/icloud" "$SB4/onedrive"
squirrel_cfg "$SB4/cmd/frontends.json" "$SB4/target" "$SB4/icloud" "$SB4/onedrive"
rm -rf "$SB4/build"
LOG4="$SB4/fake.log"; rm -f "$LOG4"
OUT4="$SB4/out.txt"
rc=0
( cd "$SB4" && env UNISON="$SB4/.unison" FAKE_LOG="$LOG4" ./cmd/update.sh --sync-only --cloud-sync ) >"$OUT4" 2>&1 || rc=$?
assert_rc "$rc" 75 "链路停在已提交（退出 75）"
assert_contains "$OUT4" "前桥接" "执行了前桥接"
assert_contains "$LOG4" "ARGV[0]:--sync" "前桥接后提交了 Rime 同步"
assert_contains "$OUT4" "后桥接未自动执行" "明确后桥接缺口"
assert_contains "$OUT4" "手动执行后桥接" "给出人工后桥接步骤"
if [ -n "$(ls -A "$SB4/.unison" 2>/dev/null)" ]; then ok "前桥接确实运行了 Unison（有归档）"; else nok "前桥接未运行 Unison"; fi

# ===========================================================================
echo "== b5: 前桥接失败 -> 不继续同步"
SB5=$(make_sandbox chain-pre-fail)
mkdir -p "$SB5/onedrive"   # icloud 目录缺失
squirrel_cfg "$SB5/cmd/frontends.json" "$SB5/target" "$SB5/icloud-missing" "$SB5/onedrive"
rm -rf "$SB5/build"
LOG5="$SB5/fake.log"; rm -f "$LOG5"
rc=0
( cd "$SB5" && env UNISON="$SB5/.unison" FAKE_LOG="$LOG5" ./cmd/update.sh --sync-only --cloud-sync ) >"$SB5/out.txt" 2>&1 || rc=$?
assert_rc "$rc" 1 "前桥接失败退出 1"
assert_no_file "$LOG5" "前桥接失败后未调用 Rime 同步"
assert_contains "$SB5/out.txt" "iCloud directory not found" "失败原因可见"

# ===========================================================================
echo "== b6: Rime 同步失败 -> 整次不成功，报告前端/阶段/退出码"
SB6=$(make_sandbox chain-rime-fail)
mkdir -p "$SB6/icloud" "$SB6/onedrive"
squirrel_cfg "$SB6/cmd/frontends.json" "$SB6/target" "$SB6/icloud" "$SB6/onedrive"
rm -rf "$SB6/build"
rc=0
( cd "$SB6" && env UNISON="$SB6/.unison" FAKE_LOG="$SB6/fake.log" FAKE_FAIL_ARG=--sync FAKE_EXIT=7 \
    ./cmd/update.sh --sync-only --cloud-sync ) >"$SB6/out.txt" 2>&1 || rc=$?
assert_rc "$rc" 1 "Rime 失败退出 1"
assert_contains "$SB6/out.txt" "exit code 7" "报告退出码"
assert_contains "$SB6/out.txt" "squirrel" "报告前端"
assert_contains "$SB6/out.txt" "Rime 同步" "报告失败阶段"
assert_no_line "$SB6/out.txt" "后桥接未自动执行" "失败时不输出链路缺口成功语义"

# ===========================================================================
echo "== b7: 链路 dry-run：不启动 Unison、不调用假进程、只输出步骤"
SB7=$(make_sandbox chain-dry)
mkdir -p "$SB7/icloud" "$SB7/onedrive"
squirrel_cfg "$SB7/cmd/frontends.json" "$SB7/target" "$SB7/icloud" "$SB7/onedrive"
rm -rf "$SB7/build"; rm -f "$SB7/fake.log"
rc=0
( cd "$SB7" && env UNISON="$SB7/.unison" FAKE_LOG="$SB7/fake.log" \
    ./cmd/update.sh --sync-only --cloud-sync --dry-run ) >"$SB7/out.txt" 2>&1 || rc=$?
assert_rc "$rc" 0 "dry-run exit 0"
assert_no_file "$SB7/fake.log" "dry-run 未调用假进程"
assert_no_file "$SB7/.unison" "dry-run 未启动 Unison（无归档）"
assert_contains "$SB7/out.txt" "待执行: unison" "输出桥接步骤"
assert_contains "$SB7/out.txt" "(dry-run) 将调用" "输出将调用的同步命令"

# ===========================================================================
echo "== b8: sync-userdict.sh --dry-run 不做任何修改"
SB8=$(make_sandbox ud-dry)
mkdir -p "$SB8/icloud" "$SB8/onedrive"
squirrel_cfg "$SB8/cmd/frontends.json" "$SB8/tgt" "$SB8/icloud" "$SB8/onedrive"
printf 'icloud-only\n' > "$SB8/icloud/a.txt"
printf 'onedrive-only\n' > "$SB8/onedrive/b.txt"
rc=0
( cd "$SB8" && env UNISON="$SB8/.unison" ./cmd/sync-userdict.sh --dry-run ) >"$SB8/out.txt" 2>&1 || rc=$?
assert_rc "$rc" 0 "dry-run exit 0"
assert_contains "$SB8/out.txt" "待执行: unison" "输出待执行命令"
assert_no_file "$SB8/.unison" "未创建 Unison 归档"
assert_no_file "$SB8/icloud/b.txt" "icloud 侧未被修改"
assert_no_file "$SB8/onedrive/a.txt" "onedrive 侧未被修改"

# ===========================================================================
echo "== b9: sync-userdict.sh 失败可见（目录缺失）"
SB9=$(make_sandbox ud-fail)
mkdir -p "$SB9/icloud"   # onedrive 缺失
squirrel_cfg "$SB9/cmd/frontends.json" "$SB9/tgt" "$SB9/icloud" "$SB9/onedrive-missing"
rc=0
( cd "$SB9" && env UNISON="$SB9/.unison" ./cmd/sync-userdict.sh ) >"$SB9/out.txt" 2>&1 || rc=$?
assert_rc "$rc" 1 "失败退出 1"
assert_contains "$SB9/out.txt" "OneDrive directory not found" "失败原因可见"

# ===========================================================================
echo "== b10: 真实 Unison 场景（独立临时目录对，不连接真实云目录）"
if command -v unison >/dev/null 2>&1; then
  SB10=$(make_sandbox unison)
  A="$SB10/icloud"; B="$SB10/onedrive"
  mkdir -p "$A" "$B"
  squirrel_cfg "$SB10/cmd/frontends.json" "$SB10/tgt" "$A" "$B"
  # shellcheck disable=SC2120  # 保留 "$@" 透传能力，便于扩展 verbose/debug
  UDRUN() { ( cd "$SB10" && env UNISON="$SB10/.unison" ./cmd/sync-userdict.sh "$@" ) >>"$SB10/out.txt" 2>&1; }
  : > "$SB10/out.txt"
  # run1: 双端新增
  printf 'x1\n' > "$A/x1"; printf 'x2\n' > "$B/x2"; UDRUN
  assert_file "$B/x1" "run1: A 新增同步到 B"
  assert_file "$A/x2" "run1: B 新增同步到 A"
  # run2: 双端各自修改不同文件
  printf 'x1-v2\n' > "$A/x1"; printf 'x3\n' > "$B/x3"; UDRUN
  assert_contains "$B/x1" "x1-v2" "run2: A 修改传播到 B"
  assert_contains "$A/x3" "x3" "run2: B 新增传播到 A"
  # run3: 非冲突删除
  rm -f "$A/x2"; UDRUN
  assert_no_file "$B/x2" "run3: 非冲突删除传播"
  # run4: 冲突（同文件双端修改，prefer newer）
  printf 'c-old\n' > "$A/c"; cp "$A/c" "$B/c"; UDRUN
  printf 'c-from-A\n' > "$A/c"; touch -t 202001010000 "$A/c"
  printf 'c-from-B-newer\n' > "$B/c"
  UDRUN
  assert_contains "$A/c" "c-from-B-newer" "run4: 冲突时 prefer newer（B 较新胜出）"
  assert_contains "$B/c" "c-from-B-newer" "run4: 冲突双方收敛到较新版本"
else
  echo "  UNVERIFIED: unison 不在 PATH，跳过 b10（记录为未验证项）"
fi

# ===========================================================================
echo "== b11: .env 只从配置目录加载"
SB11=$(make_sandbox env-cfg)
SB11B="$WORK/env-fixture"; mkdir -p "$SB11B"
printf 'RIME_TEST_ENV_MARK=FROM_SCRIPT_DIR_ENV\n' > "$SB11/cmd/.env"
squirrel_cfg "$SB11B/frontends.json" "$SB11/target" "$SB11/icloud" "$SB11/onedrive"
rm -rf "$SB11/build"; rm -f "$SB11/fake.log"
rc=0
( cd "$SB11" && env PATH="$HIDDEN_BIN:/bin:/usr/bin" FAKE_LOG="$SB11/fake.log" \
    ./cmd/update.sh --config "$SB11B/frontends.json" --sync-only ) >"$SB11/out.txt" 2>&1 || rc=$?
assert_rc "$rc" 0 "使用外部配置 sync-only 成功"
assert_contains "$SB11/fake.log" "ENV_MARK:<unset>" "未加载脚本目录的 .env"
printf 'RIME_TEST_ENV_MARK=FROM_CONFIG_DIR_ENV\n' > "$SB11B/.env"
rm -f "$SB11/fake.log"
rc=0
( cd "$SB11" && env PATH="$HIDDEN_BIN:/bin:/usr/bin" FAKE_LOG="$SB11/fake.log" \
    ./cmd/update.sh --config "$SB11B/frontends.json" --sync-only ) >"$SB11/out.txt" 2>&1 || rc=$?
assert_rc "$rc" 0 "第二次运行成功"
assert_contains "$SB11/fake.log" "ENV_MARK:FROM_CONFIG_DIR_ENV" "加载了配置目录的 .env"

# ===========================================================================
echo "== b12: 配置错误有明确结果（缺文件/坏 JSON/坏字段/中文空格路径）"
SB12=$(make_sandbox cfg-err)
mkdir -p "$SB12/cmd"
rc=0
( cd "$SB12" && env PATH="$HIDDEN_BIN:/bin:/usr/bin" ./cmd/update.sh --sync-only ) >"$SB12/o1" 2>&1 || rc=$?
assert_rc "$rc" 1 "缺配置退出 1"
assert_contains "$SB12/o1" "frontends config not found" "缺配置提示明确"
SB12B="$WORK/cfg-err-b"; mkdir -p "$SB12B"
printf '{"frontends": {' > "$SB12B/frontends.json"
rc=0
( cd "$SB12" && env PATH="$HIDDEN_BIN:/bin:/usr/bin" ./cmd/update.sh --config "$SB12B/frontends.json" --sync-only ) >"$SB12/o2" 2>&1 || rc=$?
assert_rc "$rc" 1 "坏 JSON 退出 1"
assert_contains "$SB12/o2" "invalid JSON" "坏 JSON 提示明确"
printf '{"frontends": {"s": {"active": "sometimes", "target_dir": "/x"}}}' > "$SB12B/frontends.json"
rc=0
( cd "$SB12" && env PATH="$HIDDEN_BIN:/bin:/usr/bin" ./cmd/update.sh --config "$SB12B/frontends.json" --sync-only ) >"$SB12/o3" 2>&1 || rc=$?
assert_rc "$rc" 1 "坏 active 退出 1"
assert_contains "$SB12/o3" 'must be true, false, or "auto"' "坏 active 提示明确"
printf '{"frontends": {"s": {"active": true, "target_dir": "/x", "sync_cmd": "not-an-object"}}}' > "$SB12B/frontends.json"
rc=0
( cd "$SB12" && env PATH="$HIDDEN_BIN:/bin:/usr/bin" ./cmd/update.sh --config "$SB12B/frontends.json" --sync-only ) >"$SB12/o4" 2>&1 || rc=$?
assert_rc "$rc" 1 "坏 sync_cmd 退出 1"
assert_contains "$SB12/o4" 'must be an object' "坏 sync_cmd 提示明确"

# ===========================================================================
echo "== b13: 目标校验（覆盖仅单前端 / 覆盖需关 hook / 重叠 / 重复目标）"
SB13=$(make_sandbox tgt)
seed_upstream "$SB13"
squirrel_cfg "$SB13/cmd/frontends.json" "$SB13/tgt-default" "$SB13/icloud" "$SB13/onedrive"
# 多前端 + --target
cat > "$SB13/cmd/frontends.json" <<EOF
{
  "frontends": {
    "squirrel": {"active": true, "target_dir": "$SB13/t1", "rsync_filter": "squirrel/update-rsync.filter"},
    "weasel": {"active": true, "target_dir": "$SB13/t2", "rsync_filter": "weasel/update-rsync.filter"}
  }
}
EOF
rc=0
( cd "$SB13" && ./cmd/update.sh --no-download --target "$SB13/t-override" ) >"$SB13/o1" 2>&1 || rc=$?
assert_rc "$rc" 1 "多前端 + --target 拒绝"
assert_contains "$SB13/o1" "只允许单一" "拒绝原因明确"
assert_no_file "$SB13/t-override" "未创建覆盖目标"
# 单前端 + --target 非 dry-run 且未关 hook
squirrel_cfg "$SB13/cmd/frontends.json" "$SB13/tgt-default" "$SB13/icloud" "$SB13/onedrive"
rc=0
( cd "$SB13" && ./cmd/update.sh --no-download --target "$SB13/t-override2" ) >"$SB13/o2" 2>&1 || rc=$?
assert_rc "$rc" 1 "非 dry-run 覆盖目标未关 hook 拒绝"
assert_contains "$SB13/o2" "--no-redeploy --no-sync" "拒绝原因明确"
assert_no_file "$SB13/t-override2" "未创建覆盖目标"
# 单前端 + --target + 关 hook + dry-run? 直接真实运行验证可用
rm -f "$SB13/fake.log"
rc=0
( cd "$SB13" && env FAKE_LOG="$SB13/fake.log" ./cmd/update.sh --no-download --target "$SB13/t-override3" --no-redeploy --no-sync ) >"$SB13/o3" 2>&1 || rc=$?
assert_rc "$rc" 0 "单前端 + 覆盖目标 + 关 hook 成功"
assert_no_file "$SB13/fake.log" "覆盖目标时不调用 redeploy/sync"
assert_file "$SB13/t-override3/wanxiang.schema.yaml" "覆盖目标被写入"
# 目标与 stage 重叠
rc=0
( cd "$SB13" && ./cmd/update.sh --no-download --target "$SB13/build/stage/squirrel" --no-redeploy --no-sync --dry-run ) >"$SB13/o4" 2>&1 || rc=$?
assert_rc "$rc" 1 "stage 与目标重叠拒绝"
assert_contains "$SB13/o4" "重叠" "重叠原因明确"
# 多前端同目标
cat > "$SB13/cmd/frontends.json" <<EOF
{
  "frontends": {
    "squirrel": {"active": true, "target_dir": "$SB13/same-target", "rsync_filter": "squirrel/update-rsync.filter"},
    "weasel": {"active": true, "target_dir": "$SB13/same-target", "rsync_filter": "weasel/update-rsync.filter"}
  }
}
EOF
rc=0
( cd "$SB13" && ./cmd/update.sh --no-download ) >"$SB13/o5" 2>&1 || rc=$?
assert_rc "$rc" 1 "多前端同目标拒绝"
assert_contains "$SB13/o5" "同一目标" "重复目标原因明确"
assert_no_file "$SB13/same-target" "未创建重复目标"

# ===========================================================================
echo "== b14: 短语库 dry-run 只进 stage；真实执行才生成用户副本"
SB14=$(make_sandbox phrase)
seed_upstream "$SB14"
squirrel_cfg "$SB14/cmd/frontends.json" "$SB14/tgt" "$SB14/icloud" "$SB14/onedrive"
assert_no_file "$SB14/custom_phrase_user.dict.yaml" "初始无用户短语文件"
rc=0
( cd "$SB14" && ./cmd/update.sh --no-download --dry-run ) >"$SB14/o1" 2>&1 || rc=$?
assert_rc "$rc" 0 "dry-run exit 0"
assert_no_file "$SB14/custom_phrase_user.dict.yaml" "dry-run 未生成用户短语文件"
assert_file "$SB14/build/stage/squirrel/custom_phrase_user.dict.yaml" "dry-run stage 使用示例"
assert_no_file "$SB14/tgt" "dry-run 未创建目标"
rc=0
( cd "$SB14" && ./cmd/update.sh --no-download --no-redeploy --no-sync ) >"$SB14/o2" 2>&1 || rc=$?
assert_rc "$rc" 0 "真实执行 exit 0"
assert_file "$SB14/custom_phrase_user.dict.yaml" "真实执行生成用户短语文件"
assert_file "$SB14/tgt/custom_phrase_user.dict.yaml" "目标收到短语文件"

# ===========================================================================
echo "== b15: 更新流程 hook 失败可见（redeploy 失败 -> 非零 + 汇总）"
SB15=$(make_sandbox hookfail)
seed_upstream "$SB15"
squirrel_cfg "$SB15/cmd/frontends.json" "$SB15/tgt" "$SB15/icloud" "$SB15/onedrive"
rc=0
( cd "$SB15" && env FAKE_LOG="$SB15/fake.log" FAKE_FAIL_ARG=--reload FAKE_EXIT=5 \
    ./cmd/update.sh --no-download ) >"$SB15/out.txt" 2>&1 || rc=$?
assert_rc "$rc" 1 "redeploy 失败 -> 退出 1"
assert_contains "$SB15/out.txt" "exit code 5" "报告退出码"
assert_contains "$SB15/out.txt" "失败的阶段" "输出失败汇总"
assert_contains "$SB15/out.txt" "redeploy" "报告失败阶段"

# ===========================================================================
echo "== b16: 目标校验在任何 build 目录创建/下载之前（拒绝后零侧副作用）"
SB16=$(make_sandbox tgt-early)
seed_upstream "$SB16"
squirrel_cfg "$SB16/cmd/frontends.json" "$SB16/tgt" "$SB16/icloud" "$SB16/onedrive"
rc=0
( cd "$SB16" && ./cmd/update.sh --no-download --target "$SB16/build/stage/squirrel" --no-redeploy --no-sync ) >"$SB16/out.txt" 2>&1 || rc=$?
assert_rc "$rc" 1 "重叠目标拒绝（exit 1）"
assert_no_file "$SB16/build/stage/squirrel" "目标未被创建"
assert_no_file "$SB16/build/stage" "build/stage 未被创建（校验先于 ensure_dirs）"
assert_no_file "$SB16/tgt" "配置目标未被创建"
# 与 upstream 重叠同样在校验阶段拒绝（upstream 不会被下载逻辑重建）
rc=0
( cd "$SB16" && ./cmd/update.sh --no-download --target "$SB16/build/upstream" --no-redeploy --no-sync --dry-run ) >"$SB16/out2.txt" 2>&1 || rc=$?
assert_rc "$rc" 1 "upstream 重叠目标拒绝"
assert_contains "$SB16/build/upstream/wanxiang.schema.yaml" "upstream-schema-v1" "upstream 内容不变"

# ===========================================================================
echo "== b17: 启用的 hook 可执行文件在任何写入前预检（关闭的 hook 不要求存在）"
SB17=$(make_sandbox hookpreflight)
seed_upstream "$SB17"
cat > "$SB17/cmd/frontends.json" <<EOF
{"frontends": {"squirrel": {"active": true, "target_dir": "$SB17/tgt", "ui_layer": "squirrel",
"rsync_filter": "squirrel/update-rsync.filter",
"redeploy_cmd": {"executable": "/does-not-exist/rime-deploy", "args": ["--reload"]},
"sync_cmd": {"executable": "$FAKE", "args": ["--sync"]}}}}
EOF
rc=0
( cd "$SB17" && ./cmd/update.sh --no-download ) >"$SB17/o1" 2>&1 || rc=$?
assert_rc "$rc" 1 "redeploy 可执行文件缺失 -> 退出 1"
assert_contains "$SB17/o1" "/does-not-exist/rime-deploy" "错误命名缺失的可执行文件"
assert_no_file "$SB17/tgt" "预检失败时目标未被写入"
assert_no_file "$SB17/build/stage" "预检失败时 stage 未被创建"
# 关闭对应 hook 后不要求存在，正常完成
rc=0
( cd "$SB17" && env FAKE_LOG="$SB17/fake.log" ./cmd/update.sh --no-download --no-redeploy ) >"$SB17/o2" 2>&1 || rc=$?
assert_rc "$rc" 0 "关闭 redeploy 后成功"
assert_contains "$SB17/fake.log" "ARGV[0]:--sync" "启用中的 sync hook 正常执行"

# ===========================================================================
echo "== b18: 后桥接提示可直接复制执行且使用同一配置（外部 --config）"
SB18=$(make_sandbox postbridge-hint)
EXT18="$WORK/ext-cfg-18"; mkdir -p "$EXT18/icloud" "$EXT18/onedrive"
cat > "$EXT18/frontends.json" <<EOF
{"frontends": {"squirrel": {"active": true, "target_dir": "$SB18/tgt",
  "sync_cmd": {"executable": "$FAKE", "args": ["--sync"]}}},
 "userdict_sync": {"icloud": "$EXT18/icloud", "onedrive": {"darwin": "$EXT18/onedrive"}}}
EOF
# 默认配置指向另一对目录，用于验证提示不会误用它
DEF18="$SB18/cmd/frontends.json"
cat > "$DEF18" <<EOF
{"frontends": {"squirrel": {"active": true, "target_dir": "$SB18/tgt",
  "sync_cmd": {"executable": "$FAKE", "args": ["--sync"]}}},
 "userdict_sync": {"icloud": "$SB18/other-icloud", "onedrive": {"darwin": "$SB18/other-onedrive"}}}
EOF
rc=0
( cd "$SB18" && env UNISON="$SB18/.unison" FAKE_LOG="$SB18/fake.log" \
    ./cmd/update.sh --config "$EXT18/frontends.json" --sync-only --cloud-sync ) >"$SB18/out.txt" 2>&1 || rc=$?
assert_rc "$rc" 75 "链路停在已提交（75）"
HINT=$(sed -n 's/.*手动执行后桥接（可直接复制）：//p' "$SB18/out.txt" | head -n 1 | sed $'s/\x1b\[[0-9;]*m//g')
[ -n "$HINT" ] && ok "提示中包含后桥接命令" || nok "提示中包含后桥接命令 (got: [$HINT])"
printf 'sentinel-from-external-icloud\n' > "$EXT18/icloud/post-bridge-marker.txt"
# 在干净 env（无 FRONTENDS_CONFIG）+ 不同 cwd 下执行提示命令，验证它使用外部配置的目录对
rc=0
( cd "$WORK" && env -u FRONTENDS_CONFIG UNISON="$SB18/.unison" bash -c "$HINT" ) >"$SB18/post.txt" 2>&1 || rc=$?
assert_rc "$rc" 0 "提示命令可直接执行（exit 0）"
assert_file "$EXT18/onedrive/post-bridge-marker.txt" "提示命令后桥接了外部配置的目录对"
assert_no_file "$SB18/other-onedrive/post-bridge-marker.txt" "未误用默认配置目录对"

# ===========================================================================
echo "== b19: 参数边界（空参数与内嵌换行原样传递）"
SB19=$(make_sandbox arg-boundary)
cat > "$SB19/cmd/frontends.json" <<EOF
{"frontends": {"squirrel": {"active": true, "target_dir": "$SB19/tgt",
  "sync_cmd": {"executable": "$FAKE", "args": ["--sync", "", "b\nc"]}}}}
EOF
rc=0
( cd "$SB19" && env FAKE_LOG="$SB19/fake.log" ./cmd/update.sh --sync-only ) >"$SB19/out.txt" 2>&1 || rc=$?
assert_rc "$rc" 0 "sync-only exit 0"
assert_contains "$SB19/fake.log" "ARGC:3" "参数数目保留（3 个）"
if grep -qx 'ARGV\[1\]:' "$SB19/fake.log"; then ok "空参数保留为空串"; else nok "空参数保留为空串"; fi
if grep -qx 'ARGV\[2\]:b' "$SB19/fake.log" && grep -qx 'c' "$SB19/fake.log"; then ok "内嵌换行参数原样传递"; else nok "内嵌换行参数原样传递"; fi

# ===========================================================================
echo "== b20: 多前端 debug 只报告一次 rsync 环境，保留各次调用参数"
SB20=$(make_sandbox rsync-debug)
seed_upstream "$SB20"
cat > "$SB20/cmd/frontends.json" <<EOF
{"frontends": {
  "hamster3": {"active": true, "target_dir": "$SB20/t-hamster3", "ui_layer": "hamster3",
    "rsync_filter": "hamster3/update-rsync.filter", "bootstrap_filter": "hamster3/bootstrap-rsync.filter"},
  "squirrel": {"active": true, "target_dir": "$SB20/t-squirrel", "ui_layer": "squirrel",
    "rsync_filter": "squirrel/update-rsync.filter", "bootstrap_filter": "squirrel/bootstrap-rsync.filter"}
}}
EOF
for mode in dry-run update; do
  opts=()
  [ "$mode" = dry-run ] && opts+=(--dry-run)
  rc=0
  ( cd "$SB20" && ./cmd/update.sh --no-download --no-redeploy --no-sync --init --debug \
      ${opts[@]+"${opts[@]}"} ) >"$SB20/$mode.txt" 2>&1 || rc=$?
  assert_rc "$rc" 0 "$mode: 多前端更新成功"
  for prefix in 'DEBUG: rsync:' 'DEBUG: rsync runtime:' 'DEBUG: rsync  version'; do
    assert_eq "$mode: $prefix 只输出一次" "$(grep -cF "$prefix" "$SB20/$mode.txt")" 1
  done
  assert_contains "$SB20/$mode.txt" 'DEBUG: rsync args:' "$mode: 保留实际调用参数"
  for frontend in hamster3 squirrel; do
    assert_contains "$SB20/$mode.txt" "=== Completed: $frontend ===" "$mode: $frontend 完成"
    if [ "$mode" = dry-run ]; then
      assert_no_file "$SB20/t-$frontend" "$mode: 未创建 $frontend 目标"
    else
      assert_file "$SB20/t-$frontend/wanxiang.schema.yaml" "$mode: $frontend 收到上游文件"
    fi
  done
done

# ===========================================================================
echo
echo "=========================================="
echo "PASS: $PASS  FAIL: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf 'failed: %s\n' "${FAILED[@]}"
  exit 1
fi
echo "ALL BASH SCENARIOS PASSED"
