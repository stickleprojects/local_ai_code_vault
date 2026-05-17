<#
.SYNOPSIS
  Compute the canonical repo_id — the SINGLE source of truth (AD-2).

.DESCRIPTION
  repo_id = slug(basename(repo_root)) + "-" + sha1(normalized_abs_root)[:8]

  This is a sacred contract: NOTHING else computes repo_id. The indexer,
  registry collection name, vault-status, query, and git hooks all
  resolve it through this one script so "is it registered" / "is it
  stale" / "where do results come from" can never disagree.

  Normalization of the repo root path (must stay stable across sessions
  and identical for the same repo regardless of how the user typed the
  path; Windows filesystems are case-insensitive):
    1. repo_root = `git rev-parse --show-toplevel` (so a subdirectory
       resolves to the same id as the root)
    2. absolute path, backslashes -> '/', trailing '/' removed
    3. lower-cased (invariant)
    4. sha1 of its UTF-8 bytes, first 8 hex chars (lower)
  slug(basename): lower-case, any run of non [a-z0-9] -> '-', trimmed.

.PARAMETER Path
  A path inside the repo (default: current directory).

.PARAMETER Raw
  Print only the repo_id string (for hooks/other scripts). Default
  output is a JSON object.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Path = '.',
    [switch]$Raw
)

. "$PSScriptRoot/_common.ps1"

$root = Resolve-GitRoot -Path $Path          # absolute repo root or exit 3

$norm = ($root -replace '\\', '/').TrimEnd('/').ToLowerInvariant()
$sha1 = [System.Security.Cryptography.SHA1]::Create().ComputeHash(
            [System.Text.Encoding]::UTF8.GetBytes($norm))
$hex  = -join ($sha1 | ForEach-Object { $_.ToString('x2') })

$base = Split-Path -Leaf $root
$slug = ($base.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
if ([string]::IsNullOrEmpty($slug)) { $slug = 'repo' }

$repoId = "$slug-$($hex.Substring(0, 8))"

if ($Raw) {
    Write-Output $repoId      # success stream so Get-RepoId can capture it
    exit 0
}

Write-VaultResult ([ordered]@{
    repo_id         = $repoId
    repo_root       = $root
    normalized_path = $norm
    slug            = $slug
}) 0
