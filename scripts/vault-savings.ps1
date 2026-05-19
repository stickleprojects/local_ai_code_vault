<#
.SYNOPSIS
  Aggregate the per-repo savings ledger written by query.ps1.

.DESCRIPTION
  Reads the JSONL ledger for THIS repo and reports cumulative and
  recent-window estimates of context tokens avoided by using the vault
  instead of reading whole files.

  HONESTY: every figure is an ESTIMATE and an UPPER BOUND. The baseline
  assumes Claude would otherwise have read the FULL source of every file
  a hit came from; in reality it often reads only ranges, so true
  savings are lower. Token counts use a ~4-chars/token heuristic, not
  Claude's tokenizer. Vault tool overhead and prompt caching are not
  modelled. There is deliberately NO money conversion — that would stack
  too many assumptions to be trustworthy.

  stdout JSON: { repo_id, stats_file, recorded_queries, all_time:{...},
                 window:{days,...}, basis }

.PARAMETER Path  A path inside the repo (default: current dir).
.PARAMETER Days  Recent-window size in days for the `window` block
                 (1..365, default 14).
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Path = '.',
    [ValidateRange(1, 365)][int]$Days = 14
)

. "$PSScriptRoot/_common.ps1"

$root   = Resolve-GitRoot -Path $Path
$repoId = Get-RepoId -Path $root

$statsFile = Join-Path (Get-VaultStatsDir) "$repoId.jsonl"

function New-Bucket {
    [ordered]@{
        queries               = 0
        returned_tokens       = 0
        baseline_tokens_upper = 0
        saved_tokens_upper    = 0
        pct_upper             = 0
    }
}
function Add-Event {
    param($Bucket, $Ev)
    $Bucket.queries++
    $Bucket.returned_tokens       += [int]$Ev.returned_tokens
    $Bucket.baseline_tokens_upper += [int]$Ev.baseline_tokens_upper
    $Bucket.saved_tokens_upper    += [int]$Ev.saved_tokens_upper
}
function Set-Pct {
    param($Bucket)
    $Bucket.pct_upper = if ($Bucket.baseline_tokens_upper -gt 0) {
        [int][math]::Round($Bucket.saved_tokens_upper / $Bucket.baseline_tokens_upper * 100)
    } else { 0 }
}

$all    = New-Bucket
$window = New-Bucket
$firstAt = $null
$lastAt  = $null
$cutoff  = [DateTime]::UtcNow.AddDays(-$Days)
$corrupt = 0

if (Test-Path -LiteralPath $statsFile -PathType Leaf) {
    foreach ($line in [IO.File]::ReadAllLines($statsFile)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $ev = $line | ConvertFrom-Json } catch { $corrupt++; continue }
        if ($null -eq $ev.ts) { $corrupt++; continue }
        Add-Event $all $ev
        $ts = $null
        if ([DateTime]::TryParse([string]$ev.ts, [ref]$ts)) {
            $tsUtc = $ts.ToUniversalTime()
            if ($null -eq $firstAt -or $tsUtc -lt $firstAt) { $firstAt = $tsUtc }
            if ($null -eq $lastAt  -or $tsUtc -gt $lastAt)  { $lastAt  = $tsUtc }
            if ($tsUtc -ge $cutoff) { Add-Event $window $ev }
        }
    }
}
Set-Pct $all
Set-Pct $window

$all['first_at'] = if ($firstAt) { $firstAt.ToString('o') } else { $null }
$all['last_at']  = if ($lastAt)  { $lastAt.ToString('o') }  else { $null }
$window['days']  = $Days

Write-VaultResult ([ordered]@{
    repo_id          = $repoId
    stats_file       = $statsFile
    recorded_queries = $all.queries
    corrupt_lines    = $corrupt
    all_time         = $all
    window           = $window
    basis            = 'ESTIMATE & UPPER BOUND: baseline = full source of files in results (Claude often reads ranges, so true savings are lower); ~4 chars/token, not Claude tokenizer; excludes vault tool overhead and prompt caching; no money conversion'
    note             = if ($all.queries -eq 0) { 'No /vault-search queries recorded yet for this repo.' } else { $null }
}) 0
