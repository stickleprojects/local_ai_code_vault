<#
.SYNOPSIS
  Install (or remove) the vault skill so /vault-* works in ANY repo.

.DESCRIPTION
  The host scripts live in exactly one clone of this repo and are
  self-locating — they are never copied per project. The Claude skill,
  however, must sit where Claude Code discovers skills and must invoke
  the scripts at their canonical absolute location, not relative to
  whatever repo you happen to be in.

  This script, run ONCE:
   1. copies `SKILL.md` to `<SkillsRoot>/vault/SKILL.md`
      (default `~/.claude/skills/vault/` — personal scope, all repos);
   2. records `VAULT_HOME` = this clone's root so the skill can resolve
      `$env:VAULT_HOME/scripts/*.ps1` from any working directory
      (persisted to the Windows User environment unless -NoPersist; on
      non-Windows it sets the process var and prints the line to add to
      your shell profile).

  Re-run it after moving/updating the clone. `-Remove` uninstalls.
  Idempotent.

.PARAMETER SkillsRoot  Skills directory (default: ~/.claude/skills).
.PARAMETER Remove      Uninstall the skill and stop here.
.PARAMETER NoPersist   Do not persist VAULT_HOME (process scope only).
#>
[CmdletBinding()]
param(
    [string]$SkillsRoot = (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.claude/skills'),
    [switch]$Remove,
    [switch]$NoPersist
)

. "$PSScriptRoot/_common.ps1"

$cloneRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$skillDir  = Join-Path $SkillsRoot 'vault'
$dest      = Join-Path $skillDir 'SKILL.md'
$source    = Join-Path $cloneRoot 'SKILL.md'

if ($Remove) {
    $existed = Test-Path -LiteralPath $skillDir
    if ($existed) { Remove-Item -LiteralPath $skillDir -Recurse -Force }
    if (-not $NoPersist -and $IsWindows) {
        [Environment]::SetEnvironmentVariable('VAULT_HOME', $null, 'User')
    }
    $env:VAULT_HOME = $null
    Write-VaultResult ([ordered]@{
        removed     = $true
        skill_dir   = $skillDir
        was_present = [bool]$existed
    }) 0
}

if (-not (Test-Path -LiteralPath $source)) {
    Stop-VaultWithError "SKILL.md not found at $source (is this a full clone?)" $VaultExit.Usage
}

$null = New-Item -ItemType Directory -Force -Path $skillDir
Copy-Item -LiteralPath $source -Destination $dest -Force

# Bake the absolute scripts dir into the installed skill. The skill must
# invoke scripts with a LITERAL path via `&` (no `pwsh -NoProfile -File`
# child process, no `$env:` expression) so Claude Code does not prompt on
# every call. The repo SKILL.md ships the `{{VAULT_SCRIPTS}}` placeholder;
# only the installed copy gets the machine-specific path. .Replace() is a
# literal (non-regex) substitution — safe for Windows backslash paths.
$scriptsDir = (Resolve-Path -LiteralPath $PSScriptRoot).Path
$skillText  = [IO.File]::ReadAllText($dest)
$skillText  = $skillText.Replace('{{VAULT_SCRIPTS}}', $scriptsDir)
if ($skillText -match '\{\{VAULT_SCRIPTS\}\}') {
    Stop-VaultWithError "placeholder substitution failed in $dest" $VaultExit.Usage
}
[IO.File]::WriteAllText($dest, $skillText)

# VAULT_HOME: process scope now (usable this session) + persisted so
# new Claude Code processes inherit it.
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

Write-VaultResult ([ordered]@{
    installed   = $true
    skill_dir   = $skillDir
    vault_home  = $cloneRoot
    persisted   = $persisted
    profile_hint = $profileHint
    scripts_dir = $scriptsDir
    note        = 'restart Claude Code so it discovers the skill and inherits VAULT_HOME'
}) 0
