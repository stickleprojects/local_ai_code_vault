<#
.SYNOPSIS
  Poll a background indexer container (from index-repo.ps1 without -Wait).

.DESCRIPTION
  `docker inspect` -> { container_id, state, exit_code, done }.
  When the container has exited it is reaped (docker rm) so background
  jobs don't accumulate — pass -Keep to leave it for log inspection.
  A container that no longer exists is reported done/state=gone (the
  skill treats that as "finished, result already in the index").

.PARAMETER ContainerId  Id printed by index-repo.ps1.
.PARAMETER Keep         Do not remove the container after it has exited.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)][string]$ContainerId,
    [switch]$Keep
)

. "$PSScriptRoot/_common.ps1"

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Stop-VaultWithError "docker not found on PATH" $VaultExit.Docker
}

$fmt = (& docker inspect -f '{{.State.Status}}|{{.State.ExitCode}}' $ContainerId 2>$null)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($fmt)) {
    Write-VaultResult ([ordered]@{
        container_id = $ContainerId; state = 'gone'
        exit_code = $null; done = $true
        note = 'container no longer exists (already finished and reaped)'
    }) 0
}

$parts    = "$fmt".Trim().Split('|')
$state    = $parts[0]
$exitCode = [int]$parts[1]
$done     = ($state -eq 'exited' -or $state -eq 'dead')

if ($done -and -not $Keep) {
    & docker rm $ContainerId *> $null      # best-effort reap
}

Write-VaultResult ([ordered]@{
    container_id = $ContainerId
    state        = $state
    exit_code    = if ($done) { $exitCode } else { $null }
    done         = $done
}) 0
