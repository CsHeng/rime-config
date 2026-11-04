#Requires -Version 7.0
<#
.SYNOPSIS
  cmd/tests/run-tests.ps1 — PowerShell 侧场景测试
.DESCRIPTION
  在临时沙盒（含空格与中文路径）中运行真实 cmd/update.ps1 入口，验证：
    - -SyncOnly 在空 PATH（无 yq/bash/rsync/curl/jq/unzip）与阻断代理下可用
    - -SyncOnly / -CloudSync / 更新专用选项冲突在副作用前拒绝
    - 过滤引擎：目录感知遍历、受保护内容（userdb/installation/build/lua/tips/custom）不变
    - 显式删除只影响允许项；初始化只补缺失；dry-run 无目标副作用
    - --target 校验与短语示例只进 stage
    - 与 Bash+rsync 同场景结果交叉核对
  运行: pwsh -NoProfile -File cmd/tests/run-tests.ps1
  注意: 本机结果不构成 Windows 原生行为证据（见 cmd/tests/README.md）。
#>

$ErrorActionPreference = 'Stop'

# 防止宿主继承的 BASH_ENV 在非交互 bash 子进程中重置 PATH/环境（p14 交叉核对）
if ($env:BASH_ENV) { $env:BASH_ENV = $null }

$TestsDir = (Resolve-Path (Join-Path $PSScriptRoot '.')).Path
$RepoDir  = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$PwshExe  = (Get-Command pwsh).Source
$Fake     = Join-Path $TestsDir 'fake-cmd.sh'

$script:Pass = 0
$script:Fail = 0
$script:FailedNames = [System.Collections.Generic.List[string]]::new()

function Ok([string]$name)  { $script:Pass++; Write-Host "  ok: $name" }
function No([string]$name)  { $script:Fail++; $script:FailedNames.Add($name); Write-Host "  FAIL: $name" }
function AssertRc([int]$got, [int]$want, [string]$name) { if ($got -eq $want) { Ok $name } else { No "$name (rc=$got, want $want)" } }
function AssertTrue([bool]$cond, [string]$name) { if ($cond) { Ok $name } else { No $name } }
function AssertEq([string]$got, [string]$want, [string]$name) { if ($got -eq $want) { Ok $name } else { No "$name (got [$got], want [$want])" } }
function AssertContains([string]$haystack, [string]$needle, [string]$name) { if ($haystack.Contains($needle)) { Ok $name } else { No "$name (missing [$needle])" } }
function AssertFileContent([string]$path, [string]$want, [string]$name) {
    if ((Test-Path -LiteralPath $path) -and ((Get-Content -LiteralPath $path -Raw) -eq $want)) { Ok $name } else { No "$name ($path)" }
}
function AssertAbsent([string]$path, [string]$name) { if (-not (Test-Path -LiteralPath $path)) { Ok $name } else { No "$name ($path exists)" } }
function AssertPresent([string]$path, [string]$name) { if (Test-Path -LiteralPath $path) { Ok $name } else { No "$name ($path missing)" } }

# 沙盒基路径包含空格与中文（覆盖 P1 的路径证据）
$Work = Join-Path ([IO.Path]::GetTempPath()) ("rime pw tests 空格.中文." + [IO.Path]::GetRandomFileName().Replace('.',''))
New-Item -ItemType Directory -Path $Work -Force | Out-Null
$TmpKeep = $env:TMP; $TempKeep = $env:TEMP

function New-Sandbox([string]$name) {
    $sb = Join-Path $Work $name
    New-Item -ItemType Directory -Path (Join-Path $sb 'cmd') -Force | Out-Null
    Copy-Item "$RepoDir/cmd/update.sh","$RepoDir/cmd/update.ps1","$RepoDir/cmd/frontends.sh","$RepoDir/cmd/sync-userdict.sh" -Destination "$sb/cmd/"
    foreach ($d in @('weasel','squirrel','hamster3','hamster','common')) {
        Copy-Item -Recurse -Force "$RepoDir/cmd/$d" "$sb/cmd/"
    }
    Copy-Item "$RepoDir/custom_phrase_user.dict.yaml.example" $sb
    Copy-Item "$RepoDir/*.custom.yaml" $sb -ErrorAction SilentlyContinue
    return $sb
}

