<#
.SYNOPSIS
  Smart semantic search with safe auto-index + fallback guidance.

.DESCRIPTION
  Shared orchestration script for Claude/Copilot search flows.

  Behavior:
   1) If vault is unavailable (stack down), return a fallback payload
      telling the caller to continue with normal workspace file search.
   2) If repo is not registered (query returns code 5):
      - with -DoNotIndex: return fallback payload (indexing declined)
      - otherwise: run index-repo.ps1 -Wait, then retry query once.
   3) If query returns zero hits, return fallback payload so callers can
      continue with normal workspace file search.

  This script keeps decision logic in scripts (AD-4), so both clients
  can share the same behavior.

.PARAMETER Query       Natural-language query (required).
.PARAMETER Path        A path inside the repo (default: current dir).
.PARAMETER Limit       Max hits (1..50, default 10).
.PARAMETER Mode        Search mode: semantic (default) or symbol.
.PARAMETER Symbol      Shortcut for symbol mode using Query as the identifier.
.PARAMETER DoNotIndex  Explicit opt-out for auto-index on code 5.
.PARAMETER Build       Build indexer image if missing during auto-index.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)][string]$Query,
    [Parameter(Position = 1)][string]$Path = '.',
    [ValidateRange(1, 50)][int]$Limit = 10,
    [ValidateSet('semantic', 'symbol')][string]$Mode = 'semantic',
    [switch]$Symbol,
    [switch]$DoNotIndex,
    [switch]$Build
)

. "$PSScriptRoot/_common.ps1"

# This wrapper intentionally interprets child script exit codes as
# control-flow (e.g. code 5 -> auto-index path), so native non-zero
# exits must not raise terminating errors here.
$PSNativeCommandUseErrorActionPreference = $false

if ([string]::IsNullOrWhiteSpace($Query)) {
    Stop-VaultWithError "query string is required" $VaultExit.Usage
}

$root = Resolve-GitRoot -Path $Path
$repoId = Get-RepoId -Path $root
$indexStale = $false
$changedFilesNotIndexed = @()
$searchMode = if ($Symbol) { 'symbol' } else { $Mode }

function Invoke-JsonScript {
    param(
        [Parameter(Mandatory)][string]$ScriptName,
        [object[]]$PositionalArgs = @(),
        [hashtable]$NamedArgs = @{}
    )
    $raw = & "$PSScriptRoot/$ScriptName" @PositionalArgs @NamedArgs 2>$null
    $code = $LASTEXITCODE
    $obj = $null
    if ($raw) {
        try { $obj = ($raw -join "`n") | ConvertFrom-Json -AsHashtable } catch { $obj = $null }
    }
    if ($null -eq $obj) {
        $obj = [ordered]@{ ok = ($code -eq 0); code = $code; raw = "$raw" }
    }
    [ordered]@{ code = $code; body = $obj }
}

function New-ZeroSavings {
    [ordered]@{
        returned_tokens       = 0
        baseline_tokens_upper = 0
        saved_tokens_upper    = 0
        pct_upper             = 0
        files_counted         = 0
        files_missing         = 0
        basis                 = 'estimate (~4 chars/token, not Claude tokenizer); baseline = full source of files in results = UPPER BOUND; excludes vault tool overhead and prompt caching'
    }
}

function Get-IndexStaleness {
    param([Parameter(Mandatory)][string]$RepoRoot)

    $status = Invoke-JsonScript -ScriptName 'vault-status.ps1' -NamedArgs @{ Path = $RepoRoot }
    if ($status.code -ne 0) {
        return [ordered]@{ stale = $false; changed = @() }
    }

    $staleValue = Get-VaultBodyValue -Body $status.body -Key 'stale'
    $changedValue = Get-VaultBodyValue -Body $status.body -Key 'changed_files'
    $changed = if ($null -ne $changedValue) { @($changedValue) } else { @() }
    [ordered]@{
        stale = [bool]$staleValue
        changed = $changed
    }
}

