<#
.SYNOPSIS
  Is the vault stack reachable? (GET /api/status)

.DESCRIPTION
  Exit 0 + JSON status body when the API answers 200; exit 4
  (StackDown) with actionable guidance otherwise. No repo context
  needed — this is the first check the skill runs.
#>
[CmdletBinding()]
param()

. "$PSScriptRoot/_common.ps1"

$r = Invoke-VaultApi -Path '/api/status'   # connection failure -> exit 4 here

if ($r.status -ne 200) {
    Stop-VaultWithError "vault API returned HTTP $($r.status) on /api/status" $VaultExit.StackDown
}

$b = $r.body
Write-VaultResult ([ordered]@{
    reachable       = $true
    api_version     = $b.api_version
    embed_model     = $b.embed_model
    embed_dim       = $b.embed_dim
    qdrant_connected = $b.qdrant_connected
}) 0