function Seed-Upstream([string]$sb) {
    New-Item -ItemType Directory -Path "$sb/build/upstream/dicts" -Force | Out-Null
    Set-Content -NoNewline -Path "$sb/build/upstream/wanxiang.schema.yaml" -Value "upstream-schema-v1`n"
    Set-Content -NoNewline -Path "$sb/build/upstream/dicts/base.txt" -Value "upstream-dict-data`n"
}

function Write-WeaselConfig([string]$path, [string]$target) {
    $json = @"
{
  "auto": {"darwin": "squirrel", "windows": "weasel"},
  "frontends": {
    "weasel": {
      "active": true,
      "target_dir": "$target",
      "ui_layer": "weasel",
      "rsync_filter": "weasel/update-rsync.filter",
      "bootstrap_filter": "weasel/bootstrap-rsync.filter",
      "redeploy_cmd": {"executable": "$Fake", "args": ["/deploy"]},
      "sync_cmd": {"executable": "$Fake", "args": ["/sync"]}
    }
  }
}
"@
    Set-Content -NoNewline -Path $path -Value $json
}

function Write-SquirrelConfig([string]$path, [string]$target) {
    $json = @"
{
  "auto": {"darwin": "squirrel", "windows": "weasel"},
  "frontends": {
    "squirrel": {
      "active": true,
      "target_dir": "$target",
      "ui_layer": "squirrel",
      "rsync_filter": "squirrel/update-rsync.filter",
      "bootstrap_filter": "squirrel/bootstrap-rsync.filter",
      "redeploy_cmd": {"executable": "$Fake", "args": ["--reload"]},
      "sync_cmd": {"executable": "$Fake", "args": ["--sync"]}
    }
  }
}
"@
    Set-Content -NoNewline -Path $path -Value $json
}

function Invoke-Entry {
    <# 运行沙盒中的 update.ps1；返回 @{ Output; ExitCode }。Env 覆盖后恢复。 #>
    param(
        [Parameter(Mandatory)][string]$Sandbox,
        [string[]]$Arguments = @(),
        [hashtable]$EnvVars = @{}
    )
    $saved = @{}
    foreach ($k in $EnvVars.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $EnvVars[$k], 'Process') }
    try {
        $out = & $PwshExe -NoProfile -File (Join-Path $Sandbox 'cmd/update.ps1') @Arguments 2>&1 | Out-String
        $code = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { 0 }
    } finally {
        foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k], 'Process') }
    }
    return @{ Output = $out; ExitCode = $code }
}

# ===========================================================================
Write-Host "== p1: 前端选择（同一份 auto/true/false 配置）"
$SB1 = New-Sandbox 'selection'
$cfg1 = Join-Path $Work 'parity-frontends.json'
@"
{
  "auto": {"darwin": "squirrel", "windows": "weasel"},
  "frontends": {
    "squirrel": {"active": "auto", "target_dir": "$SB1/t-sq"},
    "weasel": {"active": true, "target_dir": "$SB1/t-ws"},
    "hamster": {"active": false, "target_dir": "$SB1/t-ham"},
    "hamster3": {"active": "auto", "target_dir": "$SB1/t-ham3"}
  }
}
"@ | Set-Content -NoNewline -Path $cfg1
$r1 = Invoke-Entry $SB1 @('-Config', $cfg1, '-DryRun', '-NoDownload')
$selLine = ($r1.Output -split "`n" | Where-Object { $_ -match '^Active frontends: ' } | Select-Object -First 1)
if ($null -ne $selLine) {
    $sel = (($selLine -replace '^Active frontends: ', '').Trim() -split '\s+' | Where-Object { $_ } | Sort-Object) -join ' '
    AssertEq $sel 'squirrel weasel' 'pwsh selection (auto+true, 非 darwin auto 不选 hamster3)'
} else {
    No 'pwsh selection (未输出 Active frontends 行)'
    Write-Host $r1.Output
}