function Get-LanguageFromPath {
    param([string]$RelativePath)
    if ([string]::IsNullOrWhiteSpace($RelativePath)) { return $null }
    $ext = [IO.Path]::GetExtension($RelativePath).ToLowerInvariant()
    switch ($ext) {
        '.py' { return 'python' }
        '.cs' { return 'csharp' }
        '.js' { return 'javascript' }
        '.jsx' { return 'javascript' }
        '.ts' { return 'typescript' }
        '.tsx' { return 'typescript' }
        default { return $null }
    }
}

function Invoke-SymbolSearch {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Identifier
    )

    $args = @(
        '-C', $RepoRoot,
        'grep',
        '-n',
        '-I',
        '--full-name',
        '-w',
        '-e', $Identifier,
        '--',
        '.'
    )
    $raw = & git @args 2>$null
    $code = $LASTEXITCODE

    if ($code -eq 1) { return @() } # no matches
    if ($code -ne 0) { return $null } # grep error

    $hits = @()
    foreach ($line in @($raw)) {
        if (-not $line) { continue }
        $m = [regex]::Match([string]$line, '^(?<path>.+?):(?<line>\d+):(?<code>.*)$')
        if (-not $m.Success) { continue }
        $relPath = $m.Groups['path'].Value
        $lineNo = [int]$m.Groups['line'].Value
        $codeText = $m.Groups['code'].Value
        $hits += [ordered]@{
            path       = $relPath
            language   = Get-LanguageFromPath -RelativePath $relPath
            start_line = $lineNo
            end_line   = $lineNo
            score      = 1.0
            code       = $codeText
        }
    }
    $hits
}

function Write-SearchOutcome {
    param(
        [bool]$UsedVault,
        [string]$Reason,
        [string]$Message,
        $QueryBody,
        [string]$Mode = $searchMode,
        [bool]$IndexedThisRun = $false,
        $IndexBody = $null,
        [bool]$IndexStale = $indexStale,
        [object[]]$ChangedFilesNotIndexed = $changedFilesNotIndexed
    )
    $count = 0
    $results = @()
    $savings = New-ZeroSavings
    $query = $Query
    if ($null -ne $QueryBody) {
        $countValue = Get-VaultBodyValue -Body $QueryBody -Key 'count'
        $resultsValue = Get-VaultBodyValue -Body $QueryBody -Key 'results'
        $savingsValue = Get-VaultBodyValue -Body $QueryBody -Key 'savings'
        $queryValue = Get-VaultBodyValue -Body $QueryBody -Key 'query'

        if ($null -ne $countValue) { $count = [int]$countValue }
        if ($null -ne $resultsValue) { $results = @($resultsValue) }
        if ($null -ne $savingsValue) { $savings = $savingsValue }
        if ($null -ne $queryValue) { $query = [string]$queryValue }
    }

    Write-VaultResult ([ordered]@{
            repo_id          = $repoId
            query            = $query
            mode             = $Mode
            count            = $count
            results          = $results
            savings          = $savings
            used_vault       = $UsedVault
            fallback_reason  = $Reason
            fallback_message = $Message
            next_action      = if ($UsedVault) { $null } else { 'workspace_search' }
            indexed_this_run = $IndexedThisRun
            index_result     = $IndexBody
            index_stale      = $IndexStale
            changed_files_not_indexed = @($ChangedFilesNotIndexed)
        }) 0
}

# Symbol mode = exact identifier completeness via git grep.
if ($searchMode -eq 'symbol') {
    if ([string]::IsNullOrWhiteSpace($Query)) {
        Stop-VaultWithError "symbol identifier is required" $VaultExit.Usage
    }
    $symbolHits = Invoke-SymbolSearch -RepoRoot $root -Identifier $Query
    if ($null -eq $symbolHits) {
        Write-SearchOutcome -UsedVault:$false -Reason 'vault_unavailable' `
            -Message 'Exact symbol search failed; continuing with normal workspace file search.' -QueryBody $null `
            -Mode 'symbol' -IndexStale:$false -ChangedFilesNotIndexed @()
    }
    Write-SearchOutcome -UsedVault:$true -Reason $null -Message $null -QueryBody ([ordered]@{
            query = $Query
            count = $symbolHits.Count
            results = $symbolHits
            savings = New-ZeroSavings
        }) -Mode 'symbol' -IndexStale:$false -ChangedFilesNotIndexed @()
}

