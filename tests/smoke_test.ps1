<#
.SYNOPSIS
  Manual end-to-end smoke test (Phase 3 — NOT run in CI).

.DESCRIPTION
  Exercises the real path against the live stack: health → index →
  registered & not stale → semantic query → introspection. This needs
  the GPU `docker compose` stack up (see README_SETUP.md) and the
  indexer image built, so it is a documented manual release gate, not a
  CI job (automating the GPU stack would only re-prove the closed B-1
  path). The pure script logic is covered automatically by
  `tests/scripts.Tests.ps1` (the `pester` CI job).

  Dogfoods the host scripts (it is itself a check that they compose).
  Exits 0 only if every step passes; non-zero with the failing step.

.PARAMETER Path
  Repo to index/query (default: this repository).

.EXAMPLE
  pwsh -NoProfile -File tests/smoke_test.ps1
#>
[CmdletBinding()]
param([string]$Path = (Join-Path $PSScriptRoot '..'))

$ErrorActionPreference = 'Stop'
$scripts = Join-Path $PSScriptRoot '..' 'scripts' | Resolve-Path
$repo = (Resolve-Path $Path).Path
$fail = 0

function Step {
    param([string]$Name, [scriptblock]$Body)
    Write-Host "→ $Name" -ForegroundColor Cyan
    try {
        & $Body
        Write-Host "  OK" -ForegroundColor Green
    } catch {
        Write-Host "  FAIL: $($_.Exception.Message)" -ForegroundColor Red
        $script:fail++
    }
}

function Invoke-VaultScript {
    param([string]$Name, [string[]]$VArgs = @())
    $out = & pwsh -NoProfile -File (Join-Path $scripts $Name) @VArgs
    $code = $LASTEXITCODE
    $json = $null
    try { $json = ($out -join "`n") | ConvertFrom-Json } catch {}
    [pscustomobject]@{ Code = $code; Json = $json; Raw = ($out -join "`n") }
}

Step 'stack health' {
    $r = Invoke-VaultScript 'vault-health.ps1'
    if ($r.Code -ne 0) { throw "vault-health exit $($r.Code): $($r.Raw)" }
    if (-not $r.Json.qdrant_connected) { throw 'qdrant not connected' }
    if ($r.Json.embed_dim -ne 3584) { throw "embed_dim=$($r.Json.embed_dim), expected 3584" }
}

Step 'index (build + wait)' {
    $r = Invoke-VaultScript 'index-repo.ps1' @($repo, '-Build', '-Wait')
    if ($r.Code -ne 0) { throw "index-repo exit $($r.Code): $($r.Raw)" }
    if ($r.Json.indexer.chunks -lt 1) { throw "indexer wrote $($r.Json.indexer.chunks) chunks" }
    Write-Host "  files=$($r.Json.indexer.files) chunks=$($r.Json.indexer.chunks) skipped=$($r.Json.indexer.skipped)"
}

Step 'registered & not stale' {
    $r = Invoke-VaultScript 'vault-status.ps1' @($repo)
    if ($r.Code -ne 0) { throw "vault-status exit $($r.Code)" }
    if (-not $r.Json.registered) { throw 'repo not registered after indexing' }
    if ($r.Json.stale) { throw 'repo reported stale immediately after a full index' }
}

Step 'semantic query returns hits' {
    $r = Invoke-VaultScript 'query.ps1' @('how is the canonical repo_id computed', $repo, '-Limit', '3')
    if ($r.Code -ne 0) { throw "query exit $($r.Code): $($r.Raw)" }
    if ($r.Json.count -lt 1) { throw 'query returned no results' }
    $r.Json.results | ForEach-Object { Write-Host ("  {0,-30} {1:N3}" -f $_.path, $_.score) }
}

Step 'inspect reports counts' {
    $r = Invoke-VaultScript 'vault-inspect.ps1' @($repo)
    if ($r.Code -ne 0) { throw "vault-inspect exit $($r.Code)" }
    if ($r.Json.stats.chunk_count -lt 1) { throw 'inspect reports 0 chunks' }
    Write-Host "  file_count=$($r.Json.stats.file_count) chunk_count=$($r.Json.stats.chunk_count)"
}

Write-Host ''
if ($fail -gt 0) {
    Write-Host "SMOKE TEST FAILED ($fail step(s))" -ForegroundColor Red
    exit 1
}
Write-Host 'SMOKE TEST PASSED' -ForegroundColor Green
exit 0