# ===========================================================================
Write-Host "== p2: -SyncOnly 空 PATH（隐藏 yq/bash/rsync/curl/jq/unzip）+ 阻断代理 + 无 build/"
$SB2 = New-Sandbox 'sync-only'
$emptyBin = Join-Path $Work 'empty-bin'
New-Item -ItemType Directory -Path $emptyBin -Force | Out-Null
$t2 = Join-Path $SB2 'target 目录 中文'
Write-WeaselConfig (Join-Path $SB2 'cmd/frontends.json') $t2
$log2 = Join-Path $SB2 'fake.log'
Remove-Item -LiteralPath $log2 -ErrorAction SilentlyContinue
$r2 = Invoke-Entry $SB2 @('-SyncOnly') @{
    PATH        = $emptyBin
    HTTPS_PROXY = 'http://127.0.0.1:9'
    HTTP_PROXY  = 'http://127.0.0.1:9'
    FAKE_LOG    = $log2
    TMP         = $Work; TEMP = $Work
}
AssertRc $r2.ExitCode 0 '-SyncOnly exit 0（空 PATH）'
AssertTrue ((Test-Path -LiteralPath $log2) -and ((Get-Content -LiteralPath $log2 -Raw).Contains('ARGV[0]:/sync'))) 'fake 收到原样参数 /sync'
AssertAbsent (Join-Path $SB2 'build') '未创建 build/（不依赖上游/缓存）'
AssertContains $r2.Output 'Rime 同步' '输出包含同步阶段信息'

# ===========================================================================
Write-Host "== p3: -SyncOnly 仅有 iOS 前端（无 sync_cmd）不得报完成"
$SB3 = New-Sandbox 'ios-only'
@"
{"frontends": {"hamster3": {"active": true, "target_dir": "$SB3/t"}}}
"@ | Set-Content -NoNewline -Path (Join-Path $SB3 'cmd/frontends.json')
$r3 = Invoke-Entry $SB3 @('-SyncOnly')
AssertRc $r3.ExitCode 1 'iOS-only -SyncOnly exit 1'
AssertContains $r3.Output 'sync-only 未完成' '明确报告未完成'

# ===========================================================================
Write-Host "== p4: -SyncOnly -DryRun 只输出计划，不调用命令"
$SB4 = New-Sandbox 'sync-dry'
$t4 = Join-Path $SB4 't'
Write-WeaselConfig (Join-Path $SB4 'cmd/frontends.json') $t4
$log4 = Join-Path $SB4 'fake.log'
Remove-Item -LiteralPath $log4 -ErrorAction SilentlyContinue
$r4 = Invoke-Entry $SB4 @('-SyncOnly', '-DryRun') @{ FAKE_LOG = $log4 }
AssertRc $r4.ExitCode 0 'dry-run exit 0'
AssertAbsent $log4 '未调用假进程'
AssertContains $r4.Output '(dry-run) 将调用' '输出将调用的命令'
AssertContains $r4.Output '/sync' '命令参数可见'

# ===========================================================================
Write-Host "== p5/p6: 选项冲突与 -CloudSync 在副作用前拒绝"
$SB5 = New-Sandbox 'conflicts'
$t5 = Join-Path $SB5 't'
Write-WeaselConfig (Join-Path $SB5 'cmd/frontends.json') $t5
$log5 = Join-Path $SB5 'fake.log'
foreach ($combo in @(
    @('-SyncOnly','-Init'),
    @('-SyncOnly','-Delete'),
    @('-SyncOnly','-NoDownload'),
    @('-SyncOnly','-NoSync'),
    @('-SyncOnly','-Target', (Join-Path $SB5 'tx')),
    @('-CloudSync'),
    @('-CloudSync','-SyncOnly')
)) {
    Remove-Item -LiteralPath $log5 -ErrorAction SilentlyContinue
    $r = Invoke-Entry $SB5 $combo @{ FAKE_LOG = $log5 }
    AssertTrue ($r.ExitCode -ne 0) ("拒绝组合: " + ($combo -join ' '))
    AssertAbsent $log5 ("组合未调用命令: " + ($combo -join ' '))
}

