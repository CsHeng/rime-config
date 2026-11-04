#Requires -Version 7.0
<#
.SYNOPSIS
  Rime configuration updater — PowerShell 7 entry (no yq / rsync / curl / jq / unzip dependency).
.DESCRIPTION
  Reads cmd/frontends.json, downloads upstream schema/dicts/grammar, merges with
  local overlays, and syncs to each active frontend's target directory using
  native file operations. Cloud bridge (iCloud <-> OneDrive) is macOS-only and
  lives in cmd/sync-userdict.sh; -CloudSync is rejected here.
.NOTES
  Exit codes: 0 success; 1 failure. -SyncOnly waits for the sync command to exit
  (WeaselDeployer /sync blocks until the maintenance thread finishes, so its
  exit code is the sync result; Squirrel --sync is only an async notification).
#>

[CmdletBinding()]
param(
    [string]$Config,
    [string]$Target,
    [switch]$Init,
    [switch]$DryRun,
    [switch]$NoDownload,
    [switch]$Delete,
    [switch]$NoDelete,
    [switch]$Redeploy,
    [switch]$NoRedeploy,
    [switch]$Sync,
    [switch]$NoSync,
    [switch]$SyncOnly,
    [switch]$CloudSync
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Definition
$RepoDir    = Split-Path -Parent $ScriptDir
$BuildDir   = Join-Path $RepoDir 'build'
$TmpDir     = Join-Path $BuildDir 'tmp'
$MarkersDir = Join-Path $BuildDir 'markers'
$CacheDir   = Join-Path $BuildDir 'cache'
$UpstreamDir= Join-Path $BuildDir 'upstream'
$StageRoot  = Join-Path $BuildDir 'stage'

# ---------------------------------------------------------------------------
# Flag defaults (match bash: redeploy=on, sync=on, delete=off)
# ---------------------------------------------------------------------------
$FlagRedeploy = if ($NoRedeploy) { $false } elseif ($Redeploy) { $true } else { $true }
$FlagSync     = if ($NoSync)     { $false } elseif ($Sync)     { $true } else { $true }
$FlagDelete   = if ($NoDelete)   { $false } elseif ($Delete)   { $true } else { $false }

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
function Write-Log {
    param(
        [ValidateSet('info','warn','error','debug')]
        [string]$Level,
        [string]$Message
    )
    $color = switch ($Level) {
        'info'  { 'Green' }
        'warn'  { 'Yellow' }
        'error' { 'Red' }
        'debug' { 'Gray' }
    }
    if ($Level -eq 'debug' -and -not $DebugPreference) { return }
    if ($Level -eq 'error') { $Message = "ERROR: $Message" }
    Write-Host $Message -ForegroundColor $color
}

function Fail {
    param([Parameter(Mandatory)][string]$Message)
    Write-Log -Level error $Message
    exit 1
}

# ---------------------------------------------------------------------------
# Config resolution (single read, single validation)
# ---------------------------------------------------------------------------
if ($Config) {
    $ConfigPath = if ([IO.Path]::IsPathRooted($Config)) { $Config } else { Join-Path $PWD $Config }
} else {
    $ConfigPath = Join-Path $ScriptDir 'frontends.json'
}
$ConfigDir = Split-Path -Parent $ConfigPath

function Get-Prop {
    <# Null-safe property access for PSCustomObject under Set-StrictMode.
       Note: `,$p.Value` prevents PowerShell from unrolling array-valued properties (e.g. args: ["--sync"]). #>
    param([Parameter(Mandatory)]$Object, [Parameter(Mandatory)][string]$Name)
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return , $p.Value } else { return $null }
}

function ConvertTo-NativePath {
    <#
    .SYNOPSIS
      Converts /c/Users/... to C:\Users\... and ~/... to $HOME/... on Windows.
      Relative paths are resolved against the config directory.
    #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not $Path) { return $Path }
    if ($Path -eq '~') { return $HOME }
    if ($Path.StartsWith('~/')) { $Path = "$HOME/" + $Path.Substring(2) }
    if (-not [IO.Path]::IsPathRooted($Path)) {
        $Path = Join-Path $ConfigDir $Path
    }
    if ($IsWindows -and $Path -match '^/([a-zA-Z])/(.*)$') {
        $drive = $Matches[1].ToUpper()
        $rest  = $Matches[2] -replace '/', '\'
        return "${drive}:\$rest"
    }
    return $Path
}

function Assert-ValidCommandObject {
    param($Cmd, [string]$What)
    if ($null -eq $Cmd) { return }
    if ($Cmd -isnot [System.Management.Automation.PSCustomObject]) {
        throw "${What}: must be an object {`"executable`", `"args`"}"
    }
    $exe = Get-Prop $Cmd 'executable'
    if ($exe -isnot [string] -or -not $exe) {
        throw "${What}.executable: must be a non-empty string"
    }
    $argsValue = Get-Prop $Cmd 'args'
    if ($null -ne $argsValue) {
        if ($argsValue -isnot [array]) { throw "${What}.args: must be an array of strings" }
        foreach ($a in $argsValue) {
            if ($a -isnot [string]) { throw "${What}.args: must be an array of strings" }
        }
    }
}

