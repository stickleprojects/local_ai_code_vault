<#
.SYNOPSIS
  Install/remove non-blocking post-commit & post-merge auto-reindex hooks.

.DESCRIPTION
  Writes POSIX `sh` hooks (git runs hooks via its bundled sh on Windows)
  that fire an INCREMENTAL reindex in the background and `exit 0`
  immediately — a commit/merge is never blocked or failed, and if the
  vault stack is down the reindex simply no-ops (index-repo.ps1 exits
  non-zero but the hook discards output and still exits 0).

  Hooks carry a marker line so -Remove only deletes vault-managed hooks.
  A pre-existing, non-vault hook is left untouched (use -Force to
  overwrite). Requires `pwsh` on PATH at commit time.

.PARAMETER Path    A path inside the repo (default: current dir).
.PARAMETER Remove  Remove vault-managed hooks instead of installing.
.PARAMETER Force   Overwrite a pre-existing non-vault hook.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Path = '.',
    [switch]$Remove,
    [switch]$Force
)

. "$PSScriptRoot/_common.ps1"

$root     = Resolve-GitRoot -Path $Path
$marker   = '# vault-managed hook (local_ai_code_vault)'
$hooksDir = Join-Path (& git -C $root rev-parse --git-path hooks).Trim() ''
if (-not [System.IO.Path]::IsPathRooted($hooksDir)) {
    $hooksDir = Join-Path $root $hooksDir
}
$null = New-Item -ItemType Directory -Force -Path $hooksDir

$indexer  = ((Resolve-Path "$PSScriptRoot/index-repo.ps1").Path) -replace '\\', '/'
$repoPosix = ($root -replace '\\', '/')
$hookNames = @('post-commit', 'post-merge')

$body = @"
#!/bin/sh
$marker
pwsh -NoProfile -File "$indexer" "$repoPosix" -Incremental >/dev/null 2>&1 &
exit 0
"@ -replace "`r`n", "`n"

$done = @()
foreach ($name in $hookNames) {
    $hookPath = Join-Path $hooksDir $name

    if ($Remove) {
        if (Test-Path -LiteralPath $hookPath) {
            if ((Get-Content -Raw -LiteralPath $hookPath) -like "*$marker*") {
                Remove-Item -LiteralPath $hookPath -Force
                $done += @{ hook = $name; action = 'removed' }
            } else {
                $done += @{ hook = $name; action = 'left (not vault-managed)' }
            }
        } else {
            $done += @{ hook = $name; action = 'absent' }
        }
        continue
    }

    if ((Test-Path -LiteralPath $hookPath) -and -not $Force) {
        if ((Get-Content -Raw -LiteralPath $hookPath) -notlike "*$marker*") {
            Stop-VaultWithError "existing non-vault '$name' hook present — refusing to overwrite (use -Force)" `
                $VaultExit.Usage ([ordered]@{ hook = $name })
        }
    }
    # LF newlines, no BOM — git's sh must be able to run it.
    [System.IO.File]::WriteAllText($hookPath, $body, (New-Object System.Text.UTF8Encoding($false)))
    $done += @{ hook = $name; action = 'installed' }
}

Write-VaultResult ([ordered]@{
    repo_root = $root
    hooks_dir = $hooksDir
    removed   = [bool]$Remove
    result    = $done
}) 0