# ===========================================================================
Write-Host "== p7: 过滤引擎复制保护（目录感知；userdb/installation/build/lua/custom 不动）"
$SB7 = New-Sandbox 'copy'
Seed-Upstream $SB7
Set-Content -NoNewline -Path "$SB7/cmd/weasel/weasel.custom.yaml" -Value "NEW-PATCH`n"
$t7 = Join-Path $SB7 'tgt'
Write-WeaselConfig (Join-Path $SB7 'cmd/frontends.json') $t7
# 预置目标受保护内容
@{
    'user.yaml'            = "user-state`n"
    'installation.yaml'    = "installation-state`n"
    'foo.userdb/a/b/deep.txt' = "deep-db`n"
    'build/compiled.bin'   = "bin`n"
    'lua/tips/tip.txt'     = "tip`n"
    'custom/doc.md'        = "doc`n"
    'weasel.custom.yaml'   = "OLD-PATCH`n"
    'extra.txt'            = "extra`n"
}.GetEnumerator() | ForEach-Object {
    $p = Join-Path $t7 $_.Key
    New-Item -ItemType Directory -Path (Split-Path -Parent $p) -Force | Out-Null
    Set-Content -NoNewline -Path $p -Value $_.Value
}
$log7 = Join-Path $SB7 'fake.log'; Remove-Item -LiteralPath $log7 -ErrorAction SilentlyContinue
$r7 = Invoke-Entry $SB7 @('-NoDownload') @{ FAKE_LOG = $log7 }
AssertRc $r7.ExitCode 0 '更新 exit 0'
AssertFileContent (Join-Path $t7 'weasel.custom.yaml') "NEW-PATCH`n" '过期 patch 被更新'
AssertFileContent (Join-Path $t7 'wanxiang.schema.yaml') "upstream-schema-v1`n" '上游文件被复制'
AssertFileContent (Join-Path $t7 'user.yaml') "user-state`n" 'user.yaml 内容不变'
AssertFileContent (Join-Path $t7 'installation.yaml') "installation-state`n" 'installation.yaml 内容不变'
AssertFileContent (Join-Path $t7 'foo.userdb/a/b/deep.txt') "deep-db`n" '嵌套 userdb 深层文件不变'
AssertFileContent (Join-Path $t7 'build/compiled.bin') "bin`n" 'build/ 不变'
AssertFileContent (Join-Path $t7 'lua/tips/tip.txt') "tip`n" 'lua/tips/ 不变'
AssertFileContent (Join-Path $t7 'custom/doc.md') "doc`n" 'custom/ 不被复制也不被删除'
AssertPresent (Join-Path $t7 'extra.txt') '源缺失的目标文件默认保留'
AssertPresent (Join-Path $t7 'default.custom.yaml') 'common 层 patch 到达目标'
AssertTrue ((Test-Path -LiteralPath $log7) -and ((Get-Content -LiteralPath $log7 -Raw).Contains('ARGV[0]:/deploy'))) 'redeploy hook 被调用'

# ===========================================================================
Write-Host "== p8: 显式 -Delete 只影响允许项"
$SB8 = $SB7   # 复用 p7 的目标状态
New-Item -ItemType Directory -Path (Join-Path $t7 'obsolete') -Force | Out-Null
Set-Content -NoNewline -Path (Join-Path $t7 'obsolete/keep.txt') -Value "obsolete`n"
$log8 = Join-Path $SB7 'fake2.log'; Remove-Item -LiteralPath $log8 -ErrorAction SilentlyContinue
$r8 = Invoke-Entry $SB8 @('-NoDownload', '-Delete', '-NoRedeploy', '-NoSync') @{ FAKE_LOG = $log8 }
AssertRc $r8.ExitCode 0 '-Delete 更新 exit 0'
AssertAbsent (Join-Path $t7 'extra.txt') '允许的多余文件被删除'
AssertAbsent (Join-Path $t7 'obsolete/keep.txt') '多余子树文件被删除'
AssertAbsent (Join-Path $t7 'obsolete') '清空后的多余目录被删除'
AssertFileContent (Join-Path $t7 'user.yaml') "user-state`n" '-Delete 后 user.yaml 仍在'
AssertFileContent (Join-Path $t7 'foo.userdb/a/b/deep.txt') "deep-db`n" '-Delete 后 userdb 深层文件仍在'
AssertFileContent (Join-Path $t7 'build/compiled.bin') "bin`n" '-Delete 后 build/ 仍在'
AssertFileContent (Join-Path $t7 'lua/tips/tip.txt') "tip`n" '-Delete 后 lua/tips/ 仍在'
AssertPresent (Join-Path $t7 'custom/doc.md') '-Delete 后 custom/（前端排除项）仍在'

# ===========================================================================
Write-Host "== p9: -Init 只补缺失文件，不覆盖已存在"
$SB9 = New-Sandbox 'init'
Seed-Upstream $SB9
$t9 = Join-Path $SB9 'tgt9'
Write-WeaselConfig (Join-Path $SB9 'cmd/frontends.json') $t9
New-Item -ItemType Directory -Path $t9 -Force | Out-Null
Set-Content -NoNewline -Path (Join-Path $t9 'installation.yaml') -Value "MINE-NOT-OVERWRITE`n"
$r9 = Invoke-Entry $SB9 @('-NoDownload', '-Init', '-NoRedeploy', '-NoSync')
AssertRc $r9.ExitCode 0 '-Init 更新 exit 0'
AssertFileContent (Join-Path $t9 'installation.yaml') "MINE-NOT-OVERWRITE`n" '已存在 installation.yaml 不被覆盖'
AssertPresent (Join-Path $t9 'user.yaml') '缺失 user.yaml 被补上'