function Get-FrontendsConfig {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Config not found: $Path (copy cmd/frontends.json.tmpl to cmd/frontends.json and edit it)"
    }
    try {
        $cfg = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "Invalid JSON in ${Path}: $($_.Exception.Message)"
    }

    $auto = Get-Prop $cfg 'auto'
    if ($null -ne $auto) {
        if ($auto -isnot [System.Management.Automation.PSCustomObject]) {
            throw 'auto: must be an object like {"darwin": ..., "windows": ...}'
        }
        foreach ($k in @('darwin','windows')) {
            $v = Get-Prop $auto $k
            if ($null -ne $v -and $v -isnot [string]) { throw "auto.$k must be a string (frontend name)" }
        }
    }

    $frontends = Get-Prop $cfg 'frontends'
    if ($frontends -isnot [System.Management.Automation.PSCustomObject]) {
        throw 'frontends: must be an object mapping frontend name -> settings'
    }
    if (@($frontends.PSObject.Properties).Count -eq 0) {
        throw 'frontends: must contain at least one frontend'
    }
    foreach ($p in $frontends.PSObject.Properties) {
        $name = $p.Name
        $entry = $p.Value
        if ($entry -isnot [System.Management.Automation.PSCustomObject]) {
            throw "frontends.${name}: must be an object"
        }
        $active = Get-Prop $entry 'active'
        $activeOk = $active -is [bool]
        if (-not $activeOk -and $active -is [string]) { $activeOk = ($active -eq 'auto') }
        if (-not $activeOk) {
            throw "frontends.${name}.active: must be true, false, or `"auto`""
        }
        foreach ($field in @('target_dir','ui_layer','rsync_filter','bootstrap_filter')) {
            $v = Get-Prop $entry $field
            if ($null -ne $v -and $v -isnot [string]) { throw "frontends.${name}.${field}: must be a string" }
        }
        Assert-ValidCommandObject (Get-Prop $entry 'redeploy_cmd') "frontends.${name}.redeploy_cmd"
        Assert-ValidCommandObject (Get-Prop $entry 'sync_cmd')     "frontends.${name}.sync_cmd"
    }

    $uds = Get-Prop $cfg 'userdict_sync'
    if ($null -ne $uds) {
        if ($uds -isnot [System.Management.Automation.PSCustomObject]) {
            throw 'userdict_sync: must be an object {"icloud", "onedrive"}'
        }
        $ic = Get-Prop $uds 'icloud'
        if ($null -ne $ic -and $ic -isnot [string]) { throw 'userdict_sync.icloud: must be a string' }
        $od = Get-Prop $uds 'onedrive'
        if ($null -ne $od) {
            if ($od -isnot [System.Management.Automation.PSCustomObject]) {
                throw 'userdict_sync.onedrive: must be an object {"darwin"}'
            }
            foreach ($p in $od.PSObject.Properties) {
                if ($p.Value -isnot [string]) { throw "userdict_sync.onedrive.$($p.Name): must be a string" }
            }
        }
    }
    return $cfg
}

# ---------------------------------------------------------------------------
# .env loader (only from the selected config directory)
# ---------------------------------------------------------------------------
function Import-DotEnv {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    Get-Content -LiteralPath $Path | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith('#')) {
            if ($line -match '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
                [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2].Trim('"').Trim("'"), 'Process')
            }
        }
    }
}

Import-DotEnv (Join-Path $ConfigDir '.env')

# ---------------------------------------------------------------------------
# Frontend selection (same semantics as cmd/frontends.sh)
# ---------------------------------------------------------------------------
$script:FrontendsConfig = $null

function Get-AutoFrontend {
    $auto = Get-Prop $script:FrontendsConfig 'auto'
    if ($null -eq $auto) { return 'none' }
    if ($IsWindows)  { $v = Get-Prop $auto 'windows' } else { $v = $null }
    if ($IsMacOS)    { $v = Get-Prop $auto 'darwin' }
    if (-not $IsWindows -and -not $IsMacOS) { return 'none' }
    if ($v) { return [string]$v }
    return 'none'
}

function Get-ActiveFrontends {
    $frontends = Get-Prop $script:FrontendsConfig 'frontends'
    $auto = Get-AutoFrontend
    $result = [System.Collections.Generic.List[string]]::new()
    foreach ($p in $frontends.PSObject.Properties) {
        if ((Get-Prop $p.Value 'active') -is [bool] -and (Get-Prop $p.Value 'active')) {
            if ($p.Name -notin $result) { $result.Add($p.Name) }
        }
    }
    if ($auto -ne 'none') {
        foreach ($p in $frontends.PSObject.Properties) {
            $a = Get-Prop $p.Value 'active'
            if ($p.Name -eq $auto -and $a -is [string] -and $a -eq 'auto' -and $p.Name -notin $result) {
                $result.Add($p.Name)
                break
            }
        }
    }
    return , $result
}

function Get-FrontendEntry {
    param([Parameter(Mandatory)][string]$Frontend)
    $frontends = Get-Prop $script:FrontendsConfig 'frontends'
    $p = $frontends.PSObject.Properties[$Frontend]
    if (-not $p) { throw "Unknown frontend: $Frontend" }
    return $p.Value
}

function Get-FrontendString {
    param([Parameter(Mandatory)]$Entry, [Parameter(Mandatory)][string]$Field, [string]$Default = '')
    $v = Get-Prop $Entry $Field
    if ($null -eq $v) { return $Default }
    return [string]$v
}

function Get-FrontendCommand {
    <# Returns $null or @{ Executable = string; Arguments = string[] }。
       注意：Get-Prop 的逗号包裹已保留数组本体；这里不得再包 @() 外层（否则数组成为单元素，
       foreach 会把整个数组拼接成一个参数）。 #>
    param($Cmd)
    if ($null -eq $Cmd) { return $null }
    $exe = [string](Get-Prop $Cmd 'executable')
    $rawArgs = Get-Prop $Cmd 'args'
    $argList = [System.Collections.Generic.List[string]]::new()
    if ($null -ne $rawArgs) {
        foreach ($a in @($rawArgs)) { $argList.Add([string]$a) }
    }
    return @{ Executable = $exe; Arguments = $argList }
}

function Resolve-CommandExecutable {
    param([Parameter(Mandatory)][string]$Exe, [switch]$Quiet)
    if ($Exe -match '[/\\]') {
        $resolved = ConvertTo-NativePath $Exe
        if (Test-Path -LiteralPath $resolved -PathType Leaf) { return $resolved }
        if (-not $Quiet) { Write-Log -Level error "executable not found: $Exe (resolved: $resolved)" }
        return $null
    }
    $found = Get-Command $Exe -ErrorAction SilentlyContinue
    if ($found) { return $found.Source }
    if (-not $Quiet) { Write-Log -Level error "executable not found in PATH: $Exe" }
    return $null
}

# ---------------------------------------------------------------------------
# Native command invocation (no Invoke-Expression; arguments passed as-is)
# ---------------------------------------------------------------------------
$script:HookFailures = [System.Collections.Generic.List[string]]::new()

function Invoke-FrontendCommand {
    <# Runs the command; on failure records frontend|stage|exitcode. Returns $true on success. #>
    param(
        [Parameter(Mandatory)][string]$Frontend,
        [Parameter(Mandatory)][string]$Stage,
        [Parameter(Mandatory)][hashtable]$Command
    )
    $exe = $Command.Executable
    $arguments = @($Command.Arguments)
    Write-Log -Level info "Running [$Stage] frontend '$Frontend': $exe $($arguments -join ' ')"
    & $exe @arguments
    $code = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { 0 }
    if ($code -ne 0) {
        $script:HookFailures.Add("$Frontend|$Stage|$code")
        Write-Log -Level error "frontend '$Frontend' stage '$Stage' failed with exit code $code (cmd: $exe $($arguments -join ' '))"
        return $false
    }
    return $true
}

function Report-SyncSubmission {
    param([Parameter(Mandatory)][string]$Exe)
    $base = [IO.Path]::GetFileName($Exe)
    if ($base -like 'Squirrel*') {
        Write-Log -Level warn "已提交（异步通知）：$Exe 退出仅代表通知已发送；Squirrel --sync 无完成信号"
    } else {
        Write-Log -Level info "同步命令退出码 0（WeaselDeployer /sync 会等待同步完成；其他可执行文件以其自身语义为准）"
    }
}

# ---------------------------------------------------------------------------
# rsync filter engine (directory-aware; copy and delete share one rule set)
# ---------------------------------------------------------------------------
function ConvertFrom-RsyncFilter {
    <#
    .SYNOPSIS
      Parses an rsync filter file into rule objects; unsupported rules throw.
    .DESCRIPTION
      Supported pattern syntax (exactly what this project's filters use):
        + name / - name     exact filename match (basename), quotes allowed
        - dir/              directory with that name at any depth (dir-only)
        - path/             anchored directory path (e.g. lua/tips/)
        - dir/**            everything under dir/ (anchored)
        - **.userdb/        directory whose any path segment ends with suffix (dir-only)
        + * / - *           catch-all
      First-match-wins (same as rsync). Any other wildcard usage is an error,
      not a silent skip.
    #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Filter file not found: $Path" }
    $rules = [System.Collections.Generic.List[PSCustomObject]]::new()
    $lineNo = 0
    foreach ($raw in (Get-Content -LiteralPath $Path)) {
        $lineNo++
        $line = $raw.Trim()
        if (-not $line -or $line.StartsWith('#')) { continue }
        if ($line -notmatch '^([+-])\s+(.+)$') {
            throw "Unsupported filter rule at $Path`:$lineNo`: '$line' (expected '+ pattern' or '- pattern')"
        }
        $action  = if ($Matches[1] -eq '+') { 'include' } else { 'exclude' }
        $pattern = $Matches[2].Trim()
        if ($pattern.Length -ge 2 -and $pattern.StartsWith('"') -and $pattern.EndsWith('"')) {
            $pattern = $pattern.Substring(1, $pattern.Length - 2)
        }

        $kind = $null; $value = $null
        if ($pattern -eq '*') {
            $kind = 'catchall'; $value = $null
        }
        elseif ($pattern.StartsWith('**')) {
            if (-not $pattern.EndsWith('/')) {
                throw "Unsupported filter pattern at $Path`:$lineNo`: '$pattern' (** patterns must end with / here)"
            }
            $suffix = $pattern.TrimEnd('/').TrimStart('*')
            if ($suffix -match '[*?/]') {
                throw "Unsupported filter pattern at $Path`:$lineNo`: '$pattern' (wildcard inside ** suffix)"
            }
            $kind = 'seg-suffix-dir'; $value = $suffix
        }
        elseif ($pattern.EndsWith('/**')) {
            $prefix = $pattern.Substring(0, $pattern.Length - 3)
            if ($prefix -match '[*?]' -or -not $prefix) {
                throw "Unsupported filter pattern at $Path`:$lineNo`: '$pattern'"
            }
            $kind = 'under-path'; $value = $prefix
        }
        elseif ($pattern.EndsWith('/')) {
            $name = $pattern.TrimEnd('/')
            if ($name -match '[*?]') {
                throw "Unsupported filter pattern at $Path`:$lineNo`: '$pattern' (wildcard in directory name)"
            }
            if ($name.Contains('/')) { $kind = 'anchored-dir' } else { $kind = 'anywhere-dir' }
            $value = $name
        }
        else {
            if ($pattern -match '[*?/]') {
                throw "Unsupported filter pattern at $Path`:$lineNo`: '$pattern' (only exact filenames are supported without wildcards)"
            }
            $kind = 'basename'; $value = $pattern
        }

        $rules.Add([PSCustomObject]@{
            Action  = $action
            Kind    = $kind
            Value   = $value
            Raw     = $line
        })
    }
    if ($rules.Count -eq 0) { throw "Filter file has no rules: $Path" }
    return $rules
}

function Test-RsyncFilter {
    <#
    .SYNOPSIS
      First-match-wins evaluation. Returns 'include', 'exclude', or 'no-match'.
    #>
    param(
        [Parameter(Mandatory)]$Rules,
        [Parameter(Mandatory)][string]$RelativePath,
        [bool]$IsDirectory = $false
    )
    $segments = $RelativePath -split '/'
    $basename = $segments[-1]
    foreach ($rule in $Rules) {
        $matched = switch ($rule.Kind) {
            'catchall'        { $true }
            'seg-suffix-dir'  { $IsDirectory -and (@($segments | Where-Object { $_.EndsWith($rule.Value) }).Count -gt 0) }
            'under-path'      { $RelativePath -eq $rule.Value -or $RelativePath.StartsWith("$($rule.Value)/") }
            'anywhere-dir'    { $IsDirectory -and ($segments -contains $rule.Value) }
            'anchored-dir'    { $IsDirectory -and $RelativePath -eq $rule.Value }
            'basename'        { $basename -eq $rule.Value }
            default           { $false }
        }
        if ($matched) { return $rule.Action }
    }
    return 'no-match'
}

function Copy-FilteredTree {
    <#
    .SYNOPSIS
      Syncs source directory to destination using rsync filter rules.
      Directory-aware: an excluded directory prunes the whole subtree for both
      copy and delete. Copy and delete share the same rule interpretation.
    .PARAMETER DeleteExtra
      Removes destination entries missing from source that the filter allows.
      Protected entries (filter-excluded) are never enumerated or deleted.
    .PARAMETER IgnoreExisting
      Skips files that already exist in destination (rsync --ignore-existing).
    .NOTES
      Does not create the destination in dry-run mode.
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$FilterFile,
        [switch]$DeleteExtra,
        [switch]$IgnoreExisting
    )

    $rules = ConvertFrom-RsyncFilter -Path $FilterFile
    $srcRoot = (Resolve-Path -LiteralPath $Source).Path.TrimEnd('\','/')

    $dstExists = Test-Path -LiteralPath $Destination
    if (-not $dstExists) {
        if ($DryRun) {
            Write-Log -Level info "  [dry-run] target absent, would create: $Destination"
            $dstRoot = [IO.Path]::GetFullPath($Destination).TrimEnd('\','/')
        } else {
            New-Item -ItemType Directory -Path $Destination -Force | Out-Null
            $dstRoot = (Resolve-Path -LiteralPath $Destination).Path.TrimEnd('\','/')
        }
    } else {
        $dstRoot = (Resolve-Path -LiteralPath $Destination).Path.TrimEnd('\','/')
    }

    # --- Phase 1: copy (directory-aware traversal) ---
    $stack = [System.Collections.Generic.Stack[string]]::new()
    $stack.Push($srcRoot)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        foreach ($item in Get-ChildItem -LiteralPath $dir -Force) {
            if ($item.Name -eq '.DS_Store') { continue }
            $relPath = $item.FullName.Substring($srcRoot.Length + 1) -replace '\\', '/'
            $isDir = $item.PSIsContainer
            $verdict = Test-RsyncFilter -Rules $rules -RelativePath $relPath -IsDirectory $isDir
            if ($verdict -eq 'exclude') { continue }   # excluded dir: skip entire subtree

            if ($isDir) {
                $destPath = Join-Path $dstRoot ($relPath -replace '/', [IO.Path]::DirectorySeparatorChar)
                if (-not (Test-Path -LiteralPath $destPath)) {
                    if ($DryRun) {
                        Write-Log -Level info "  [dry-run] mkdir: $relPath/"
                    } else {
                        New-Item -ItemType Directory -Path $destPath -Force | Out-Null
                    }
                }
                $stack.Push($item.FullName)
            } else {
                $destPath = Join-Path $dstRoot ($relPath -replace '/', [IO.Path]::DirectorySeparatorChar)
                if ($IgnoreExisting -and (Test-Path -LiteralPath $destPath)) { continue }
                if ($DryRun) {
                    Write-Log -Level info "  [dry-run] copy: $relPath"
                } else {
                    $destDir = Split-Path -Parent $destPath
                    if (-not (Test-Path -LiteralPath $destDir)) {
                        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
                    }
                    Copy-Item -LiteralPath $item.FullName -Destination $destPath -Force
                }
            }
        }
    }

    # --- Phase 2: delete extras (same directory-aware walk as copy; excluded dirs prune subtrees) ---
    if ($DeleteExtra -and $dstExists -and -not $DryRun) {
        # 先删文件（遍历时跳过被排除目录的整棵子树），后按深度删除空目录
        $dirsSeen = [System.Collections.Generic.List[string]]::new()
        $stack.Clear()
        $stack.Push($dstRoot)
        while ($stack.Count -gt 0) {
            $dir = $stack.Pop()
            foreach ($item in Get-ChildItem -LiteralPath $dir -Force) {
                if ($item.Name -eq '.DS_Store') { continue }
                $relPath = $item.FullName.Substring($dstRoot.Length + 1) -replace '\\', '/'
                $isDir = $item.PSIsContainer
                # 与复制阶段同一套规则：被排除的目录整棵子树不枚举、不删除
                if ((Test-RsyncFilter -Rules $rules -RelativePath $relPath -IsDirectory $isDir) -eq 'exclude') { continue }
                $srcPath = Join-Path $srcRoot ($relPath -replace '/', [IO.Path]::DirectorySeparatorChar)
                if ($isDir) {
                    $dirsSeen.Add($item.FullName)
                    $stack.Push($item.FullName)
                } else {
                    if (-not (Test-Path -LiteralPath $srcPath)) {
                        Remove-Item -LiteralPath $item.FullName -Force
                        Write-Log -Level info "  deleted (extra): $relPath"
                    }
                }
            }
        }
        # 只删空目录（任何受保护/保留内容都会使其非空），不会通过删父目录绕过保护
        foreach ($dir in ($dirsSeen | Sort-Object { $_.Length } -Descending)) {
            $relPath = $dir.Substring($dstRoot.Length + 1) -replace '\\', '/'
            $srcPath = Join-Path $srcRoot ($relPath -replace '/', [IO.Path]::DirectorySeparatorChar)
            if (-not (Test-Path -LiteralPath $srcPath) -and -not (Get-ChildItem -LiteralPath $dir -Force)) {
                Remove-Item -LiteralPath $dir -Force
                Write-Log -Level info "  deleted (extra dir): $relPath/"
            }
        }
    } elseif ($DeleteExtra -and $DryRun) {
        Write-Log -Level info "  [dry-run] -Delete: would remove filter-allowed files missing from source"
    }
}

# ---------------------------------------------------------------------------
# GitHub API / download
# ---------------------------------------------------------------------------
function Get-GitHubReleases {
    param([Parameter(Mandatory)][string]$Repo)
    $url = "https://api.github.com/repos/$Repo/releases"
    $headers = @{ 'User-Agent' = 'rime-config-updater' }
    if ($env:GITHUB_TOKEN) {
        $headers['Authorization'] = "token $env:GITHUB_TOKEN"
    }
    return Invoke-RestMethod -Uri $url -Headers $headers -ErrorAction Stop
}

function Find-GitHubAsset {
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$TagPrefix,
        [Parameter(Mandatory)][string]$AssetName,
        [ValidateSet('tag','asset_updated_at')]
        [string]$VersionMode = 'tag'
    )
    $releases = Get-GitHubReleases -Repo $Repo
    $release = $releases | Where-Object { $_.tag_name.StartsWith($TagPrefix) } | Select-Object -First 1
    if (-not $release) {
        throw "No release tag starting with '$TagPrefix' in $Repo"
    }
    $asset = $release.assets | Where-Object { $_.name -eq $AssetName } | Select-Object -First 1
    if (-not $asset) {
        throw "Asset not found in ${Repo}@$($release.tag_name): $AssetName"
    }
    $version = switch ($VersionMode) {
        'tag'              { $release.tag_name }
        'asset_updated_at' { $asset.updated_at }
    }
    if (-not $version) {
        $version = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ')
    }
    return [PSCustomObject]@{
        Tag     = $release.tag_name
        Version = $version
        Url     = $asset.browser_download_url
    }
}

function Save-Download {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$OutFile
    )
    $tmpFile = "$OutFile.tmp"
    Write-Log -Level info "Downloading: $(Split-Path $OutFile -Leaf)"
    try {
        Invoke-WebRequest -Uri $Url -OutFile $tmpFile -ErrorAction Stop
        Move-Item -Path $tmpFile -Destination $OutFile -Force
    } catch {
        Remove-Item -Path $tmpFile -ErrorAction SilentlyContinue
        throw "Download failed: $Url — $_"
    }
}

function Expand-ZipToDirectory {
    param(
        [Parameter(Mandatory)][string]$ZipPath,
        [Parameter(Mandatory)][string]$Destination
    )
    if (-not (Test-Path -LiteralPath $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }
    Expand-Archive -Path $ZipPath -DestinationPath $Destination -Force
}

function Expand-ZipFlatten {
    param(
        [Parameter(Mandatory)][string]$ZipPath,
        [Parameter(Mandatory)][string]$Destination
    )
    $tmpExtract = Join-Path $TmpDir "extract_$PID"
    if (Test-Path -LiteralPath $tmpExtract) { Remove-Item -LiteralPath $tmpExtract -Recurse -Force }
    New-Item -ItemType Directory -Path $tmpExtract -Force | Out-Null
    if (-not (Test-Path -LiteralPath $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }
    Expand-Archive -Path $ZipPath -DestinationPath $tmpExtract -Force
    Get-ChildItem -LiteralPath $tmpExtract -Recurse -File | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $Destination $_.Name) -Force
    }
    Remove-Item -LiteralPath $tmpExtract -Recurse -Force
}

# ---------------------------------------------------------------------------
# Markers
# ---------------------------------------------------------------------------
function Get-Marker {
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path -LiteralPath $Path) { return (Get-Content -LiteralPath $Path -Raw).Trim() }
    return ''
}

function Set-Marker {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Value
    )
    Set-Content -Path $Path -Value $Value -NoNewline
}

# ---------------------------------------------------------------------------
# Build: upstream cache
# ---------------------------------------------------------------------------
function Initialize-BuildDirs {
    @($TmpDir, $MarkersDir, $CacheDir, $UpstreamDir, $StageRoot) | ForEach-Object {
        if (-not (Test-Path -LiteralPath $_)) { New-Item -ItemType Directory -Path $_ -Force | Out-Null }
    }
}

function Update-UpstreamCache {
    Initialize-BuildDirs

    $schemaRepo  = 'amzxyz/rime-wanxiang'

    # --- schema ---
    $schemaAsset  = 'rime-wanxiang-base.zip'
    $schemaMarker = Join-Path $MarkersDir 'schema_version'
    $schemaZip    = Join-Path $CacheDir $schemaAsset

    $schemaInfo    = Find-GitHubAsset -Repo $schemaRepo -TagPrefix 'v' -AssetName $schemaAsset -VersionMode tag
    $schemaStored  = Get-Marker -Path $schemaMarker
    $upstreamEmpty = -not (Test-Path -LiteralPath $UpstreamDir) -or -not (Get-ChildItem -LiteralPath $UpstreamDir -Force -ErrorAction SilentlyContinue)

    if ($schemaInfo.Version -ne $schemaStored -or $upstreamEmpty) {
        Save-Download -Url $schemaInfo.Url -OutFile $schemaZip
        if (Test-Path -LiteralPath $UpstreamDir) { Remove-Item -LiteralPath $UpstreamDir -Recurse -Force }
        New-Item -ItemType Directory -Path $UpstreamDir -Force | Out-Null
        Write-Log -Level info 'Extracting schema -> build/upstream/'
        Expand-ZipToDirectory -ZipPath $schemaZip -Destination $UpstreamDir
        Set-Marker -Path $schemaMarker -Value $schemaInfo.Version
    } else {
        Write-Log -Level info "Schema up to date: $($schemaInfo.Version)"
    }

    # --- dicts ---
    $dictsAsset  = 'base-dicts.zip'
    $dictsMarker = Join-Path $MarkersDir 'dicts_version'
    $dictsZip    = Join-Path $CacheDir $dictsAsset
    $dictsDir    = Join-Path $UpstreamDir 'dicts'

    $dictsInfo   = Find-GitHubAsset -Repo $schemaRepo -TagPrefix 'dict-nightly' -AssetName $dictsAsset -VersionMode asset_updated_at
    $dictsStored = Get-Marker -Path $dictsMarker

    if ($dictsInfo.Version -ne $dictsStored -or -not (Test-Path -LiteralPath $dictsDir)) {
        Save-Download -Url $dictsInfo.Url -OutFile $dictsZip
        if (Test-Path -LiteralPath $dictsDir) { Remove-Item -LiteralPath $dictsDir -Recurse -Force }
        New-Item -ItemType Directory -Path $dictsDir -Force | Out-Null
        Write-Log -Level info 'Extracting dicts -> build/upstream/dicts/'
        Expand-ZipFlatten -ZipPath $dictsZip -Destination $dictsDir
        Set-Marker -Path $dictsMarker -Value $dictsInfo.Version
    } else {
        Write-Log -Level info "Dicts up to date: $($dictsInfo.Version)"
    }

    # --- grammar (data repo renamed from amzxyz/RIME-LMDG) ---
    $grammarRepo   = 'amzxyz/rime-wanxiang-data'
    $grammarAsset  = 'wanxiang-lts-zh-hans.gram'
    $grammarMarker = Join-Path $MarkersDir 'grammar_version'
    $grammarFile   = Join-Path $CacheDir $grammarAsset
    $grammarDest   = Join-Path $UpstreamDir $grammarAsset

    $grammarInfo   = Find-GitHubAsset -Repo $grammarRepo -TagPrefix 'LTS' -AssetName $grammarAsset -VersionMode asset_updated_at
    $grammarStored = Get-Marker -Path $grammarMarker

    if ($grammarInfo.Version -ne $grammarStored -or -not (Test-Path -LiteralPath $grammarDest)) {
        Save-Download -Url $grammarInfo.Url -OutFile $grammarFile
        Write-Log -Level info "Updating grammar -> build/upstream/$grammarAsset"
        Copy-Item -LiteralPath $grammarFile -Destination $grammarDest -Force
        Set-Marker -Path $grammarMarker -Value $grammarInfo.Version
    } else {
        Write-Log -Level info "Grammar up to date: $($grammarInfo.Version)"
    }
}

# ---------------------------------------------------------------------------
# Build: stage directory
# ---------------------------------------------------------------------------
function Copy-DirectoryContents {
    <# Recursively copies directory contents, excluding .DS_Store (rsync -a equivalent for our needs). #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )
    if (-not (Test-Path -LiteralPath $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }
    Get-ChildItem -LiteralPath $Source -Recurse -Force | Where-Object { $_.Name -ne '.DS_Store' } | ForEach-Object {
        $relPath = $_.FullName.Substring((Resolve-Path -LiteralPath $Source).Path.Length + 1)
        $destPath = Join-Path $Destination $relPath
        if ($_.PSIsContainer) {
            if (-not (Test-Path -LiteralPath $destPath)) {
                New-Item -ItemType Directory -Path $destPath -Force | Out-Null
            }
        } else {
            $destDir = Split-Path -Parent $destPath
            if (-not (Test-Path -LiteralPath $destDir)) {
                New-Item -ItemType Directory -Path $destDir -Force | Out-Null
            }
            Copy-Item -LiteralPath $_.FullName -Destination $destPath -Force
        }
    }
}

function Build-StageDirectory {
    param(
        [Parameter(Mandatory)][string]$Frontend,
        [string]$UiLayer = 'none'
    )
    $stage = Join-Path $StageRoot $Frontend
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
    New-Item -ItemType Directory -Path $stage -Force | Out-Null

    if ($Frontend -ne 'none') {
        Copy-DirectoryContents -Source $UpstreamDir -Destination $stage
    }

    # local layer (repo tracked)
    # 自定义置顶短语词库（gitignored）；缺失时用模板生成，保证 custom_phrase_user 始终可编译。
    # dry-run 只把示例放进 stage，不在仓库生成用户副本；实际执行才生成。
    $phraseDict = Join-Path $RepoDir 'custom_phrase_user.dict.yaml'
    $phraseTemplate = Join-Path $RepoDir 'custom_phrase_user.dict.yaml.example'
    if (-not (Test-Path -LiteralPath $phraseDict)) {
        if (Test-Path -LiteralPath $phraseTemplate) {
            if ($DryRun) {
                Copy-Item -LiteralPath $phraseTemplate -Destination (Join-Path $stage 'custom_phrase_user.dict.yaml') -Force
                Write-Log -Level info '(dry-run) stage 使用示例短语模板；未生成 custom_phrase_user.dict.yaml'
            } else {
                Copy-Item -LiteralPath $phraseTemplate -Destination $phraseDict -Force
                Write-Log -Level warn 'Created custom_phrase_user.dict.yaml from template (edit it to add your phrases)'
            }
        }
    }
    if (Test-Path -LiteralPath $phraseDict) {
        Copy-Item -LiteralPath $phraseDict -Destination (Join-Path $stage 'custom_phrase_user.dict.yaml') -Force
    }
    Get-ChildItem -LiteralPath $RepoDir -Filter '*.custom.yaml' -File | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $stage $_.Name) -Force
    }

    # UI overlays
    if ($UiLayer -and $UiLayer -ne 'none') {
        $commonDefault = Join-Path $RepoDir 'cmd/common/default.custom.yaml'
        if (Test-Path -LiteralPath $commonDefault) {
            Copy-Item -LiteralPath $commonDefault -Destination (Join-Path $stage 'default.custom.yaml') -Force
        }
        $tplDir = Join-Path $RepoDir "cmd/$UiLayer"
        if (Test-Path -LiteralPath $tplDir) {
            # UI 层只取 patch 与 Hamster3 的 include_keyboard_rime_files.txt（键盘→应用 包含规则）
            Get-ChildItem -LiteralPath $tplDir -File | Where-Object {
                $_.Name -like '*.custom.yaml' -or $_.Name -like '*.txt'
            } | ForEach-Object {
                Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $stage $_.Name) -Force
            }
        }
    }

    return $stage
}

# ---------------------------------------------------------------------------
# Bootstrap templates (only fill missing files)
# ---------------------------------------------------------------------------
function Invoke-BootstrapTemplates {
    param(
        [Parameter(Mandatory)][string]$Frontend,
        [Parameter(Mandatory)][string]$TargetDir
    )
    if ($Frontend -eq 'none') { return }
    $tplDir = Join-Path $RepoDir "cmd/$Frontend"
    if (-not (Test-Path -LiteralPath $tplDir)) { return }

    $filterRel = Get-FrontendString -Entry (Get-FrontendEntry $Frontend) -Field 'bootstrap_filter'
    if (-not $filterRel) {
        throw "Missing bootstrap_filter for frontend '$Frontend'"
    }
    $filterPath = ConvertTo-NativePath $filterRel
    if (-not (Test-Path -LiteralPath $filterPath)) {
        throw "Bootstrap filter file not found: $filterPath"
    }

    if ($DryRun) {
        Write-Log -Level info "(dry-run) init templates: $Frontend -> $TargetDir (only missing files)"
        Copy-FilteredTree -Source $tplDir -Destination $TargetDir -FilterFile $filterPath -IgnoreExisting
    } else {
        Copy-FilteredTree -Source $tplDir -Destination $TargetDir -FilterFile $filterPath -IgnoreExisting
        Write-Log -Level info "Initialized templates: $Frontend -> $TargetDir"
    }
}

# ---------------------------------------------------------------------------
# Path overlap validation
# ---------------------------------------------------------------------------
function Test-PathOverlap {
    param(
        [Parameter(Mandatory)][string]$A,
        [Parameter(Mandatory)][string]$B
    )
    $a = [IO.Path]::GetFullPath($A).TrimEnd('\','/')
    $b = [IO.Path]::GetFullPath($B).TrimEnd('\','/')
    $cmp = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if ([string]::Equals($a, $b, $cmp)) { return $true }
    if ($a.StartsWith($b + [IO.Path]::DirectorySeparatorChar, $cmp)) { return $true }
    if ($b.StartsWith($a + [IO.Path]::DirectorySeparatorChar, $cmp)) { return $true }
    return $false
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
function Assert-OptionConflicts {
    if ($CloudSync) {
        Fail '-CloudSync is not supported on this entry: the iCloud <-> OneDrive bridge runs only on macOS via cmd/sync-userdict.sh (bash + Unison). Windows syncs directly to its local OneDrive folder via the Rime sync_dir.'
    }
    if ($SyncOnly) {
        $bad = @()
        if ($Init) { $bad += '-Init' }
        if ($Delete) { $bad += '-Delete' }
        if ($Target) { $bad += '-Target' }
        if ($NoDownload) { $bad += '-NoDownload' }
        if ($NoSync) { $bad += '-NoSync' }
        if ($bad.Count -gt 0) {
            Fail "-SyncOnly cannot be combined with: $($bad -join ' ')"
        }
    }
}

function Invoke-SyncOnly {
    $frontends = Get-ActiveFrontends
    $desktop = [System.Collections.Generic.List[string]]::new()
    foreach ($f in $frontends) {
        $cmd = Get-FrontendCommand (Get-Prop (Get-FrontendEntry $f) 'sync_cmd')
        if ($null -ne $cmd) { $desktop.Add($f) }
    }
    if ($desktop.Count -eq 0) {
        Fail '没有可调用的桌面 Rime 同步命令（active 前端均未配置 sync_cmd）；sync-only 未完成'
    }

    # 预检：可执行文件必须可解析（在任何副作用前）
    $commands = @{}
    foreach ($f in $desktop) {
        $cmd = Get-FrontendCommand (Get-Prop (Get-FrontendEntry $f) 'sync_cmd')
        $exe = Resolve-CommandExecutable -Exe $cmd.Executable
        if (-not $exe) { exit 1 }
        $commands[$f] = @{ Executable = $exe; Arguments = @($cmd.Arguments) }
    }

    foreach ($f in $desktop) {
        $cmd = $commands[$f]
        if ($DryRun) {
            Write-Log -Level info "(dry-run) 将调用 [$f]: $($cmd.Executable) $($cmd.Arguments -join ' ')"
            continue
        }
        if (Invoke-FrontendCommand -Frontend $f -Stage 'Rime 同步' -Command $cmd) {
            Report-SyncSubmission -Exe $cmd.Executable
        }
    }

    if ($script:HookFailures.Count -gt 0) {
        Write-Log -Level error '失败的阶段 (frontend|stage|exit):'
        $script:HookFailures | ForEach-Object { Write-Host "  $_" }
        exit 1
    }
    exit 0
}

function Invoke-Update {
    $frontends = Get-ActiveFrontends
    if ($frontends.Count -eq 0) {
        Fail "No active frontends found. Set `"active`": true in $ConfigPath"
    }

    Write-Log -Level info "Active frontends: $($frontends -join ' ')"

    # P3.4：目标解析/冲突/重叠校验在任何 build 目录创建、下载或目标写入之前完成
    # Resolve targets
    $targets = @{}
    foreach ($f in $frontends) {
        $entry = Get-FrontendEntry $f
        $targetDir = $Target
        if (-not $targetDir) {
            $targetDir = ConvertTo-NativePath (Get-FrontendString -Entry $entry -Field 'target_dir')
        }
        if (-not $targetDir) {
            Fail "Missing target for frontend '$f' (use -Target or set target_dir in the config)"
        }
        $targets[$f] = $targetDir
    }

    # Validations before any target write / target directory creation
    if ($Target -and $frontends.Count -gt 1) {
        Fail "-Target 只允许单一 active 前端（当前 active: $($frontends -join ' ')）"
    }
    if ($Target -and -not $DryRun -and ($FlagRedeploy -or $FlagSync)) {
        Fail '非 dry-run 使用 -Target 覆盖目标时必须同时 -NoRedeploy -NoSync（避免复制到沙盒目标却触发真实输入法）'
    }
    # 先规范化绝对路径（解析 .. 与重复分隔符），再按平台语义比较，避免等价路径逃逸重复目标检测
    $pathCompare = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $normalizedTargets = @{}
    foreach ($f in $frontends) {
        $normalizedTargets[$f] = [IO.Path]::GetFullPath($targets[$f]).TrimEnd('\','/')
    }
    $names = @($normalizedTargets.Keys)
    for ($i = 0; $i -lt $names.Count; $i++) {
        for ($j = $i + 1; $j -lt $names.Count; $j++) {
            if ([string]::Equals($normalizedTargets[$names[$i]], $normalizedTargets[$names[$j]], $pathCompare)) {
                Fail "frontends '$($names[$i])' 与 '$($names[$j])' 解析到同一目标目录：$($targets[$names[$i]]) (normalized: $($normalizedTargets[$names[$i]]))"
            }
        }
    }
    foreach ($f in $frontends) {
        $stage = Join-Path $StageRoot $f
        $tplDir = Join-Path $RepoDir "cmd/$f"
        if (Test-PathOverlap $stage $targets[$f]) {
            Fail "拒绝：stage 目录与目标重叠 (stage: $stage, target: $($targets[$f]))"
        }
        if (Test-PathOverlap $tplDir $targets[$f]) {
            Fail "拒绝：前端模板目录与目标重叠 (tpl: $tplDir, target: $($targets[$f]))"
        }
        if (Test-PathOverlap $UpstreamDir $targets[$f]) {
            Fail "拒绝：upstream 目录与目标重叠 (upstream: $UpstreamDir, target: $($targets[$f]))"
        }
    }

    # R2：对本次实际启用的 hooks 一次性预检可执行文件（在任何写入之前）；
    # 关闭的 hook 不要求存在。结果复用到主循环。
    $redeployExes = @{}
    $syncExes = @{}
    if (-not $DryRun) {
        foreach ($f in $frontends) {
            $entry = Get-FrontendEntry $f
            if ($FlagRedeploy) {
                $redeployCmd = Get-FrontendCommand (Get-Prop $entry 'redeploy_cmd')
                if ($null -ne $redeployCmd) {
                    $exe = Resolve-CommandExecutable -Exe $redeployCmd.Executable
                    if (-not $exe) { exit 1 }
                    $redeployExes[$f] = $exe
                }
            }
            if ($FlagSync) {
                $syncCmd = Get-FrontendCommand (Get-Prop $entry 'sync_cmd')
                if ($null -ne $syncCmd) {
                    $exe = Resolve-CommandExecutable -Exe $syncCmd.Executable
                    if (-not $exe) { exit 1 }
                    $syncExes[$f] = $exe
                }
            }
        }
    }

    Initialize-BuildDirs

    if (-not $NoDownload) {
        Update-UpstreamCache
    } else {
        $upstreamEmpty = -not (Test-Path -LiteralPath $UpstreamDir) -or -not (Get-ChildItem -LiteralPath $UpstreamDir -Force -ErrorAction SilentlyContinue)
        if ($upstreamEmpty) {
            Fail '-NoDownload set but build/upstream is empty'
        }
    }

    foreach ($frontend in $frontends) {
        Write-Log -Level info "=== Processing frontend: $frontend ==="
        $entry = Get-FrontendEntry $frontend

        $uiLayer = Get-FrontendString -Entry $entry -Field 'ui_layer' -Default 'none'
        $targetDir = $targets[$frontend]

        if ($Init) {
            Invoke-BootstrapTemplates -Frontend $frontend -TargetDir $targetDir
        }

        $stage = Build-StageDirectory -Frontend $frontend -UiLayer $uiLayer

        $filterRel = Get-FrontendString -Entry $entry -Field 'rsync_filter'
        if (-not $filterRel) { throw "Missing rsync_filter for frontend '$frontend'" }
        $filterPath = ConvertTo-NativePath $filterRel
        if (-not (Test-Path -LiteralPath $filterPath)) { throw "Rsync filter file not found: $filterPath" }

        Write-Log -Level info "Stage -> $frontend : $targetDir"
        Copy-FilteredTree -Source $stage -Destination $targetDir -FilterFile $filterPath -DeleteExtra:$FlagDelete

        # Post-update hooks（可执行文件已在上方预检并复用）
        if (-not $DryRun) {
            $redeployCmd = Get-FrontendCommand (Get-Prop $entry 'redeploy_cmd')
            if ($FlagRedeploy -and $null -ne $redeployCmd -and $redeployExes.ContainsKey($frontend)) {
                $cmd = @{ Executable = $redeployExes[$frontend]; Arguments = @($redeployCmd.Arguments) }
                if (Invoke-FrontendCommand -Frontend $frontend -Stage 'redeploy' -Command $cmd) { }
            }

            $syncCmd = Get-FrontendCommand (Get-Prop $entry 'sync_cmd')
            if ($FlagSync -and $null -ne $syncCmd -and $syncExes.ContainsKey($frontend)) {
                $cmd = @{ Executable = $syncExes[$frontend]; Arguments = @($syncCmd.Arguments) }
                if (Invoke-FrontendCommand -Frontend $frontend -Stage 'Rime 同步' -Command $cmd) {
                    Report-SyncSubmission -Exe $cmd.Executable
                }
            }
        }

        Write-Log -Level info "=== Completed: $frontend ==="
    }

    if ($DryRun) {
        Write-Log -Level info '(dry-run) 未写入目标、未生成用户短语文件、未调用 redeploy/sync'
    }
    if ($script:HookFailures.Count -gt 0) {
        Write-Log -Level error '失败的阶段 (frontend|stage|exit):'
        $script:HookFailures | ForEach-Object { Write-Host "  $_" }
        exit 1
    }
    exit 0
}

# ---------------------------------------------------------------------------
# Entry
# ---------------------------------------------------------------------------
Assert-OptionConflicts

try {
    $script:FrontendsConfig = Get-FrontendsConfig -Path $ConfigPath
} catch {
    Fail $_.Exception.Message
}

if ($SyncOnly) {
    Invoke-SyncOnly
}

Invoke-Update
