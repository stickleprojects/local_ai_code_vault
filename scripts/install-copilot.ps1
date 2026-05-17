<#
.SYNOPSIS
  Install (or remove) global Copilot Vault MCP integration.

.DESCRIPTION
  One-time user-scope setup for Copilot:
   1) records VAULT_HOME (same source used by Claude install);
   2) registers the Vault MCP server in VS Code user settings;
   3) installs global Copilot instruction assets in user scope;
   4) runs a post-install vault health check.

  This does not modify project repos and does not alter Claude setup.
  It shares the same script contracts used by the Claude skill so both
  adapters stay aligned without duplicated vault logic.

.PARAMETER SettingsPath
  VS Code user settings.json path (defaults by OS).

.PARAMETER InstructionsRoot
  User-scope instruction install root (default: ~/.copilot/instructions).

.PARAMETER Remove
  Remove Copilot registration + installed instruction file.

.PARAMETER NoPersist
  Do not persist VAULT_HOME to user environment (process scope only).
#>
[CmdletBinding()]
param(
    [string]$SettingsPath,
    [string]$InstructionsRoot = (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.copilot/instructions'),
    [switch]$Remove,
    [switch]$NoPersist
)

. "$PSScriptRoot/_common.ps1"

function Get-DefaultVsCodeSettingsPath {
    if ($IsWindows) {
        return Join-Path $env:APPDATA 'Code/User/settings.json'
    }
    if ($IsMacOS) {
        return Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Library/Application Support/Code/User/settings.json'
    }
    return Join-Path ([Environment]::GetFolderPath('UserProfile')) '.config/Code/User/settings.json'
}

function Read-JsonObject {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return [ordered]@{} }
    $raw = (Get-Content -Raw -LiteralPath $Path)
    if ([string]::IsNullOrWhiteSpace($raw)) { return [ordered]@{} }
    $obj = $raw | ConvertFrom-Json -AsHashtable
    if ($obj -is [hashtable]) { return $obj }
    return [ordered]@{}
}

function Write-JsonObject {
    param([string]$Path, [hashtable]$Object)
    $dir = Split-Path -Parent $Path
    if ($dir) { $null = New-Item -ItemType Directory -Force -Path $dir }
    $Object | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path
}

$cloneRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$settings = if ($SettingsPath) { $SettingsPath } else { Get-DefaultVsCodeSettingsPath }
$mcpServer = Join-Path $cloneRoot 'mcp/vault/server.py'
$instructionSource = Join-Path $cloneRoot 'copilot/instructions/vault-global.instructions.md'
$instructionDir = Join-Path $InstructionsRoot 'vault'
$instructionDest = Join-Path $instructionDir 'vault-global.instructions.md'

if (-not (Test-Path -LiteralPath $mcpServer)) {
    Stop-VaultWithError "vault MCP server not found at $mcpServer" $VaultExit.Usage
}
if (-not (Test-Path -LiteralPath $instructionSource)) {
    Stop-VaultWithError "Copilot instruction asset not found at $instructionSource" $VaultExit.Usage
}

$settingsObj = Read-JsonObject $settings

if ($Remove) {
    if ($settingsObj.Contains('chat.mcp.servers')) {
        $servers = $settingsObj['chat.mcp.servers']
        if ($servers -is [hashtable] -and $servers.Contains('vault')) {
            $null = $servers.Remove('vault')
        }
        $settingsObj['chat.mcp.servers'] = $servers
    }

    if ($settingsObj.Contains('github.copilot.chat.codeGeneration.instructions')) {
        $entries = @($settingsObj['github.copilot.chat.codeGeneration.instructions']) |
            Where-Object { -not ($_ -is [hashtable] -and $_.Contains('file') -and $_['file'] -eq $instructionDest) }
        $settingsObj['github.copilot.chat.codeGeneration.instructions'] = @($entries)
    }

    Write-JsonObject $settings $settingsObj

    if (Test-Path -LiteralPath $instructionDest) { Remove-Item -LiteralPath $instructionDest -Force }
    if (-not $NoPersist -and $IsWindows) {
        [Environment]::SetEnvironmentVariable('VAULT_HOME', $null, 'User')
    }
    $env:VAULT_HOME = $null
    Write-VaultResult ([ordered]@{
        removed = $true
        settings_path = $settings
        instruction_file = $instructionDest
    }) 0
}

$env:VAULT_HOME = $cloneRoot
$persisted = $false
$profileHint = $null
if (-not $NoPersist) {
    if ($IsWindows) {
        [Environment]::SetEnvironmentVariable('VAULT_HOME', $cloneRoot, 'User')
        $persisted = $true
    } else {
        $profileHint = "export VAULT_HOME='$cloneRoot'   # add to ~/.bashrc or ~/.zshrc"
    }
}

$null = New-Item -ItemType Directory -Force -Path $instructionDir
Copy-Item -LiteralPath $instructionSource -Destination $instructionDest -Force

if (-not $settingsObj.Contains('chat.mcp.servers') -or $settingsObj['chat.mcp.servers'] -isnot [hashtable]) {
    $settingsObj['chat.mcp.servers'] = [ordered]@{}
}
$settingsObj['chat.mcp.servers']['vault'] = [ordered]@{
    command = 'python'
    args    = @($mcpServer)
    env     = [ordered]@{ VAULT_HOME = $cloneRoot }
}

$instructionEntry = [ordered]@{ file = $instructionDest }
$existingInstructions = @()
if ($settingsObj.Contains('github.copilot.chat.codeGeneration.instructions')) {
    $existingInstructions = @($settingsObj['github.copilot.chat.codeGeneration.instructions'])
}
$hasInstruction = $false
foreach ($entry in $existingInstructions) {
    if ($entry -is [hashtable] -and $entry.Contains('file') -and $entry['file'] -eq $instructionDest) {
        $hasInstruction = $true
        break
    }
}
if (-not $hasInstruction) { $existingInstructions += $instructionEntry }
$settingsObj['github.copilot.chat.codeGeneration.instructions'] = @($existingInstructions)

Write-JsonObject $settings $settingsObj

$healthRaw = & pwsh -NoProfile -File (Join-Path $cloneRoot 'scripts/vault-health.ps1') 2>$null
$healthCode = $LASTEXITCODE
$healthJson = $null
if ($healthRaw) {
    try { $healthJson = $healthRaw | ConvertFrom-Json -AsHashtable } catch { $healthJson = $null }
}
if ($null -eq $healthJson) {
    $healthJson = [ordered]@{ ok = ($healthCode -eq 0); code = $healthCode; raw = "$healthRaw" }
}

Write-VaultResult ([ordered]@{
    installed = $true
    settings_path = $settings
    mcp_server = $mcpServer
    instruction_file = $instructionDest
    vault_home = $cloneRoot
    persisted = $persisted
    profile_hint = $profileHint
    health = $healthJson
    note = 'restart VS Code/Copilot so user-scope MCP and instructions are reloaded'
}) 0
