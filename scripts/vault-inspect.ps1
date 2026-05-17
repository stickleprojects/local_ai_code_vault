<#
.SYNOPSIS
  Show WHAT is indexed for THIS repo (AD-9, read-only — not search).

.DESCRIPTION
  Resolves repo_id and calls the introspection API:
    /api/repos/{repo_id}/stats          (always)
    /api/repos/{repo_id}/files          (only with -Files)
  Returns indexed SHA/time, file + chunk counts, per-language
  breakdown, skipped count, and (with -Files) the file inventory.
  -Language filters the inventory client-side. Strictly read-only.

  stdout JSON: { repo_id, stats:{...}, files:{...}|null }

.PARAMETER Path      A path inside the repo (default: current dir).
.PARAMETER Files     Also fetch the per-file inventory.
.PARAMETER Language  Filter the inventory to one language (implies -Files view).
.PARAMETER Offset    Inventory page offset (default 0).
.PARAMETER Limit     Inventory page size (1..1000, default 100).
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Path = '.',
    [switch]$Files,
    [string]$Language,
    [int]$Offset = 0,
    [ValidateRange(1, 1000)][int]$Limit = 100
)

. "$PSScriptRoot/_common.ps1"

$root   = Resolve-GitRoot -Path $Path
$repoId = Get-RepoId -Path $root

$s = Invoke-VaultApi -Path "/api/repos/$repoId/stats"
if ($s.status -eq 404) {
    Stop-VaultWithError "repo '$repoId' is not registered — nothing indexed yet" `
        $VaultExit.NotRegistered ([ordered]@{ repo_id = $repoId })
}
if ($s.status -ne 200) {
    Stop-VaultWithError "stats API returned HTTP $($s.status)" $VaultExit.ApiError
}

$filesBlock = $null
if ($Files -or $Language) {
    $f = Invoke-VaultApi -Path "/api/repos/$repoId/files`?offset=$Offset&limit=$Limit"
    if ($f.status -ne 200) {
        Stop-VaultWithError "files API returned HTTP $($f.status)" $VaultExit.ApiError
    }
    $inv = @($f.body.files)
    if ($Language) { $inv = @($inv | Where-Object { $_.language -eq $Language }) }
    $filesBlock = [ordered]@{
        total    = $f.body.total
        offset   = $f.body.offset
        limit    = $f.body.limit
        filter   = $Language
        returned = $inv.Count
        files    = $inv
    }
}

Write-VaultResult ([ordered]@{
    repo_id = $repoId
    stats   = $s.body
    files   = $filesBlock
}) 0