# ===========================================================================
Write-Host "== p10: -DryRun 无目标副作用（不创建目标、不生成用户短语、不调用 hook）"
$SB10 = New-Sandbox 'dry'
Seed-Upstream $SB10
$t10 = Join-Path $SB10 'tgt10'
Write-WeaselConfig (Join-Path $SB10 'cmd/frontends.json') $t10
$log10 = Join-Path $SB10 'fake.log'; Remove-Item -LiteralPath $log10 -ErrorAction SilentlyContinue
$r10 = Invoke-Entry $SB10 @('-NoDownload', '-DryRun') @{ FAKE_LOG = $log10 }
AssertRc $r10.ExitCode 0 'dry-run exit 0'
AssertAbsent $t10 'dry-run 未创建目标目录'
AssertAbsent (Join-Path $SB10 'custom_phrase_user.dict.yaml') 'dry-run 未生成用户短语文件'
AssertPresent (Join-Path $SB10 'build/stage/weasel/custom_phrase_user.dict.yaml') 'dry-run stage 使用示例短语'
AssertAbsent $log10 'dry-run 未调用 redeploy/sync'

# ===========================================================================
Write-Host "== p11: 目标校验（覆盖仅单前端 / 覆盖需关 hook / 重叠 / 重复目标）"
$SB11 = New-Sandbox 'targets'
Seed-Upstream $SB11
# 多前端 + -Target
@"
{"frontends": {
  "squirrel": {"active": true, "target_dir": "$SB11/t1", "rsync_filter": "squirrel/update-rsync.filter"},
  "weasel": {"active": true, "target_dir": "$SB11/t2", "rsync_filter": "weasel/update-rsync.filter"}
}}
"@ | Set-Content -NoNewline -Path (Join-Path $SB11 'cmd/frontends.json')
$r = Invoke-Entry $SB11 @('-NoDownload', '-Target', (Join-Path $SB11 't-override'))
AssertRc $r.ExitCode 1 '多前端 + -Target 拒绝'
AssertContains $r.Output '只允许单一' '拒绝原因明确'
AssertAbsent (Join-Path $SB11 't-override') '未创建覆盖目标'
# 单前端 + -Target 未关 hook
Write-SquirrelConfig (Join-Path $SB11 'cmd/frontends.json') (Join-Path $SB11 'tgt-default')
$r = Invoke-Entry $SB11 @('-NoDownload', '-Target', (Join-Path $SB11 't-override2'))
AssertRc $r.ExitCode 1 '非 dry-run 覆盖目标未关 hook 拒绝'
AssertContains $r.Output '-NoRedeploy -NoSync' '拒绝原因明确'
AssertAbsent (Join-Path $SB11 't-override2') '未创建覆盖目标'
# 单前端 + -Target + 关 hook
$log11 = Join-Path $SB11 'fake.log'; Remove-Item -LiteralPath $log11 -ErrorAction SilentlyContinue
$r = Invoke-Entry $SB11 @('-NoDownload', '-Target', (Join-Path $SB11 't-override3'), '-NoRedeploy', '-NoSync') @{ FAKE_LOG = $log11 }
AssertRc $r.ExitCode 0 '单前端 + 覆盖目标 + 关 hook 成功'
AssertAbsent $log11 '覆盖目标时不调用 redeploy/sync'
AssertPresent (Join-Path $SB11 't-override3/wanxiang.schema.yaml') '覆盖目标被写入'
# stage 与目标重叠
$r = Invoke-Entry $SB11 @('-NoDownload', '-Target', (Join-Path $SB11 'build/stage/squirrel'), '-NoRedeploy', '-NoSync', '-DryRun')
AssertRc $r.ExitCode 1 'stage 与目标重叠拒绝'
AssertContains $r.Output '重叠' '重叠原因明确'
# 多前端同目标
@"
{"frontends": {
  "squirrel": {"active": true, "target_dir": "$SB11/same-target", "rsync_filter": "squirrel/update-rsync.filter"},
  "weasel": {"active": true, "target_dir": "$SB11/same-target", "rsync_filter": "weasel/update-rsync.filter"}
}}
"@ | Set-Content -NoNewline -Path (Join-Path $SB11 'cmd/frontends.json')
$r = Invoke-Entry $SB11 @('-NoDownload')
AssertRc $r.ExitCode 1 '多前端同目标拒绝'
AssertContains $r.Output '同一目标' '重复目标原因明确'
AssertAbsent (Join-Path $SB11 'same-target') '未创建重复目标'

