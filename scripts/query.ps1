<#
.SYNOPSIS
  Semantic search over THIS repo's index (GET /api/query/{repo_id}).

.DESCRIPTION
  Resolves repo_id, calls the query API, and returns the ranked hits as
  JSON for the skill to format. 404 -> NotRegistered (the skill offers
  /vault-index). Rendering for the user is the skill's job (AD-4); this
  script only produces the machine-readable result.

  stdout JSON: { repo_id, query, count, results:[{path,language,
                 start_line,end_line,score,code}], savings:{...} }

  `savings` is an ESTIMATE of context tokens avoided this query:
  tokens of the returned chunks vs. an UPPER BOUND of reading the full
  source of every file the hits came from (~4 chars/token; not Claude's
  tokenizer). It is an upper bound (Claude often reads ranges, not whole
  files) and excludes vault tool overhead and prompt caching. One event
  is appended to a per-repo JSONL ledger (best-effort; a stats failure
  never fails the search) for `vault-savings.ps1` to aggregate.

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

$resultsValue = Get-VaultBodyValue -Body $r.body -Key 'results'
$results = @()
if ($null -ne $resultsValue) { $results = @($resultsValue) }

# --- Savings estimate (honest upper bound; never present as exact) ----
$returnedTokens = 0
foreach ($hit in $results) {
    $hitCode = Get-VaultBodyValue -Body $hit -Key 'code'
    $returnedTokens += Get-VaultTokenEstimate ([string]$hitCode)
}

$baselineTokens = 0
$filesCounted = 0
$filesMissing = 0
$seen = @{}
foreach ($hit in $results) {
    $rel = [string](Get-VaultBodyValue -Body $hit -Key 'path')
    if ([string]::IsNullOrWhiteSpace($rel) -or $seen.ContainsKey($rel)) { continue }
    $seen[$rel] = $true
    $full = Join-Path $root $rel
    if (Test-Path -LiteralPath $full -PathType Leaf) {
        try {
            $baselineTokens += Get-VaultTokenEstimate ([IO.File]::ReadAllText($full))
            $filesCounted++
        } catch { $filesMissing++ }
    } else {
        $filesMissing++   # indexed file no longer on disk — excluded from baseline
    }
}
$savedTokens = [math]::Max(0, $baselineTokens - $returnedTokens)
$pct = if ($baselineTokens -gt 0) { [int][math]::Round($savedTokens / $baselineTokens * 100) } else { 0 }

$savings = [ordered]@{
    returned_tokens       = $returnedTokens
    baseline_tokens_upper = $baselineTokens
    saved_tokens_upper    = $savedTokens
    pct_upper             = $pct
    files_counted         = $filesCounted
    files_missing         = $filesMissing
    basis                 = 'estimate (~4 chars/token, not Claude tokenizer); baseline = full source of files in results = UPPER BOUND; excludes vault tool overhead and prompt caching'
}

# Append one ledger event. Best-effort: a stats failure must NEVER fail
# the search (it is the whole point of the vault) — log and move on.
try {
    $statsFile = Join-Path (Get-VaultStatsDir) "$repoId.jsonl"
    $event = [ordered]@{
        ts                    = [DateTime]::UtcNow.ToString('o')
        repo_id               = $repoId
        query                 = $Query
        count                 = $results.Count
        returned_tokens       = $returnedTokens
        baseline_tokens_upper = $baselineTokens
        saved_tokens_upper    = $savedTokens
        files_counted         = $filesCounted
        files_missing         = $filesMissing
    }
    $line = ($event | ConvertTo-Json -Depth 6 -Compress)
    [IO.File]::AppendAllText($statsFile, $line + "`n")
} catch {
    Write-VaultLog "savings ledger write skipped: $($_.Exception.Message)"
}

Write-VaultResult ([ordered]@{
    repo_id = $repoId
    query   = $Query
    count   = $results.Count
    results = $results
    savings = $savings
}) 0
