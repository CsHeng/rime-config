#Requires -Version 7.0
<#
.SYNOPSIS
  Rime configuration updater — PowerShell 7 port of update.sh (no rsync dependency).
.DESCRIPTION
  Downloads upstream schema/dicts/grammar, merges with local overlays,
  and syncs to each active frontend's target directory using native file operations.
#>

[CmdletBinding()]
param(
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
$ConfigYaml = Join-Path $ScriptDir 'frontends.yaml'

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

# ---------------------------------------------------------------------------
# .env loader
# ---------------------------------------------------------------------------
function Import-DotEnv {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return }
    Get-Content $Path | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith('#')) {
            if ($line -match '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
                [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2].Trim('"').Trim("'"), 'Process')
            }
        }
    }
}

Import-DotEnv (Join-Path $ScriptDir '.env')

# ---------------------------------------------------------------------------
# YAML accessors (yq wrapper)
# ---------------------------------------------------------------------------
function Invoke-Yq {
    param(
        [Parameter(Mandatory)][string]$Expression,
        [string]$File = $ConfigYaml,
        [hashtable]$EnvVars = @{}
    )
    if (-not (Get-Command yq -ErrorAction SilentlyContinue)) {
        throw 'Missing dependency: yq (mikefarah/yq v4)'
    }
    $env = [System.Collections.Generic.Dictionary[string,string]]::new()
    $EnvVars.GetEnumerator() | ForEach-Object { $env[$_.Key] = $_.Value }
    $result = & {
        foreach ($kv in $env.GetEnumerator()) {
            [Environment]::SetEnvironmentVariable($kv.Key, $kv.Value, 'Process')
        }
        yq e $Expression $File 2>&1
    }
    foreach ($kv in $env.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable($kv.Key, $null, 'Process')
    }
    if ($LASTEXITCODE -ne 0) {
        throw "yq failed: $result"
    }
    return $result
}

function ConvertTo-NativePath {
    <#
    .SYNOPSIS
      Converts /c/Users/... to C:\Users\... and ~/... to $HOME/... on Windows.
    #>
    param([string]$Path)
    if (-not $Path) { return $Path }
    # Expand ~ to $HOME
    if ($Path.StartsWith('~/') -or $Path -eq '~') {
        $Path = $Path -replace '^~', $HOME
    }
    # /c/... -> C:\...
    if ($IsWindows -and $Path -match '^/([a-zA-Z])/(.*)$') {
        $drive = $Matches[1].ToUpper()
        $rest  = $Matches[2] -replace '/', '\'
        return "${drive}:\$rest"
    }
    return $Path
}

function Get-AutoFrontend {
    if (-not (Test-Path $ConfigYaml)) { return 'none' }
    if ($IsWindows) {
        return (Invoke-Yq -Expression '.auto.windows // "none"').Trim()
    } elseif ($IsMacOS) {
        return (Invoke-Yq -Expression '.auto.darwin // "none"').Trim()
    }
    return 'none'
}

function Get-ActiveFrontends {
    if (-not (Test-Path $ConfigYaml)) { return @() }
    $auto = Get-AutoFrontend
    $trueList = @((Invoke-Yq -Expression '.frontends | to_entries[] | select(.value.active == true) | .key') -split "`n" | Where-Object { $_ -and $_ -ne '---' })
    $autoList = @((Invoke-Yq -Expression '.frontends | to_entries[] | select(.value.active == "auto") | .key') -split "`n" | Where-Object { $_ -and $_ -ne '---' })
    $result = [System.Collections.Generic.List[string]]::new()
    $trueList | ForEach-Object { if ($_ -and $_ -notin $result) { $result.Add($_) } }
    if ($auto -ne 'none' -and $auto -in $autoList -and $auto -notin $result) {
        $result.Add($auto)
    }
    return $result
}

