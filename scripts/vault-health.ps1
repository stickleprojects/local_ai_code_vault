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

function Get-BodyValue {
  param(
    [Parameter(Mandatory)]$Body,
    [Parameter(Mandatory)][string]$Key
  )
  if ($Body -is [hashtable]) {
    if ($Body.ContainsKey($Key)) { return $Body[$Key] }
    return $null
  }
  if ($null -eq $Body) { return $null }
  $prop = $Body.PSObject.Properties[$Key]
  if ($null -eq $prop) { return $null }
  return $prop.Value
}

Write-VaultResult ([ordered]@{
    reachable        = $true
    api_version      = Get-BodyValue -Body $b -Key 'api_version'
    embed_model      = Get-BodyValue -Body $b -Key 'embed_model'
    embed_dim        = Get-BodyValue -Body $b -Key 'embed_dim'
    qdrant_connected = Get-BodyValue -Body $b -Key 'qdrant_connected'
  }) 0
