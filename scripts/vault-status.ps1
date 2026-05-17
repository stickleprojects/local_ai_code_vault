<#
.SYNOPSIS
  Is THIS repo registered, and is its index stale vs local HEAD?

.DESCRIPTION
  Resolves repo_id (via repo-id.ps1), asks the API whether it is
  registered, compares the stored indexed SHA against local
  `git rev-parse HEAD` (AD-6 staleness), and — when stale and the
  indexed SHA is in local history — lists the changed files.

  stdout JSON:
    { repo_id, registered, indexed_sha, indexed_at, head_sha,
      stale, changed_files[] (null if undeterminable) }

.PARAMETER Path
  A path inside the repo (default: current directory).
#>
[CmdletBinding()]
param([Parameter(Position = 0)][string]$Path = '.')

. "$PSScriptRoot/_common.ps1"

$root   = Resolve-GitRoot -Path $Path        # exit 3 if not a git repo
$repoId = Get-RepoId -Path $root
$head   = Get-GitHead -Path $root

$r = Invoke-VaultApi -Path "/api/repos/$repoId"   # exit 4 if stack down

$registered = $false
$indexedSha = $null
$indexedAt  = $null
if ($r.status -eq 200) {
    $registered = $true
    $indexedSha = $r.body.indexed_sha
    $indexedAt  = $r.body.indexed_at
} elseif ($r.status -ne 404) {
    Stop-VaultWithError "unexpected HTTP $($r.status) from /api/repos/$repoId" $VaultExit.ApiError
}

$stale        = $false
$changedFiles = $null
if ($registered -and $indexedSha -and $head) {
    $stale = ($indexedSha -ne $head)
    if ($stale) {
        # Only meaningful if the indexed commit exists locally.
        & git -C $root cat-file -e "$indexedSha^{commit}" 2>$null
        if ($LASTEXITCODE -eq 0) {
            $diff = & git -C $root diff --name-only $indexedSha $head 2>$null
            if ($LASTEXITCODE -eq 0) {
                $changedFiles = @($diff | Where-Object { $_ -ne '' })
            }
        }
    } else {
        $changedFiles = @()
    }
}

Write-VaultResult ([ordered]@{
    repo_id       = $repoId
    registered    = $registered
    indexed_sha   = $indexedSha
    indexed_at    = $indexedAt
    head_sha      = $head
    stale         = $stale
    changed_files = $changedFiles
}) 0
