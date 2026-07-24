# Switch installed CLIProxyAPI role-effort behavior for controlled benchmarks.
# Backs up only the non-secret effort block and full-config hash. Never copies or
# prints the key-bearing proxy config.

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("P0", "P1", "P2")]
    [string]$Profile,
    [string]$ConfigPath = "$env:USERPROFILE\.cliproxyapi\cliproxyapi.conf",
    [string]$BackupRoot = "$env:USERPROFILE\.cliproxyapi\archive"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $ConfigPath)) { throw "proxy config not found: $ConfigPath" }

$raw = [System.IO.File]::ReadAllText($ConfigPath)
$newline = if ($raw.Contains("`r`n")) { "`r`n" } else { "`n" }
$legacyBlock = @'
payload:
  override:
    # Max effort for the 5.6 tier (sol + terra) - spark stays fast/default
    - models:
        - name: "gpt-5.6-*"
          protocol: "codex"
      params:
        "reasoning.effort": "max"
'@
$legacyBlock = ($legacyBlock.TrimEnd([char[]]"`r`n") -replace "`r?`n", $newline) + $newline
$legacyCount = ([regex]::Matches($raw, [regex]::Escape($legacyBlock))).Count
$hasAnyPayload = $raw -match '(?m)^payload:\s*$'
$hasWildcardEffort = $raw -match '(?ms)name:\s*"gpt-5\.6-\*".*?"reasoning\.effort":\s*"max"'

if ($legacyCount -gt 1) { throw "expected at most one canonical gpt-5.6 effort block; found $legacyCount" }
if ($legacyCount -eq 0 -and ($hasAnyPayload -or $hasWildcardEffort)) {
    throw "proxy payload differs from the canonical benchmark block; refusing to modify it"
}

$targetUsesWildcard = $Profile -eq "P0"
if (($targetUsesWildcard -and $legacyCount -eq 1) -or (-not $targetUsesWildcard -and $legacyCount -eq 0)) {
    Write-Host "effort profile already matches $Profile; no file changed"
    return
}

$beforeHash = (Get-FileHash $ConfigPath -Algorithm SHA256).Hash.ToLowerInvariant()
$stamp = Get-Date -Format "yyyyMMdd-HHmmss-fff"
$backupBase = Join-Path $BackupRoot "$stamp-$PID-$Profile-effort-profile"
$backupDir = $backupBase
$suffix = 1
while (Test-Path $backupDir) {
    $backupDir = "$backupBase-$suffix"
    $suffix++
}
New-Item -ItemType Directory -Path $backupDir | Out-Null
$backupPath = Join-Path $backupDir "effort-profile.json"
$backup = [ordered]@{
    configPath = $ConfigPath
    configSha256 = $beforeHash
    profileBefore = $(if ($legacyCount -eq 1) { "P0" } else { "passthrough" })
    effortBlock = $(if ($legacyCount -eq 1) { $legacyBlock } else { "" })
}
[System.IO.File]::WriteAllText(
    $backupPath,
    ($backup | ConvertTo-Json -Depth 3),
    [System.Text.UTF8Encoding]::new($false)
)

if ($targetUsesWildcard) {
    $updated = $raw.TrimEnd([char[]]"`r`n") + $newline + $legacyBlock
} else {
    $updated = $raw.Replace($legacyBlock, "")
}

[System.IO.File]::WriteAllText(
    $ConfigPath,
    $updated,
    [System.Text.UTF8Encoding]::new($false)
)

$after = [System.IO.File]::ReadAllText($ConfigPath)
$afterCount = ([regex]::Matches($after, [regex]::Escape($legacyBlock))).Count
if (($targetUsesWildcard -and $afterCount -ne 1) -or (-not $targetUsesWildcard -and $afterCount -ne 0)) {
    throw "effort profile verification failed after write; backup: $backupPath"
}

$afterHash = (Get-FileHash $ConfigPath -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Host "effort profile set to $Profile"
Write-Host "non-secret backup: $backupPath"
Write-Host "config SHA256: $beforeHash -> $afterHash"
Write-Host "restart CLIProxyAPI normally before benchmarking"