function Get-FrontendProperty {
    param(
        [Parameter(Mandatory)][string]$Frontend,
        [Parameter(Mandatory)][string]$Property,
        [string]$Default = ''
    )
    if (-not (Test-Path $ConfigYaml)) { return $Default }
    $expr = ".frontends[strenv(F)].$Property // `"$Default`""
    $val = (Invoke-Yq -Expression $expr -EnvVars @{F=$Frontend}).Trim()
    if ($val -eq 'null' -or -not $val) { return $Default }
    return $val
}

# ---------------------------------------------------------------------------
# rsync filter engine
# ---------------------------------------------------------------------------
function ConvertFrom-RsyncFilter {
    <#
    .SYNOPSIS
      Parses an rsync filter file into a list of rule objects.
    .DESCRIPTION
      Supported pattern syntax (covers all patterns in this project):
        + filename       — include exact filename
        - filename       — exclude exact filename
        - dir/           — exclude directory by name
        - dir/**         — exclude everything under dir/
        - **.userdb/     — exclude any path segment matching *.userdb
        - *              — exclude everything (catch-all)
        + *              — include everything (catch-all)
        - "quoted name"  — exclude with quoted filename
        + "quoted name"  — include with quoted filename
    #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { throw "Filter file not found: $Path" }
    $rules = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($raw in (Get-Content $Path)) {
        $line = $raw.Trim()
        if (-not $line -or $line.StartsWith('#')) { continue }
        if ($line -match '^([+-])\s+(.+)$') {
            $action  = if ($Matches[1] -eq '+') { 'include' } else { 'exclude' }
            $pattern = $Matches[2].Trim('"')
            $rules.Add([PSCustomObject]@{
                Action  = $action
                Pattern = $pattern
                Raw     = $line
            })
        }
    }
    return $rules
}

function Test-RsyncFilter {
    <#
    .SYNOPSIS
      Tests a relative path against rsync filter rules. Returns 'include', 'exclude', or 'no-match'.
    .DESCRIPTION
      First-match-wins semantics (same as rsync).
      $RelativePath uses '/' separators, no leading '/'.
      $IsDirectory should be $true for directories.
    #>
    param(
        [Parameter(Mandatory)][System.Collections.Generic.List[PSCustomObject]]$Rules,
        [Parameter(Mandatory)][string]$RelativePath,
        [bool]$IsDirectory = $false
    )
    foreach ($rule in $Rules) {
        $p = $rule.Pattern
        $matched = $false

        if ($p -eq '*') {
            # Catch-all
            $matched = $true
        }
        elseif ($p.StartsWith('**') -and $p.EndsWith('/')) {
            # **.userdb/ — match any path segment like *.userdb (directory only)
            $segPattern = $p.TrimStart('*').TrimEnd('/')  # e.g. '.userdb'
            if ($IsDirectory) {
                $segments = $RelativePath -split '/'
                foreach ($seg in $segments) {
                    if ($seg -like "*$segPattern") { $matched = $true; break }
                }
            }
        }
        elseif ($p.EndsWith('/**')) {
            # dir/** — match anything under dir/
            $prefix = $p.Substring(0, $p.Length - 3)  # e.g. 'build'
            if ($RelativePath.StartsWith("$prefix/") -or $RelativePath -eq $prefix) {
                $matched = $true
            }
        }
        elseif ($p.EndsWith('/')) {
            # dir/ — match directory by name (top-level segment)
            $dirName = $p.TrimEnd('/')
            if ($IsDirectory) {
                $segments = $RelativePath -split '/'
                if ($dirName -in $segments) { $matched = $true }
            }
        }
        else {
            # Exact filename match (basename only, like rsync default)
            $baseName = Split-Path $RelativePath -Leaf
            if ($baseName -eq $p) { $matched = $true }
        }

        if ($matched) { return $rule.Action }
    }
    return 'no-match'
}

# ---------------------------------------------------------------------------
# File copy functions (rsync replacements)
# ---------------------------------------------------------------------------
function Copy-SingleFile {
    <#
    .SYNOPSIS
      Copies a single file to a destination directory (like rsync -a <file> <dest>/).
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )
    if (-not (Test-Path $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }
    $destFile = Join-Path $Destination (Split-Path $Source -Leaf)
    if ($DryRun) {
        Write-Log -Level info "  [dry-run] copy: $(Split-Path $Source -Leaf)"
        return
    }
    Copy-Item -Path $Source -Destination $destFile -Force
}

function Copy-DirectoryContents {
    <#
    .SYNOPSIS
      Recursively copies directory contents (like rsync -a <src>/ <dst>/).
      Excludes .DS_Store by default.
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [switch]$ExcludeDSStore
    )
    if (-not (Test-Path $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }
    $items = Get-ChildItem -Path $Source -Recurse -Force
    if ($ExcludeDSStore) {
        $items = $items | Where-Object { $_.Name -ne '.DS_Store' }
    }
    foreach ($item in $items) {
        $relPath = $item.FullName.Substring($Source.TrimEnd([IO.Path]::DirectorySeparatorChar, '/').Length + 1)
        $destPath = Join-Path $Destination $relPath
        if ($item.PSIsContainer) {
            if (-not (Test-Path $destPath)) {
                New-Item -ItemType Directory -Path $destPath -Force | Out-Null
            }
        } else {
            $destDir = Split-Path $destPath -Parent
            if (-not (Test-Path $destDir)) {
                New-Item -ItemType Directory -Path $destDir -Force | Out-Null
            }
            if ($DryRun) {
                Write-Log -Level info "  [dry-run] copy: $relPath"
            } else {
                Copy-Item -Path $item.FullName -Destination $destPath -Force
            }
        }
    }
}

function Copy-FilteredTree {
    <#
    .SYNOPSIS
      Syncs source directory to destination using rsync filter rules.
      Replaces: rsync -a --filter="merge <file>" [--delete] [--ignore-existing] <src>/ <dst>/
    .PARAMETER FilterFile
      Path to rsync filter file.
    .PARAMETER DeleteExtra
      When set, removes files in destination that are not in source AND are allowed by filter rules.
      Files excluded by filter rules are never deleted (matches rsync --delete behavior).
    .PARAMETER IgnoreExisting
      When set, skips files that already exist in destination (matches rsync --ignore-existing).
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$FilterFile,
        [switch]$DeleteExtra,
        [switch]$IgnoreExisting
    )

    $rules = ConvertFrom-RsyncFilter -Path $FilterFile
    $srcRoot = $Source.TrimEnd([IO.Path]::DirectorySeparatorChar, '/')

    if (-not (Test-Path $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }
    $dstRoot = $Destination.TrimEnd([IO.Path]::DirectorySeparatorChar, '/')

    # --- Phase 1: Copy source -> destination (respecting filter) ---
    $srcItems = Get-ChildItem -Path $srcRoot -Recurse -Force
    foreach ($item in $srcItems) {
        $relPath = $item.FullName.Substring($srcRoot.Length + 1) -replace '\\', '/'
        $isDir = $item.PSIsContainer
        $verdict = Test-RsyncFilter -Rules $rules -RelativePath $relPath -IsDirectory $isDir

        # .DS_Store always excluded
        if ($item.Name -eq '.DS_Store') { continue }

        if ($verdict -eq 'exclude') { continue }
        # 'include' or 'no-match' (rsync default: include if no rule matches)

        $destPath = Join-Path $dstRoot ($relPath -replace '/', [IO.Path]::DirectorySeparatorChar)
        if ($isDir) {
            if (-not (Test-Path $destPath)) {
                if ($DryRun) {
                    Write-Log -Level info "  [dry-run] mkdir: $relPath/"
                } else {
                    New-Item -ItemType Directory -Path $destPath -Force | Out-Null
                }
            }
        } else {
            if ($IgnoreExisting -and (Test-Path $destPath)) { continue }
            $destDir = Split-Path $destPath -Parent
            if (-not (Test-Path $destDir)) {
                if (-not $DryRun) {
                    New-Item -ItemType Directory -Path $destDir -Force | Out-Null
                }
            }
            if ($DryRun) {
                Write-Log -Level info "  [dry-run] copy: $relPath"
            } else {
                Copy-Item -Path $item.FullName -Destination $destPath -Force
            }
        }
    }

    # --- Phase 2: Delete extra files in destination (if requested) ---
    if ($DeleteExtra -and (Test-Path $dstRoot)) {
        # Collect destination items, process files first then directories (deepest first)
        $dstItems = Get-ChildItem -Path $dstRoot -Recurse -Force | Sort-Object { $_.FullName.Length } -Descending
        foreach ($item in $dstItems) {
            $relPath = $item.FullName.Substring($dstRoot.Length + 1) -replace '\\', '/'
            $isDir = $item.PSIsContainer
            $verdict = Test-RsyncFilter -Rules $rules -RelativePath $relPath -IsDirectory $isDir

            # Only delete files that the filter would allow syncing (not excluded)
            if ($verdict -eq 'exclude') { continue }

            $srcPath = Join-Path $srcRoot ($relPath -replace '/', [IO.Path]::DirectorySeparatorChar)
            if (-not (Test-Path $srcPath)) {
                if ($DryRun) {
                    $kind = if ($isDir) { 'rmdir' } else { 'delete' }
                    Write-Log -Level info "  [dry-run] $kind`: $relPath"
                } else {
                    if ($isDir) {
                        # Only remove if empty (files inside may be excluded)
                        if (-not (Get-ChildItem -Path $item.FullName -Force)) {
                            Remove-Item -Path $item.FullName -Force
                        }
                    } else {
                        Remove-Item -Path $item.FullName -Force
                    }
                }
            }
        }
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
    $response = Invoke-RestMethod -Uri $url -Headers $headers -ErrorAction Stop
    return $response
}

