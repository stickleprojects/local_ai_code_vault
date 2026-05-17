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
    try {
        $obj = $raw | ConvertFrom-Json -AsHashtable
    } catch {
        $raw = Remove-JsonComments $raw
        try {
            $obj = $raw | ConvertFrom-Json -AsHashtable
        } catch {
            Stop-VaultWithError "Could not parse VS Code settings file '$Path' as JSON/JSONC." $VaultExit.Usage
        }
    }
    if ($obj -is [hashtable]) { return $obj }
    return [ordered]@{}
}

function Remove-JsonComments {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $Text }
    $sb = New-Object System.Text.StringBuilder
    $inString = $false
    $escaped = $false
    $inLineComment = $false
    $inBlockComment = $false
    $backslashChar = '\'[0]
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $ch = $Text[$i]
        $next = if ($i + 1 -lt $Text.Length) { $Text[$i + 1] } else { [char]0 }
        if ($inLineComment) {
            if ($ch -eq "`n") {
                $inLineComment = $false
                [void]$sb.Append($ch)
            } elseif ($ch -eq "`r") {
                [void]$sb.Append($ch)
            }
            continue
        }
        if ($inBlockComment) {
            if ($ch -eq '*' -and $next -eq '/') {
                $inBlockComment = $false
                $i++
            }
            continue
        }
        if (-not $inString -and $ch -eq '/' -and $next -eq '/') {
            $inLineComment = $true
            $i++
            continue
        }
        if (-not $inString -and $ch -eq '/' -and $next -eq '*') {
            $inBlockComment = $true
            $i++
            continue
        }
        [void]$sb.Append($ch)
        if ($inString) {
            if ($escaped) {
                $escaped = $false
            } elseif ($ch -eq $backslashChar) {
                $escaped = $true
            } elseif ($ch -eq '"') {
                $inString = $false
            }
        } elseif ($ch -eq '"') {
            $inString = $true
        }
    }
    $sb.ToString()
}

function Resolve-PythonLaunchSpec {
    $python = Get-Command python -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($python -and $python.Source) {
        return [ordered]@{ command = $python.Source; args = @() }
    }
    $pyLauncher = Get-Command py -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pyLauncher -and $pyLauncher.Source) {
        return [ordered]@{ command = $pyLauncher.Source; args = @('-3') }
    }
    Stop-VaultWithError "No Python interpreter found on PATH (tried 'python' and 'py')." $VaultExit.Usage
}

function Write-JsonObject {
    param([string]$Path, [hashtable]$Object)
    $dir = Split-Path -Parent $Path
    if ($dir) { $null = New-Item -ItemType Directory -Force -Path $dir }
    $backupPath = $null
    if (Test-Path -LiteralPath $Path) {
        $stamp = (Get-Date).ToString('yyyyMMddHHmmss')
        $backupPath = "$Path.vault-backup-$stamp"
        Copy-Item -LiteralPath $Path -Destination $backupPath -Force
    }
    $Object | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path
    [ordered]@{
        rewritten = [bool]$backupPath
        backup_path = $backupPath
    }
}

$cloneRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$settings = if ($SettingsPath) { $SettingsPath } else { Get-DefaultVsCodeSettingsPath }
$mcpServer = Join-Path $cloneRoot 'vault_mcp/vault/server.py'
$mcpSettingsKey = 'mcp.servers'
$legacyMcpSettingsKey = 'chat.mcp.servers'
$pythonLaunch = Resolve-PythonLaunchSpec
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
    if ($settingsObj.Contains($mcpSettingsKey)) {
        $servers = $settingsObj[$mcpSettingsKey]
        if ($servers -is [hashtable] -and $servers.Contains('vault')) {
            $null = $servers.Remove('vault')
        }
        $settingsObj[$mcpSettingsKey] = $servers
    }
    if ($settingsObj.Contains($legacyMcpSettingsKey)) {
        $legacyServers = $settingsObj[$legacyMcpSettingsKey]
        if ($legacyServers -is [hashtable] -and $legacyServers.Contains('vault')) {
            $null = $legacyServers.Remove('vault')
        }
        $settingsObj[$legacyMcpSettingsKey] = $legacyServers
    }

    if ($settingsObj.Contains('github.copilot.chat.codeGeneration.instructions')) {
        $entries = @($settingsObj['github.copilot.chat.codeGeneration.instructions']) |
            Where-Object { -not ($_ -is [hashtable] -and $_.Contains('file') -and $_['file'] -eq $instructionDest) }
        $settingsObj['github.copilot.chat.codeGeneration.instructions'] = @($entries)
    }

    $writeMeta = Write-JsonObject $settings $settingsObj

    if (Test-Path -LiteralPath $instructionDest) { Remove-Item -LiteralPath $instructionDest -Force }
    if (-not $NoPersist -and $IsWindows) {
        [Environment]::SetEnvironmentVariable('VAULT_HOME', $null, 'User')
    }
    $env:VAULT_HOME = $null
    $settingsNotice = $null
    if ($writeMeta.rewritten) {
        $settingsNotice = "settings.json has been rewritten; backup saved to $($writeMeta.backup_path)"
    }
    Write-VaultResult ([ordered]@{
        removed = $true
        settings_path = $settings
        settings_rewritten = $writeMeta.rewritten
        settings_backup_path = $writeMeta.backup_path
        instruction_file = $instructionDest
        settings_notice = $settingsNotice
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

if (-not $settingsObj.Contains($mcpSettingsKey) -or $settingsObj[$mcpSettingsKey] -isnot [hashtable]) {
    $settingsObj[$mcpSettingsKey] = [ordered]@{}
}
$combinedLaunchArgs = @($pythonLaunch.args + @($mcpServer))
$settingsObj[$mcpSettingsKey]['vault'] = [ordered]@{
    command = $pythonLaunch.command
    args    = $combinedLaunchArgs
    env     = [ordered]@{ VAULT_HOME = $cloneRoot }
}
if ($settingsObj.Contains($legacyMcpSettingsKey)) {
    $legacyServers = $settingsObj[$legacyMcpSettingsKey]
    if ($legacyServers -is [hashtable] -and $legacyServers.Contains('vault')) {
        $null = $legacyServers.Remove('vault')
    }
    $settingsObj[$legacyMcpSettingsKey] = $legacyServers
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

$writeMeta = Write-JsonObject $settings $settingsObj

$healthRaw = & pwsh -NoProfile -File (Join-Path $cloneRoot 'scripts/vault-health.ps1') 2>$null
$healthCode = $LASTEXITCODE
$healthJson = $null
if ($healthRaw) {
    try { $healthJson = $healthRaw | ConvertFrom-Json -AsHashtable } catch { $healthJson = $null }
}
if ($null -eq $healthJson) {
    $healthJson = [ordered]@{ ok = ($healthCode -eq 0); code = $healthCode; raw = "$healthRaw" }
}

$settingsNotice = $null
if ($writeMeta.rewritten) {
    $settingsNotice = "settings.json has been rewritten; backup saved to $($writeMeta.backup_path)"
}
Write-VaultResult ([ordered]@{
    installed = $true
    settings_path = $settings
    mcp_server = $mcpServer
    python_command = $pythonLaunch.command
    python_args = @($pythonLaunch.args)
    instruction_file = $instructionDest
    vault_home = $cloneRoot
    persisted = $persisted
    profile_hint = $profileHint
    settings_rewritten = $writeMeta.rewritten
    settings_backup_path = $writeMeta.backup_path
    settings_notice = $settingsNotice
    health = $healthJson
    note = 'restart VS Code/Copilot so user-scope MCP and instructions are reloaded'
}) 0