# ===========================================================================
Write-Host "== p12: 配置错误有明确结果"
$SB12 = New-Sandbox 'cfgerr'
$r = Invoke-Entry $SB12 @('-SyncOnly', '-Config', (Join-Path $Work 'missing-config.json'))
AssertRc $r.ExitCode 1 '缺配置退出 1'
AssertContains $r.Output 'Config not found' '缺配置提示明确'
$badJsonPath = Join-Path $Work 'bad.json'
Set-Content -NoNewline -Path $badJsonPath -Value '{"frontends": {'
$r = Invoke-Entry $SB12 @('-SyncOnly', '-Config', $badJsonPath)
AssertRc $r.ExitCode 1 '坏 JSON 退出 1'
AssertContains $r.Output 'Invalid JSON' '坏 JSON 提示明确'
$badActivePath = Join-Path $Work 'bad-active.json'
Set-Content -NoNewline -Path $badActivePath -Value '{"frontends": {"s": {"active": "sometimes", "target_dir": "/x"}}}'
$r = Invoke-Entry $SB12 @('-SyncOnly', '-Config', $badActivePath)
AssertRc $r.ExitCode 1 '坏 active 退出 1'
AssertContains $r.Output 'must be true, false, or "auto"' '坏 active 提示明确'
$badCmdPath = Join-Path $Work 'bad-cmd.json'
Set-Content -NoNewline -Path $badCmdPath -Value '{"frontends": {"s": {"active": true, "target_dir": "/x", "sync_cmd": "not-an-object"}}}'
$r = Invoke-Entry $SB12 @('-SyncOnly', '-Config', $badCmdPath)
AssertRc $r.ExitCode 1 '坏 sync_cmd 退出 1'
AssertContains $r.Output 'must be an object' '坏 sync_cmd 提示明确'

# ===========================================================================
Write-Host "== p13: .env 只从配置目录加载"
$SB13 = New-Sandbox 'envcfg'
$fixtureDir = Join-Path $Work 'env-fixture'
New-Item -ItemType Directory -Path $fixtureDir -Force | Out-Null
Set-Content -NoNewline -Path (Join-Path $SB13 'cmd/.env') -Value "RIME_TEST_ENV_MARK=FROM_SCRIPT_DIR_ENV`n"
$t13 = Join-Path $SB13 't'
Write-WeaselConfig (Join-Path $fixtureDir 'frontends.json') $t13
$log13 = Join-Path $SB13 'fake.log'; Remove-Item -LiteralPath $log13 -ErrorAction SilentlyContinue
$r = Invoke-Entry $SB13 @('-SyncOnly', '-Config', (Join-Path $fixtureDir 'frontends.json')) @{ FAKE_LOG = $log13 }
AssertRc $r.ExitCode 0 '使用外部配置 -SyncOnly 成功'
AssertTrue ((Test-Path -LiteralPath $log13) -and ((Get-Content -LiteralPath $log13 -Raw).Contains('ENV_MARK:<unset>'))) '未加载脚本目录的 .env'
Set-Content -NoNewline -Path (Join-Path $fixtureDir '.env') -Value "RIME_TEST_ENV_MARK=FROM_CONFIG_DIR_ENV`n"
Remove-Item -LiteralPath $log13 -ErrorAction SilentlyContinue
$r = Invoke-Entry $SB13 @('-SyncOnly', '-Config', (Join-Path $fixtureDir 'frontends.json')) @{ FAKE_LOG = $log13 }
AssertRc $r.ExitCode 0 '第二次运行成功'
AssertTrue ((Test-Path -LiteralPath $log13) -and ((Get-Content -LiteralPath $log13 -Raw).Contains('ENV_MARK:FROM_CONFIG_DIR_ENV'))) '加载了配置目录的 .env'

