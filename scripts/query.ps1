<#
.SYNOPSIS
  Semantic search over THIS repo's index (GET /api/query/{repo_id}).

.DESCRIPTION
  Resolves repo_id, calls the query API, and returns the ranked hits as
  JSON for the skill to format. 404 -> NotRegistered (the skill offers
  /vault-index). Rendering for the user is the skill's job (AD-4); this
  script only produces the machine-readable result.

  stdout JSON: { repo_id, query, count, results:[{path,language,
                 start_line,end_line,score,code}] }

.PARAMETER Path   A path inside the repo (default: current dir).
.PARAMETER Query  The natural-language search string (required).
.PARAMETER Limit  Max hits (1..50, default 10).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)][string]$Query,
    [Parameter(Position = 1)][string]$Path = '.',
    [ValidateRange(1, 50)][int]$Limit = 10
)

. "$PSScriptRoot/_common.ps1"

if ([string]::IsNullOrWhiteSpace($Query)) {
    Stop-VaultWithError "query string is required" $VaultExit.Usage
}

$root   = Resolve-GitRoot -Path $Path
$repoId = Get-RepoId -Path $root

$enc = [uri]::EscapeDataString($Query)
$r = Invoke-VaultApi -Path "/api/query/$repoId`?q=$enc&limit=$Limit"

if ($r.status -eq 404) {
    Stop-VaultWithError "repo '$repoId' is not registered — index it first (scripts/index-repo.ps1)" `
        $VaultExit.NotRegistered ([ordered]@{ repo_id = $repoId })
}
if ($r.status -ne 200) {
    Stop-VaultWithError "query API returned HTTP $($r.status)" $VaultExit.ApiError
}

$results = @($r.body.results)
Write-VaultResult ([ordered]@{
    repo_id = $repoId
    query   = $Query
    count   = $results.Count
    results = $results
}) 0
