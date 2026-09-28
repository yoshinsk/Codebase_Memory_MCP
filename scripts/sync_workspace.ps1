# C:\Users\Yoshi\Documents\GitHub\Codebase_Memory_MCP\scripts\sync_workspace.ps1
# 指定ワークスペースのGitリポジトリを検証してから、codebase-memory-mcpへ逐次索引を依頼する。
#
# このスクリプトはMCP本体の代替ではない。MCPが持つ永続グラフ、差分索引、横断リンク機能に対し、
# 個人環境で管理するプロジェクト集合を明示し、安全な一括同期の入口を提供する。

[CmdletBinding()]
param(
    [Parameter()]
    [string]$WorkspaceFile = (Join-Path $PSScriptRoot '..\workspaces\jmrc-kinki.json'),

    [Parameter()]
    [string]$ExecutablePath,

    [Parameter()]
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ManifestProperty {
    param(
        [Parameter(Mandatory)] [object]$Object,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter()] [bool]$Required = $true
    )

    # PSCustomObjectの直接参照では、存在しないキーとnull値を区別できないため、
    # Propertiesコレクションでスキーマ違反を明示的に検出する。
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        if ($Required) {
            throw "ワークスペース定義に必須キー '$Name' がありません。"
        }
        return $null
    }
    return $property.Value
}

function Get-RequiredString {
    param(
        [Parameter(Mandatory)] [object]$Object,
        [Parameter(Mandatory)] [string]$Name
    )

    $value = Get-ManifestProperty -Object $Object -Name $Name
    if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)) {
        throw "ワークスペース定義の '$Name' は空でない文字列である必要があります。"
    }
    return $value.Trim()
}

function Resolve-ExistingDirectory {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$Label
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "$Label が存在するディレクトリではありません: $Path"
    }
    return [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Path).Path)
}

function Test-PathWithinRoot {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$Root
    )

    $normalizedPath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $normalizedRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $rootPrefix = "$normalizedRoot$([System.IO.Path]::DirectorySeparatorChar)"

    return $normalizedPath.Equals($normalizedRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
        $normalizedPath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-TrackedProjectStatistics {
    param([Parameter(Mandatory)] [string]$ProjectPath)

    # Git管理下の実ファイルだけを数える。MCP側の探索結果そのものではないため、
    # ここで得る値は索引見積り・異常検知に限定して使用する。
    $trackedPaths = @(git -C $ProjectPath ls-files)
    if ($LASTEXITCODE -ne 0) {
        throw "Git追跡ファイルの取得に失敗しました: $ProjectPath"
    }

    [int64]$bytes = 0
    [int]$files = 0
    foreach ($relativePath in $trackedPaths) {
        $candidate = Join-Path $ProjectPath $relativePath
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $bytes += (Get-Item -LiteralPath $candidate).Length
            $files++
        }
    }

    return [PSCustomObject]@{
        Files = $files
        Bytes = $bytes
    }
}

function Assert-RequiredCbmiIgnorePatterns {
    param(
        [Parameter(Mandatory)] [string]$ProjectId,
        [Parameter(Mandatory)] [string]$ProjectPath,
        [Parameter(Mandatory)] [object[]]$Patterns
    )

    # 機密性の高いファイルは、索引後のグラフや検索結果に残さない。ここで定義と
    # 実際の .cbmignore を照合し、除外漏れの状態では同期処理を始めない。
    if ($Patterns.Count -eq 0) {
        return
    }

    $ignorePath = Join-Path $ProjectPath '.cbmignore'
    if (-not (Test-Path -LiteralPath $ignorePath -PathType Leaf)) {
        throw "projects[$ProjectId] にはrequired_cbmignore_patternsがありますが、.cbmignoreがありません。"
    }
    $declaredPatterns = @(Get-Content -LiteralPath $ignorePath -Encoding UTF8 | ForEach-Object { $_.Trim() })
    foreach ($pattern in $Patterns) {
        if ($pattern -isnot [string] -or [string]::IsNullOrWhiteSpace($pattern)) {
            throw "projects[$ProjectId].required_cbmignore_patterns は空でない文字列の配列である必要があります。"
        }
        if ($declaredPatterns -notcontains $pattern.Trim()) {
            throw "projects[$ProjectId] の.cbmignoreに必須除外パターンがありません: $pattern"
        }
    }
}

