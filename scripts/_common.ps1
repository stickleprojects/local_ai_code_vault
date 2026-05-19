# Shared helpers for the vault host scripts (AD-4: all logic lives in
# scripts; the skill only delegates). Dot-sourced by every script:
#   . "$PSScriptRoot/_common.ps1"
#
# Contract (see scripts/README.md):
#  * stdout  = exactly one JSON object (machine-readable, for the skill)
#  * stderr  = human/diagnostic text and -Verbose logging
#  * exit    = a stable code from $VaultExit (0 = success)
# On failure scripts STILL print a JSON object {ok:false,error,code} so
# the skill can parse either outcome the same way.
#
# This file deliberately does NOT compute repo_id — that is the sole
# job of repo-id.ps1 (sacred single-source contract). Get-RepoId here
# shells out to that one script so nothing else ever recomputes it.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Stable exit codes — referenced by scripts and documented for the skill.
$script:VaultExit = @{
    Ok            = 0   # success
    Usage         = 2   # bad/missing arguments
    NotGitRepo    = 3   # path is not inside a git work tree
    StackDown     = 4   # vault API unreachable
    NotRegistered = 5   # repo not registered / not indexed yet
    Docker        = 6   # docker missing, image missing, indexer failed
    ApiError      = 7   # API reachable but returned a non-2xx
}

function Get-VaultConfig {
    # All overridable via environment so scripts stay host-agnostic.
    [pscustomobject]@{
        ApiBase      = if ($env:VAULT_API_BASE) { $env:VAULT_API_BASE.TrimEnd('/') } else { 'http://localhost:8000' }
        Network      = if ($env:VAULT_NETWORK)  { $env:VAULT_NETWORK }  else { 'vault_default' }
        IndexerImage = if ($env:VAULT_INDEXER_IMAGE) { $env:VAULT_INDEXER_IMAGE } else { 'vault-indexer:local' }
    }
}

function Write-VaultLog {
    param([string]$Message)
    # -Verbose is a common param; honour it without each script re-plumbing.
    if ($VerbosePreference -eq 'Continue') {
        [Console]::Error.WriteLine("[$(Split-Path -Leaf $PSCommandPath)] $Message")
    }
}

function Write-VaultResult {
    # Emit the single JSON object on stdout and exit. Adds ok/code if absent.
    param([Parameter(Mandatory)] $Object, [int]$Code = 0)
    $h = [ordered]@{}
    if ($Object -isnot [hashtable] -and $Object -isnot [System.Collections.Specialized.OrderedDictionary]) {
        # pscustomobject / parsed JSON -> ordered map we can augment
        foreach ($p in $Object.PSObject.Properties) { $h[$p.Name] = $p.Value }
    } else {
        foreach ($k in $Object.Keys) { $h[$k] = $Object[$k] }
    }
    if (-not $h.Contains('ok'))   { $h['ok']   = ($Code -eq 0) }
    if (-not $h.Contains('code')) { $h['code'] = $Code }
    # Success stream (not [Console]::Out) so a parent script can capture
    # this with `$x = & child.ps1` / `child.ps1 | ConvertFrom-Json`.
    Write-Output ($h | ConvertTo-Json -Depth 12 -Compress)
    exit $Code
}

function Stop-VaultWithError {
    param([Parameter(Mandatory)][string]$Message, [Parameter(Mandatory)][int]$Code, $Extra)
    $h = [ordered]@{ ok = $false; error = $Message; code = $Code }
    if ($Extra) { foreach ($p in $Extra.GetEnumerator()) { $h[$p.Key] = $p.Value } }
    Write-Output ($h | ConvertTo-Json -Depth 12 -Compress)
    exit $Code
}