function Find-GitHubAsset {
    <#
    .SYNOPSIS
      Finds a release asset. Returns [PSCustomObject]@{Tag; Version; Url}.
    #>
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
    if (-not (Test-Path $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }
    Expand-Archive -Path $ZipPath -DestinationPath $Destination -Force
}

function Expand-ZipFlatten {
    <#
    .SYNOPSIS
      Extracts zip and flattens files from up to depth 2 into destination.
    #>
    param(
        [Parameter(Mandatory)][string]$ZipPath,
        [Parameter(Mandatory)][string]$Destination
    )
    $tmpExtract = Join-Path $TmpDir "extract_$PID"
    if (Test-Path $tmpExtract) { Remove-Item -Path $tmpExtract -Recurse -Force }
    New-Item -ItemType Directory -Path $tmpExtract -Force | Out-Null
    if (-not (Test-Path $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }
    Expand-Archive -Path $ZipPath -DestinationPath $tmpExtract -Force
    Get-ChildItem -Path $tmpExtract -Recurse -File -Depth 2 | ForEach-Object {
        Copy-Item -Path $_.FullName -Destination (Join-Path $Destination $_.Name) -Force
    }
    Remove-Item -Path $tmpExtract -Recurse -Force
}

# ---------------------------------------------------------------------------
# Markers
# ---------------------------------------------------------------------------
function Get-Marker {
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path $Path) { return (Get-Content $Path -Raw).Trim() }
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
        if (-not (Test-Path $_)) { New-Item -ItemType Directory -Path $_ -Force | Out-Null }
    }
}