function Invoke-CodebaseMemoryCli {
    param(
        [Parameter(Mandatory)] [string]$Binary,
        [Parameter(Mandatory)] [string[]]$Arguments,
        [Parameter(Mandatory)] [string]$Operation
    )

    & $Binary @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "codebase-memory-mcp の $Operation に失敗しました。終了コード: $LASTEXITCODE"
    }
}

function Restore-EnvironmentVariable {
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [bool]$Existed,
        [AllowNull()] [string]$Value
    )

    if ($Existed) {
        Set-Item -Path "Env:$Name" -Value $Value
    } else {
        Remove-Item -Path "Env:$Name" -ErrorAction SilentlyContinue
    }
}

$manifestPath = Resolve-Path -LiteralPath $WorkspaceFile -ErrorAction Stop
$manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $manifestPath | ConvertFrom-Json

if ((Get-ManifestProperty -Object $manifest -Name 'schema_version') -ne 1) {
    throw '対応していないワークスペース定義のschema_versionです。'
}

$workspaceId = Get-RequiredString -Object $manifest -Name 'id'
$allowedRoot = Resolve-ExistingDirectory -Path (Get-RequiredString -Object $manifest -Name 'allowed_root') -Label 'allowed_root'
$runtime = Get-ManifestProperty -Object $manifest -Name 'runtime'
$cacheDir = [System.IO.Path]::GetFullPath((Get-RequiredString -Object $runtime -Name 'cache_dir'))
$maxMemoryMb = Get-ManifestProperty -Object $runtime -Name 'max_memory_mb'
if ($maxMemoryMb -isnot [long] -and $maxMemoryMb -isnot [int] -and $maxMemoryMb -isnot [double]) {
    throw 'runtime.max_memory_mb は整数である必要があります。'
}
$maxMemoryMb = [int]$maxMemoryMb
if ($maxMemoryMb -lt 256) {
    throw 'runtime.max_memory_mb は256 MiB以上にしてください。'
}

$projectDefinitions = @(Get-ManifestProperty -Object $manifest -Name 'projects')
if ($projectDefinitions.Count -eq 0) {
    throw 'projectsには少なくとも1件のリポジトリが必要です。'
}

$projects = @()
$projectIds = @{}
$projectPaths = @{}
foreach ($definition in $projectDefinitions) {
    $projectId = Get-RequiredString -Object $definition -Name 'id'
    if ($projectIds.ContainsKey($projectId)) {
        throw "projects.id が重複しています: $projectId"
    }

    $projectPath = Resolve-ExistingDirectory -Path (Get-RequiredString -Object $definition -Name 'path') -Label "projects[$projectId].path"
    if (-not (Test-PathWithinRoot -Path $projectPath -Root $allowedRoot)) {
        throw "projects[$projectId].path はallowed_rootと同一または配下でなければなりません: $projectPath"
    }
    if (-not (Test-Path -LiteralPath (Join-Path $projectPath '.git'))) {
        throw "projects[$projectId].path はGitリポジトリではありません: $projectPath"
    }
    if ($projectPaths.ContainsKey($projectPath)) {
        throw "projects.path が重複しています: $projectPath"
    }

    $indexMode = Get-RequiredString -Object $definition -Name 'index_mode'
    if ($indexMode -notin @('full', 'moderate', 'fast')) {
        throw "projects[$projectId].index_mode はfull、moderate、fastのいずれかです。"
    }

    $persistence = Get-ManifestProperty -Object $definition -Name 'persistence'
    if ($persistence -isnot [bool]) {
        throw "projects[$projectId].persistence はbooleanである必要があります。"
    }

    $rawRequiredIgnorePatterns = Get-ManifestProperty -Object $definition -Name 'required_cbmignore_patterns' -Required $false
    $requiredIgnorePatterns = if ($null -eq $rawRequiredIgnorePatterns) { @() } else { @($rawRequiredIgnorePatterns) }
    Assert-RequiredCbmiIgnorePatterns -ProjectId $projectId -ProjectPath $projectPath -Patterns $requiredIgnorePatterns

    $targets = @()
    $rawTargets = Get-ManifestProperty -Object $definition -Name 'cross_repo_targets' -Required $false
    $targetDefinitions = if ($null -eq $rawTargets) { @() } else { @($rawTargets) }
    foreach ($target in $targetDefinitions) {
        if ($target -isnot [string] -or [string]::IsNullOrWhiteSpace($target)) {
            throw "projects[$projectId].cross_repo_targets は空でない文字列の配列である必要があります。"
        }
        $targets += $target.Trim()
    }

    $projectIds[$projectId] = $true
    $projectPaths[$projectPath] = $true
    $projects += [PSCustomObject]@{
        Id = $projectId
        Path = $projectPath
        IndexMode = $indexMode
        Persistence = $persistence
        RequiredCbmiIgnorePatterns = $requiredIgnorePatterns
        CrossRepoTargets = $targets
        Statistics = Get-TrackedProjectStatistics -ProjectPath $projectPath
    }
}