# ===========================================================================
Write-Host "== p14: 与 Bash+rsync 同场景交叉核对（当前项目 filter）"
$bashExe = Get-Command bash -ErrorAction SilentlyContinue
$rsyncExe = Get-Command rsync -ErrorAction SilentlyContinue
if ($bashExe -and $rsyncExe) {
    $SB14a = New-Sandbox 'parity-pwsh'
    $SB14b = New-Sandbox 'parity-bash'
    Seed-Upstream $SB14a; Seed-Upstream $SB14b
    foreach ($sb in @($SB14a, $SB14b)) {
        Set-Content -NoNewline -Path "$sb/cmd/squirrel/squirrel.custom.yaml" -Value "SQ-NEW`n"
    }
    $t14a = Join-Path $SB14a 'tgt'; $t14b = Join-Path $SB14b 'tgt'
    Write-SquirrelConfig (Join-Path $SB14a 'cmd/frontends.json') $t14a
    Write-SquirrelConfig (Join-Path $SB14b 'cmd/frontends.json') $t14b
    foreach ($t in @($t14a, $t14b)) {
        @{
            'user.yaml' = "user-state`n"
            'en.userdb/x/y.txt' = "db`n"
            'installation.yaml' = "inst`n"
            'build/b.bin' = "b`n"
            'squirrel.custom.yaml' = "SQ-OLD`n"
        }.GetEnumerator() | ForEach-Object {
            $p = Join-Path $t $_.Key
            New-Item -ItemType Directory -Path (Split-Path -Parent $p) -Force | Out-Null
            Set-Content -NoNewline -Path $p -Value $_.Value
            # 回溯 mtime：避免与 stage 同秒同大小时被 rsync -a quick-check 误判为未变化
            (Get-Item -LiteralPath $p).LastWriteTime = Get-Date '2020-01-01 00:00:00'
        }
    }
    $r14a = Invoke-Entry $SB14a @('-NoDownload', '-NoRedeploy', '-NoSync')
    AssertRc $r14a.ExitCode 0 'pwsh 更新 exit 0'
    $out14 = & bash (Join-Path $SB14b 'cmd/update.sh') --no-download --no-redeploy --no-sync 2>&1 | Out-String
    AssertTrue ($LASTEXITCODE -eq 0) 'bash+rsync 更新 exit 0'
    $filesA = (Get-ChildItem -LiteralPath $t14a -Recurse -File | ForEach-Object { $_.FullName.Substring($t14a.Length + 1) } | Sort-Object) -join "`n"
    $filesB = (Get-ChildItem -LiteralPath $t14b -Recurse -File | ForEach-Object { $_.FullName.Substring($t14b.Length + 1) } | Sort-Object) -join "`n"
    AssertEq $filesA $filesB '目标文件集合一致（pwsh == bash+rsync）'
    $sameContent = $true
    foreach ($rel in ($filesA -split "`n")) {
        if (-not $rel) { continue }
        $ca = Get-Content -LiteralPath (Join-Path $t14a $rel) -Raw -ErrorAction SilentlyContinue
        $cb = Get-Content -LiteralPath (Join-Path $t14b $rel) -Raw -ErrorAction SilentlyContinue
        if ($ca -ne $cb) { $sameContent = $false; Write-Host "  diff: $rel" }
    }
    AssertTrue $sameContent '目标文件内容一致'
} else {
    Write-Host '  SKIP: bash/rsync 不可用（macOS 应可用）'
}

Write-Host "== p15: 目标校验在任何 build 目录创建/下载之前（拒绝后零侧副作用）"
$SB15 = New-Sandbox 'tgt-early'
Seed-Upstream $SB15
$t15 = Join-Path $SB15 'tgt'
Write-WeaselConfig (Join-Path $SB15 'cmd/frontends.json') $t15
$r = Invoke-Entry $SB15 @('-NoDownload', '-Target', (Join-Path $SB15 'build/stage/weasel'), '-NoRedeploy', '-NoSync')
AssertRc $r.ExitCode 1 '重叠目标拒绝（exit 1）'
AssertAbsent (Join-Path $SB15 'build/stage/weasel') '目标未被创建'
AssertAbsent (Join-Path $SB15 'build/stage') 'build/stage 未被创建（校验先于 Initialize-BuildDirs）'
AssertAbsent $t15 '配置目标未被创建'
$r = Invoke-Entry $SB15 @('-NoDownload', '-Target', (Join-Path $SB15 'build/upstream'), '-NoRedeploy', '-NoSync', '-DryRun')
AssertRc $r.ExitCode 1 'upstream 重叠目标拒绝'
AssertFileContent (Join-Path $SB15 'build/upstream/wanxiang.schema.yaml') "upstream-schema-v1`n" 'upstream 内容不变'

