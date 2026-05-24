[CmdletBinding()]
param(
    [string]$FixturePath = (Join-Path $PSScriptRoot 'vectors.json'),
    [string]$CorpusPath = (Join-Path $PSScriptRoot 'corpus'),
    [string]$Network = $(if ($env:VAULT_NETWORK) { $env:VAULT_NETWORK } else { 'vault_default' }),
    [string]$ProxyImage = 'vault-embedder-stub:local',
    [string]$ProxyContainer = 'vault-record-embedder-proxy',
    [string]$RealContainer = 'vault-record-real-embedder'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

function Remove-ContainerIfPresent {
    param([Parameter(Mandatory)][string]$Name)

    & docker rm -f $Name 2>$null | Out-Null
    $null = $LASTEXITCODE
}

function Get-CorpusSha {
    param([Parameter(Mandatory)][string]$Root)

    $dir = (Resolve-Path -LiteralPath $Root).Path
    $hash = [System.Security.Cryptography.IncrementalHash]::CreateHash([System.Security.Cryptography.HashAlgorithmName]::SHA256)
    $utf8 = [System.Text.Encoding]::UTF8

    $files = Get-ChildItem -LiteralPath $dir -Recurse -File | Sort-Object FullName
    foreach ($file in $files) {
        $relative = [System.IO.Path]::GetRelativePath($dir, $file.FullName).Replace('\', '/')
        $hash.AppendData($utf8.GetBytes($relative))
        $hash.AppendData([byte[]](0))
        $hash.AppendData([System.IO.File]::ReadAllBytes($file.FullName))
        $hash.AppendData([byte[]](0))
    }

    return ([Convert]::ToHexString($hash.GetHashAndReset())).ToLowerInvariant()
}

function Get-EmbedderInspect {
    param([Parameter(Mandatory)][string]$RepoRoot)

    $containerId = (& docker compose -f (Join-Path $RepoRoot 'docker-compose.yml') ps -q embedder).Trim()
    if ([string]::IsNullOrWhiteSpace($containerId)) {
        throw "compose embedder is not running. Start the real GPU stack first: docker compose up -d"
    }

    $json = & docker inspect $containerId
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($json)) {
        throw 'failed to inspect running embedder container'
    }
    return (($json | ConvertFrom-Json)[0])
}

function New-MountArgs {
    param($Inspect)

    $args = @()
    foreach ($mount in @($Inspect.Mounts)) {
        $source = if ($mount.Type -eq 'volume') { $mount.Name } else { $mount.Source }
        $readonly = if ([bool]$mount.RW) { 'false' } else { 'true' }
        $args += @('--mount', "type=$($mount.Type),source=$source,target=$($mount.Destination),readonly=$readonly")
    }
    return $args
}

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$fixtureFullPath = [System.IO.Path]::GetFullPath($FixturePath)
$fixtureDir = Split-Path -Parent $fixtureFullPath
$fixtureName = Split-Path -Leaf $fixtureFullPath
$corpusSha = Get-CorpusSha -Root $CorpusPath
$composeFile = Join-Path $repoRoot 'docker-compose.yml'
$runEval = Join-Path $PSScriptRoot 'run-eval.ps1'

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw 'docker is required'
}
if (-not (Test-Path -LiteralPath $runEval -PathType Leaf)) {
    throw "eval runner not found: $runEval"
}
if (-not (Test-Path -LiteralPath $CorpusPath -PathType Container)) {
    throw "corpus path not found: $CorpusPath"
}
if (-not (Test-Path -LiteralPath $fixtureDir -PathType Container)) {
    $null = New-Item -ItemType Directory -Path $fixtureDir -Force
}

$inspect = Get-EmbedderInspect -RepoRoot $repoRoot
$embedderImage = [string]$inspect.Config.Image
$embedderCommand = @($inspect.Config.Cmd | ForEach-Object { [string]$_ })
$mountArgs = New-MountArgs -Inspect $inspect

Push-Location $repoRoot
try {
    & docker build -t $ProxyImage -f eval/embedder-stub/Dockerfile .
    if ($LASTEXITCODE -ne 0) {
        throw 'failed to build recorder/stub image'
    }

    Remove-ContainerIfPresent -Name $ProxyContainer
    Remove-ContainerIfPresent -Name $RealContainer

    & docker compose -f $composeFile stop embedder
    if ($LASTEXITCODE -ne 0) {
        throw 'failed to stop compose embedder'
    }
    & docker compose -f $composeFile rm -f embedder
    if ($LASTEXITCODE -ne 0) {
        throw 'failed to remove stopped compose embedder container'
    }

    $realArgs = @(
        'run', '-d',
        '--name', $RealContainer,
        '--network', $Network,
        '--network-alias', 'real-embedder',
        '--gpus', 'all'
    ) + $mountArgs + @($embedderImage) + $embedderCommand
    $realId = (& docker @realArgs).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($realId)) {
        throw 'failed to launch real embedder container'
    }

    $proxyArgs = @(
        'run', '-d',
        '--name', $ProxyContainer,
        '--network', $Network,
        '--network-alias', 'embedder',
        '-e', 'EMBEDDER_STUB_MODE=record',
        '-e', 'EMBEDDER_STUB_UPSTREAM_URL=http://real-embedder:8080',
        '-e', "EMBEDDER_STUB_CORPUS_SHA=$corpusSha",
        '-e', "EMBEDDER_STUB_FIXTURE=/fixtures/$fixtureName",
        '-v', "${fixtureDir}:/fixtures"
    ) + @($ProxyImage)
    $proxyId = (& docker @proxyArgs).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($proxyId)) {
        throw 'failed to launch recording proxy container'
    }

    Start-Sleep -Seconds 3
    & pwsh -NoProfile -File $runEval
    exit $LASTEXITCODE
}
finally {
    Remove-ContainerIfPresent -Name $ProxyContainer
    Remove-ContainerIfPresent -Name $RealContainer
    & docker compose -f $composeFile up -d embedder 2>$null | Out-Null
    Pop-Location
}