# 全プロジェクトを検証してから1件目の索引を始める。途中で誤ったIDが発覚して
# 一部だけ更新される事態を避けるため、横断対象の検証もここで完了させる。
foreach ($project in $projects) {
    foreach ($target in $project.CrossRepoTargets) {
        if ($target -eq $project.Id) {
            throw "projects[$($project.Id)] は自分自身をcross_repo_targetsに指定できません。"
        }
        if (-not $projectIds.ContainsKey($target)) {
            throw "projects[$($project.Id)] が未登録のcross_repo_targetsを参照しています: $target"
        }
    }
}

Write-Output "ワークスペース: $workspaceId"
Write-Output "許可ルート: $allowedRoot"
Write-Output "キャッシュ: $cacheDir"
Write-Output "メモリ上限: $maxMemoryMb MiB"
foreach ($project in $projects) {
    $sizeMiB = [math]::Round($project.Statistics.Bytes / 1MB, 2)
    Write-Output "検証済み: $($project.Id) ($($project.Statistics.Files) files, $sizeMiB MiB, $($project.IndexMode))"
}

if ($DryRun) {
    Write-Output 'dry-run: 実行ファイル、MCP設定、リポジトリ、索引キャッシュを変更しません。'
    exit 0
}

if ([string]::IsNullOrWhiteSpace($ExecutablePath)) {
    throw '実行時は-ExecutablePathで検証済みのcodebase-memory-mcp.exeを指定してください。'
}
$binary = (Resolve-Path -LiteralPath $ExecutablePath -ErrorAction Stop).Path
if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) {
    throw "実行ファイルが見つかりません: $ExecutablePath"
}

# CBMの設定はプロセスに限定する。ユーザー環境変数やCodex設定をこのスクリプトが
# 永続変更しないことで、試験ワークスペースの境界を他プロジェクトへ漏らさない。
$previousEnvironment = @{}
foreach ($name in @('CBM_ALLOWED_ROOT', 'CBM_CACHE_DIR', 'CBM_MEM_BUDGET_MB')) {
    $item = Get-Item -Path "Env:$name" -ErrorAction SilentlyContinue
    $previousEnvironment[$name] = [PSCustomObject]@{
        Existed = $null -ne $item
        Value = if ($null -ne $item) { $item.Value } else { $null }
    }
}

try {
    New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
    $env:CBM_ALLOWED_ROOT = $allowedRoot
    $env:CBM_CACHE_DIR = $cacheDir
    $env:CBM_MEM_BUDGET_MB = [string]$maxMemoryMb

    foreach ($project in $projects) {
        $arguments = @('cli', '--progress', 'index_repository', '--repo-path', $project.Path,
            '--name', $project.Id, '--mode', $project.IndexMode)
        if ($project.Persistence) {
            $arguments += '--persistence'
        }
        Invoke-CodebaseMemoryCli -Binary $binary -Arguments $arguments -Operation "索引 ($($project.Id))"
    }

    foreach ($project in $projects) {
        if ($project.CrossRepoTargets.Count -eq 0) {
            continue
        }
        $arguments = @('cli', '--progress', 'index_repository', '--repo-path', $project.Path,
            '--name', $project.Id, '--mode', 'cross-repo-intelligence')
        foreach ($target in $project.CrossRepoTargets) {
            # CBMの配列引数は、PowerShellではJSONリテラルより反復フラグの方が
            # 確実に展開される。各ターゲットを個別に追加してMCP配列へ変換させる。
            $arguments += @('--target-projects', $target)
        }
        Invoke-CodebaseMemoryCli -Binary $binary -Arguments $arguments -Operation "横断リンク ($($project.Id))"
    }
} finally {
    foreach ($name in $previousEnvironment.Keys) {
        Restore-EnvironmentVariable -Name $name -Existed $previousEnvironment[$name].Existed -Value $previousEnvironment[$name].Value
    }
}

Write-Output "ワークスペース '$workspaceId' の同期が完了しました。"