# ===========================================================================
Write-Host "== p16: 启用的 hook 可执行文件在任何写入前预检（关闭的 hook 不要求存在）"
$SB16 = New-Sandbox 'hookpreflight'
Seed-Upstream $SB16
$t16 = Join-Path $SB16 'tgt'
@"
{
  "frontends": {
    "weasel": {
      "active": true,
      "target_dir": "$t16",
      "ui_layer": "weasel",
      "rsync_filter": "weasel/update-rsync.filter",
      "redeploy_cmd": {"executable": "/does-not-exist/rime-deploy", "args": ["/deploy"]},
      "sync_cmd": {"executable": "$Fake", "args": ["/sync"]}
    }
  }
}
"@ | Set-Content -NoNewline -Path (Join-Path $SB16 'cmd/frontends.json')
$log16 = Join-Path $SB16 'fake.log'
$r = Invoke-Entry $SB16 @('-NoDownload') @{ FAKE_LOG = $log16 }
AssertRc $r.ExitCode 1 'redeploy 可执行文件缺失 -> 退出 1'
AssertContains $r.Output '/does-not-exist/rime-deploy' '错误命名缺失的可执行文件'
AssertAbsent $t16 '预检失败时目标未被写入'
AssertAbsent (Join-Path $SB16 'build/stage') '预检失败时 stage 未被创建'
Remove-Item -LiteralPath $log16 -ErrorAction SilentlyContinue
$r = Invoke-Entry $SB16 @('-NoDownload', '-NoRedeploy') @{ FAKE_LOG = $log16 }
AssertRc $r.ExitCode 0 '关闭 redeploy 后成功'
AssertTrue ((Test-Path -LiteralPath $log16) -and ((Get-Content -LiteralPath $log16 -Raw).Contains('ARGV[0]:/sync'))) '启用中的 sync hook 正常执行'

# ===========================================================================
Write-Host "== p17: 等价路径（..）不得逃逸重复目标检测"
$SB17 = New-Sandbox 'dup-normalized'
Seed-Upstream $SB17
@"
{"frontends": {
  "squirrel": {"active": true, "target_dir": "$SB17/same-target", "rsync_filter": "squirrel/update-rsync.filter"},
  "weasel": {"active": true, "target_dir": "$SB17/same-target/../same-target", "rsync_filter": "weasel/update-rsync.filter"}
}}
"@ | Set-Content -NoNewline -Path (Join-Path $SB17 'cmd/frontends.json')
$r = Invoke-Entry $SB17 @('-NoDownload', '-NoRedeploy', '-NoSync')
AssertRc $r.ExitCode 1 '等价路径重复目标拒绝（exit 1）'
AssertContains $r.Output '同一目标' '拒绝原因明确'
AssertAbsent (Join-Path $SB17 'same-target') '重复目标未被创建'

# ===========================================================================
Write-Host "== p18: 参数边界（空参数与内嵌换行原样传递）"
$SB18 = New-Sandbox 'arg-boundary'
@'
{"frontends": {"squirrel": {"active": true, "target_dir": "__TGT__",
  "sync_cmd": {"executable": "__FAKE__", "args": ["--sync", "", "b\nc"]}}}}
'@.Replace('__TGT__', (Join-Path $SB18 'tgt')).Replace('__FAKE__', $Fake) | Set-Content -NoNewline -Path (Join-Path $SB18 'cmd/frontends.json')
$log18 = Join-Path $SB18 'fake.log'
$r = Invoke-Entry $SB18 @('-SyncOnly') @{ FAKE_LOG = $log18 }
AssertRc $r.ExitCode 0 '-SyncOnly exit 0'
$logRaw = Get-Content -LiteralPath $log18 -Raw
AssertTrue ($logRaw.Contains('ARGC:3')) '参数数目保留（3 个）'
AssertTrue (($logRaw -split "`n") -contains 'ARGV[1]:') '空参数保留为空串'
AssertTrue (($logRaw -split "`n") -contains 'ARGV[2]:b') '内嵌换行参数原样传递（首行）'
AssertTrue (($logRaw -split "`n") -contains 'c') '内嵌换行参数原样传递（次行）'

# ===========================================================================
Write-Host ''
Write-Host '=========================================='
Write-Host "PASS: $($script:Pass)  FAIL: $($script:Fail)"
if ($script:Fail -gt 0) {
    $script:FailedNames | ForEach-Object { Write-Host "failed: $_" }
    Write-Host "沙盒保留供调试: $Work"
    exit 1
}
Remove-Item -LiteralPath $Work -Recurse -Force
Write-Host 'ALL PWSH SCENARIOS PASSED'
exit 0
