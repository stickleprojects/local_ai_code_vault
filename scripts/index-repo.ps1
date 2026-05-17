<#
.SYNOPSIS
  Index/reindex THIS repo via the ephemeral indexer (AD-2 Option B).

.DESCRIPTION
  Launches `docker run` for the indexer image, bind-mounting the repo
  read-only at /repo and joining the stack network so it reaches
  `qdrant` / `embedder` by name. repo_id is resolved here (never by the
  container) and passed as an explicit argument.

  Modes:
   * default (background): `docker run -d` (NOT --rm, so the container
     survives for index-status.ps1 to inspect/`docker wait`). Prints
     {container_id}. index-status.ps1 reaps it when done.
   * -Wait: `docker run --rm` attached; the indexer's stderr is streamed
     to our stderr, its stdout JSON summary is captured and returned.

  -Incremental reindexes only files changed since the indexed SHA
  (resolved via vault-status.ps1). If the repo isn't registered yet it
  falls back to a full index.

.PARAMETER Path        A path inside the repo (default: current dir).
.PARAMETER Incremental Only changed-since-indexed files.
.PARAMETER Wait        Block and stream until the indexer exits.
.PARAMETER Build       Build the indexer image if it is missing.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Path = '.',
    [switch]$Incremental,
    [switch]$Wait,
    [switch]$Build
)

. "$PSScriptRoot/_common.ps1"

$cfg    = Get-VaultConfig
$root   = Resolve-GitRoot -Path $Path
$repoId = Get-RepoId -Path $root

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Stop-VaultWithError "docker not found on PATH — required to run the indexer" $VaultExit.Docker
}

# Image present? Build on request, else fail with the exact command.
& docker image inspect $cfg.IndexerImage *> $null
if ($LASTEXITCODE -ne 0) {
    if ($Build) {
        Write-VaultLog "building $($cfg.IndexerImage) ..."
        $repoTop = (Resolve-Path -LiteralPath "$PSScriptRoot/..").Path
        # Build chatter -> stderr so stdout stays a single JSON object.
        & docker build -t $cfg.IndexerImage -f "$repoTop/indexer/Dockerfile" $repoTop 2>&1 |
            ForEach-Object { [Console]::Error.WriteLine($_) }
        if ($LASTEXITCODE -ne 0) {
            Stop-VaultWithError "indexer image build failed" $VaultExit.Docker
        }
    } else {
        Stop-VaultWithError ("indexer image '$($cfg.IndexerImage)' not found. " +
            "Build it: docker build -t $($cfg.IndexerImage) -f indexer/Dockerfile . " +
            "(or re-run with -Build)") $VaultExit.Docker
    }
}

# Incremental: gather changed files from the registered/HEAD diff.
$changedArgs = @()
$mode = 'full'
if ($Incremental) {
    $st = & "$PSScriptRoot/vault-status.ps1" -Path $root | ConvertFrom-Json
    if (-not $st -or -not $st.ok) {
        Stop-VaultWithError "could not determine change set (vault-status failed)" $VaultExit.ApiError
    }
    if ($st.registered -and $st.stale -and $st.changed_files) {
        $list = @($st.changed_files) -join ','
        if ($list) { $changedArgs = @('--changed-files', $list); $mode = 'incremental' }
    } elseif ($st.registered -and -not $st.stale) {
        Write-VaultResult ([ordered]@{
            repo_id = $repoId; skipped = $true
            reason  = 'already up to date (HEAD == indexed SHA)'
        }) 0
    } else {
        Write-VaultLog 'not registered or change set undeterminable -> full index'
    }
}

$mount     = "$($root):/repo:ro"
$indexArgs = @(
    '--repo-id', $repoId,
    '--qdrant-url', 'http://qdrant:6333',
    '--embedder-url', 'http://embedder:8080',
    '--verbose'
) + $changedArgs

if ($Wait) {
    Write-VaultLog "docker run --rm (attached) mode=$mode"
    $runArgs = @('run', '--rm', '--network', $cfg.Network,
                 '-v', $mount, $cfg.IndexerImage) + $indexArgs
    # Merge streams: show everything as progress on stderr, then recover
    # the indexer's single-line JSON summary as the last parseable line.
    $lines = & docker @runArgs 2>&1
    $rc = $LASTEXITCODE
    $lines | ForEach-Object { [Console]::Error.WriteLine($_) }
    $parsed = $null
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        try { $parsed = ("$($lines[$i])" | ConvertFrom-Json); break } catch {}
    }
    if ($rc -ne 0) {
        Stop-VaultWithError "indexer exited $rc (see streamed logs above)" $VaultExit.Docker `
            ([ordered]@{ repo_id = $repoId; mode = $mode; exit_code = $rc })
    }
    Write-VaultResult ([ordered]@{
        repo_id = $repoId; mode = $mode; waited = $true
        exit_code = 0; indexer = $parsed
    }) 0
}
else {
    Write-VaultLog "docker run -d (background) mode=$mode"
    $runArgs = @('run', '-d', '--network', $cfg.Network,
                 '-v', $mount, $cfg.IndexerImage) + $indexArgs
    $cid = & docker @runArgs 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($cid)) {
        Stop-VaultWithError "failed to launch indexer container" $VaultExit.Docker
    }
    Write-VaultResult ([ordered]@{
        repo_id      = $repoId
        mode         = $mode
        waited       = $false
        container_id = "$cid".Trim()
        hint         = 'poll with: scripts/index-status.ps1 <container_id>'
    }) 0
}