# 1) Ensure vault is reachable before trying semantic search.
$health = Invoke-JsonScript -ScriptName 'vault-health.ps1'
if ($health.code -ne 0) {
    Write-SearchOutcome -UsedVault:$false -Reason 'vault_unavailable' `
        -Message 'Vault stack is unavailable; continuing with normal workspace file search.' -QueryBody $null -Mode 'semantic'
}

$staleness = Get-IndexStaleness -RepoRoot $root
$indexStale = [bool]$staleness.stale
$changedFilesNotIndexed = @($staleness.changed)

# 2) Try semantic query first.
$queryCall = Invoke-JsonScript -ScriptName 'query.ps1' -PositionalArgs @($Query) -NamedArgs @{
    Path  = $root
    Limit = $Limit
}
if ($queryCall.code -eq 0) {
    $qCountValue = Get-VaultBodyValue -Body $queryCall.body -Key 'count'
    $qCount = if ($null -ne $qCountValue) { [int]$qCountValue } else { 0 }
    if ($qCount -gt 0) {
        Write-SearchOutcome -UsedVault:$true -Reason $null -Message $null -QueryBody $queryCall.body -Mode 'semantic'
    }
    Write-SearchOutcome -UsedVault:$false -Reason 'no_semantic_hits' `
        -Message 'Vault search returned no semantic hits; continuing with normal workspace file search.' -QueryBody $queryCall.body -Mode 'semantic'
}

# 3) Not registered: opt-out or auto-index then retry once.
if ($queryCall.code -eq $VaultExit.NotRegistered) {
    if ($DoNotIndex) {
        Write-SearchOutcome -UsedVault:$false -Reason 'indexing_declined' `
            -Message 'Vault indexing was declined ("do not index"); continuing with normal workspace file search.' -QueryBody $null -Mode 'semantic'
    }

    $indexNamed = @{ Path = $root; Wait = $true }
    if ($Build) { $indexNamed.Build = $true }
    $indexCall = Invoke-JsonScript -ScriptName 'index-repo.ps1' -NamedArgs $indexNamed
    if ($indexCall.code -ne 0) {
        Write-SearchOutcome -UsedVault:$false -Reason 'vault_unavailable' `
            -Message 'Vault indexing failed/unavailable; continuing with normal workspace file search.' -QueryBody $null `
            -IndexedThisRun:$true -IndexBody $indexCall.body -Mode 'semantic'
    }

    $retry = Invoke-JsonScript -ScriptName 'query.ps1' -PositionalArgs @($Query) -NamedArgs @{
        Path  = $root
        Limit = $Limit
    }
    if ($retry.code -eq 0) {
        $rCountValue = Get-VaultBodyValue -Body $retry.body -Key 'count'
        $rCount = if ($null -ne $rCountValue) { [int]$rCountValue } else { 0 }
        if ($rCount -gt 0) {
            Write-SearchOutcome -UsedVault:$true -Reason $null -Message $null -QueryBody $retry.body `
                -IndexedThisRun:$true -IndexBody $indexCall.body -Mode 'semantic'
        }
        Write-SearchOutcome -UsedVault:$false -Reason 'no_semantic_hits' `
            -Message 'Vault search returned no semantic hits after indexing; continuing with normal workspace file search.' `
            -QueryBody $retry.body -IndexedThisRun:$true -IndexBody $indexCall.body -Mode 'semantic'
    }

    Write-SearchOutcome -UsedVault:$false -Reason 'vault_unavailable' `
        -Message 'Vault query failed after indexing; continuing with normal workspace file search.' -QueryBody $null `
        -IndexedThisRun:$true -IndexBody $indexCall.body -Mode 'semantic'
}

# 4) Any other query failure: graceful fallback.
Write-SearchOutcome -UsedVault:$false -Reason 'vault_unavailable' `
    -Message 'Vault query failed; continuing with normal workspace file search.' -QueryBody $null -Mode 'semantic'