function Invoke-VaultApi {
    # Returns @{ status=<int>; body=<parsed|null> }. Connection failure
    # (stack down) is mapped to the StackDown contract, not a stack trace.
    param([string]$Method = 'GET', [Parameter(Mandatory)][string]$Path)
    $cfg = Get-VaultConfig
    $uri = "$($cfg.ApiBase)$Path"
    Write-VaultLog "API $Method $uri"
    try {
        $r = Invoke-WebRequest -Method $Method -Uri $uri -SkipHttpErrorCheck `
                -Headers @{ Accept = 'application/json' } -TimeoutSec 30
    } catch {
        Stop-VaultWithError "vault stack unreachable at $($cfg.ApiBase) ($($_.Exception.Message)). Is it up? docker compose up -d" `
            $VaultExit.StackDown
    }
    $body = $null
    if ($r.Content) { try { $body = $r.Content | ConvertFrom-Json } catch { $body = $r.Content } }
    @{ status = [int]$r.StatusCode; body = $body }
}

function Get-RepoId {
    # The ONLY caller path to the repo_id contract from other scripts.
    param([Parameter(Mandatory)][string]$Path)
    $out = & "$PSScriptRoot/repo-id.ps1" -Path $Path -Raw
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($out)) {
        Stop-VaultWithError "could not derive repo_id for '$Path'" $VaultExit.NotGitRepo
    }
    "$out".Trim()
}

function Resolve-GitRoot {
    # Repo root (absolute) or the NotGitRepo contract.
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        Stop-VaultWithError "path does not exist: $Path" $VaultExit.NotGitRepo
    }
    try {
        $root = (& git -C $Path rev-parse --show-toplevel 2>$null)
    } catch { $root = $null }
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($root)) {
        Stop-VaultWithError "not a git repository: $Path (run this from a repo, or git init)" $VaultExit.NotGitRepo
    }
    (Resolve-Path -LiteralPath $root).Path
}

function Get-GitHead {
    param([Parameter(Mandatory)][string]$Path)
    $sha = (& git -C $Path rev-parse HEAD 2>$null)
    if ($LASTEXITCODE -ne 0) { return $null }
    "$sha".Trim()
}

function Get-VaultBodyValue {
    param(
        [Parameter(Mandatory)]$Body,
        [Parameter(Mandatory)][string]$Key
    )
    if ($null -eq $Body) { return $null }
    # Accept hashtable, ordered dictionary, other IDictionary, or object.
    if ($Body -is [hashtable]) {
        if ($Body.ContainsKey($Key)) { return $Body[$Key] }
        return $null
    }
    if ($Body -is [System.Collections.Specialized.OrderedDictionary]) {
        if ($Body.Contains($Key)) { return $Body[$Key] }
        return $null
    }
    if ($Body -is [System.Collections.IDictionary]) {
        if ($Body.Contains($Key)) { return $Body[$Key] }
        return $null
    }
    $prop = $Body.PSObject.Properties[$Key]
    if ($null -eq $prop) { return $null }
    $prop.Value
}

function Get-VaultTokenEstimate {
    # APPROXIMATE token count. This is NOT Claude's tokenizer (that is
    # not available locally), so every number derived from it is an
    # ESTIMATE — never present it as exact. Heuristic: ~4 characters per
    # token, the common rule of thumb for English + code. Chosen for
    # being simple, stable and reproducible (the savings ledger must be
    # deterministic), not for precision.
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return 0 }
    [int][math]::Ceiling($Text.Length / 4.0)
}

function Get-VaultStatsDir {
    # Where the per-repo savings ledger lives. Host-side, OUTSIDE any
    # indexed repo (never write stats into a searched repo / the vault
    # clone). Override with $env:VAULT_STATS_DIR. Created on demand.
    if ($env:VAULT_STATS_DIR) { $base = $env:VAULT_STATS_DIR }
    else {
        $lad = [Environment]::GetFolderPath('LocalApplicationData')
        if ([string]::IsNullOrWhiteSpace($lad)) {
            $lad = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.local/share'
        }
        $base = Join-Path $lad 'vault/stats'
    }
    if (-not (Test-Path -LiteralPath $base)) {
        $null = New-Item -ItemType Directory -Force -Path $base
    }
    $base
}