function Update-UpstreamCache {
    Initialize-BuildDirs

    $schemaRepo  = 'amzxyz/rime_wanxiang'

    # --- schema ---
    $schemaAsset  = 'rime-wanxiang-base.zip'
    $schemaMarker = Join-Path $MarkersDir 'schema_version'
    $schemaZip    = Join-Path $CacheDir $schemaAsset

    $schemaInfo    = Find-GitHubAsset -Repo $schemaRepo -TagPrefix 'v' -AssetName $schemaAsset -VersionMode tag
    $schemaStored  = Get-Marker -Path $schemaMarker
    $upstreamEmpty = -not (Test-Path $UpstreamDir) -or -not (Get-ChildItem $UpstreamDir -Force -ErrorAction SilentlyContinue)

    if ($schemaInfo.Version -ne $schemaStored -or $upstreamEmpty) {
        Save-Download -Url $schemaInfo.Url -OutFile $schemaZip
        if (Test-Path $UpstreamDir) { Remove-Item -Path $UpstreamDir -Recurse -Force }
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

    if ($dictsInfo.Version -ne $dictsStored -or -not (Test-Path $dictsDir)) {
        Save-Download -Url $dictsInfo.Url -OutFile $dictsZip
        if (Test-Path $dictsDir) { Remove-Item -Path $dictsDir -Recurse -Force }
        New-Item -ItemType Directory -Path $dictsDir -Force | Out-Null
        Write-Log -Level info 'Extracting dicts -> build/upstream/dicts/'
        Expand-ZipFlatten -ZipPath $dictsZip -Destination $dictsDir
        Set-Marker -Path $dictsMarker -Value $dictsInfo.Version
    } else {
        Write-Log -Level info "Dicts up to date: $($dictsInfo.Version)"
    }

    # --- grammar ---
    $grammarRepo   = 'amzxyz/RIME-LMDG'
    $grammarAsset  = 'wanxiang-lts-zh-hans.gram'
    $grammarMarker = Join-Path $MarkersDir 'grammar_version'
    $grammarFile   = Join-Path $CacheDir $grammarAsset
    $grammarDest   = Join-Path $UpstreamDir $grammarAsset

    $grammarInfo   = Find-GitHubAsset -Repo $grammarRepo -TagPrefix 'LTS' -AssetName $grammarAsset -VersionMode asset_updated_at
    $grammarStored = Get-Marker -Path $grammarMarker

    if ($grammarInfo.Version -ne $grammarStored -or -not (Test-Path $grammarDest)) {
        Save-Download -Url $grammarInfo.Url -OutFile $grammarFile
        Write-Log -Level info "Updating grammar -> build/upstream/$grammarAsset"
        Copy-Item -Path $grammarFile -Destination $grammarDest -Force
        Set-Marker -Path $grammarMarker -Value $grammarInfo.Version
    } else {
        Write-Log -Level info "Grammar up to date: $($grammarInfo.Version)"
    }
}

# ---------------------------------------------------------------------------
# Build: stage directory
# ---------------------------------------------------------------------------
function Build-StageDirectory {
    param(
        [Parameter(Mandatory)][string]$Frontend,
        [string]$UiLayer = 'none'
    )
    $stage = Join-Path $StageRoot $Frontend
    if (Test-Path $stage) { Remove-Item -Path $stage -Recurse -Force }
    New-Item -ItemType Directory -Path $stage -Force | Out-Null

    if ($Frontend -ne 'none') {
        # upstream -> stage (exclude .DS_Store)
        Copy-DirectoryContents -Source $UpstreamDir -Destination $stage -ExcludeDSStore
    }

    # local layer (repo tracked)
    $customPhrase = Join-Path $RepoDir 'custom_phrase_user.txt'
    if (Test-Path $customPhrase) {
        Copy-SingleFile -Source $customPhrase -Destination $stage
    }
    Get-ChildItem -Path $RepoDir -Filter '*.custom.yaml' -File | ForEach-Object {
        Copy-SingleFile -Source $_.FullName -Destination $stage
    }

    # UI overlays
    if ($UiLayer -and $UiLayer -ne 'none') {
        $commonDefault = Join-Path $RepoDir 'cmd/common/default.custom.yaml'
        if (Test-Path $commonDefault) {
            Copy-Item -Path $commonDefault -Destination (Join-Path $stage 'default.custom.yaml') -Force
        }
        $tplDir = Join-Path $RepoDir "cmd/$UiLayer"
        if (Test-Path $tplDir) {
            Get-ChildItem -Path $tplDir -Filter '*.custom.yaml' -File | ForEach-Object {
                Copy-Item -Path $_.FullName -Destination (Join-Path $stage $_.Name) -Force
            }
        }
    }

    return $stage
}

# ---------------------------------------------------------------------------
# Bootstrap templates
# ---------------------------------------------------------------------------
function Invoke-BootstrapTemplates {
    param(
        [Parameter(Mandatory)][string]$Frontend,
        [Parameter(Mandatory)][string]$TargetDir
    )
    if ($Frontend -eq 'none') { return }
    $tplDir = Join-Path $RepoDir "cmd/$Frontend"
    if (-not (Test-Path $tplDir)) { return }

    $filterRel = Get-FrontendProperty -Frontend $Frontend -Property 'bootstrap_filter'
    if (-not $filterRel) {
        Write-Log -Level error "Missing bootstrap filter for frontend '$Frontend'"
        return
    }
    $filterPath = Join-Path $RepoDir $filterRel
    if (-not (Test-Path $filterPath)) {
        Write-Log -Level error "Missing bootstrap filter file: $filterRel"
        return
    }

    if (-not (Test-Path $TargetDir)) {
        New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
    }
    Copy-FilteredTree -Source $tplDir -Destination $TargetDir -FilterFile $filterPath -IgnoreExisting
    Write-Log -Level info "Initialized templates: $Frontend -> $TargetDir"
}

# ---------------------------------------------------------------------------
# Sync stage -> target
# ---------------------------------------------------------------------------
function Sync-StageToTarget {
    param(
        [Parameter(Mandatory)][string]$Frontend,
        [Parameter(Mandatory)][string]$Stage,
        [Parameter(Mandatory)][string]$TargetDir
    )
    $filterRel = Get-FrontendProperty -Frontend $Frontend -Property 'rsync_filter'
    if (-not $filterRel) {
        throw "Missing rsync_filter for frontend '$Frontend'"
    }
    $filterPath = Join-Path $RepoDir $filterRel
    if (-not (Test-Path $filterPath)) {
        throw "Missing rsync filter file: $filterRel"
    }

    if (-not (Test-Path $TargetDir)) {
        New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
    }

    # Safety: refuse if source and destination resolve to the same path
    $srcResolved = (Resolve-Path $Stage -ErrorAction SilentlyContinue).Path
    $dstResolved = (Resolve-Path $TargetDir -ErrorAction SilentlyContinue).Path
    if ($srcResolved -and $dstResolved -and $srcResolved -eq $dstResolved) {
        throw "Refusing to sync: source and destination resolve to the same path`n  src: $Stage`n  dst: $TargetDir"
    }

    Write-Log -Level info "Stage -> $Frontend : $TargetDir"
    Copy-FilteredTree -Source $Stage -Destination $TargetDir -FilterFile $filterPath -DeleteExtra:$FlagDelete
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
function Invoke-Update {
    $activeFrontends = Get-ActiveFrontends
    if (-not $activeFrontends -or $activeFrontends.Count -eq 0) {
        Write-Log -Level error 'No active frontends found. Configure active: true in cmd/frontends.yaml'
        exit 1
    }

    Write-Log -Level info "Active frontends: $($activeFrontends -join ' ')"
    Initialize-BuildDirs

    if (-not $NoDownload) {
        Update-UpstreamCache
    } else {
        $upstreamEmpty = -not (Test-Path $UpstreamDir) -or -not (Get-ChildItem $UpstreamDir -Force -ErrorAction SilentlyContinue)
        if ($upstreamEmpty) {
            Write-Log -Level error '--NoDownload set but build/upstream is empty'
            exit 1
        }
    }

    foreach ($frontend in $activeFrontends) {
        Write-Log -Level info "=== Processing frontend: $frontend ==="

        $uiLayer = Get-FrontendProperty -Frontend $frontend -Property 'ui_layer' -Default 'none'

        # Resolve target directory
        $targetDir = $Target
        if (-not $targetDir) {
            $rawTarget = Get-FrontendProperty -Frontend $frontend -Property 'target_dir'
            $targetDir = ConvertTo-NativePath $rawTarget
        }
        if (-not $targetDir) {
            Write-Log -Level error "Missing target for frontend '$frontend' (use -Target or set in cmd/frontends.yaml)"
            continue
        }

        if ($Init) {
            Invoke-BootstrapTemplates -Frontend $frontend -TargetDir $targetDir
        }

        $stage = Build-StageDirectory -Frontend $frontend -UiLayer $uiLayer
        Sync-StageToTarget -Frontend $frontend -Stage $stage -TargetDir $targetDir

        # Post-update hooks
        if (-not $DryRun) {
            $redeployCmd = Get-FrontendProperty -Frontend $frontend -Property 'redeploy_cmd'
            $syncCmd     = Get-FrontendProperty -Frontend $frontend -Property 'sync_cmd'

            if ($FlagRedeploy -and $redeployCmd) {
                Write-Log -Level info "Triggering redeploy: $redeployCmd"
                try { Invoke-Expression $redeployCmd }
                catch { Write-Log -Level warn "Redeploy command failed: $_" }
            }

            if ($FlagSync -and $syncCmd) {
                Write-Log -Level info "Triggering sync: $syncCmd"
                try { Invoke-Expression $syncCmd }
                catch { Write-Log -Level warn "Sync command failed: $_" }
            }
        }

        Write-Log -Level info "=== Completed: $frontend ==="
    }

    # Cloud sync (optional)
    if ($CloudSync) {
        $syncScript = Join-Path $ScriptDir 'sync-userdict.ps1'
        if (Test-Path $syncScript) {
            $syncArgs = @()
            if ($DryRun) { $syncArgs += '-DryRun' }
            & $syncScript @syncArgs
        } else {
            Write-Log -Level warn 'sync-userdict.ps1 not found, skipping cloud sync'
        }
    }
}

Invoke-Update
