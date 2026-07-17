# Optional: install the claudex-aware statusline for Claude Code.
# Copies the statusline scripts to ~\.claude and wires settings.json if no
# statusLine is configured yet. Existing files are backed up, never deleted.
#
# Segments rendered:
#   model name + magenta "claudex:GPT-..." marker when running through the proxy
#   cwd | git branch (dirty *) | context bar with exact % from Claude Code
#   A:5h/wk   Anthropic budget LEFT (session + week) as bars, from live payload
#   X:wk/spk  Codex budget LEFT (week + spark meter) as bars, cached 30 min
#   th:<lvl>  thinking/effort level
#   wk $N     estimated week spend via ccusage (optional - needs ccusage on PATH)
#
# Usage: powershell -ExecutionPolicy Bypass -File statusline\install-statusline.ps1

$ErrorActionPreference = "Stop"
$src = $PSScriptRoot
$dest = Join-Path $HOME ".claude"
New-Item -ItemType Directory -Force $dest | Out-Null

foreach ($f in @("statusline.ps1", "statusline-codex-refresh.ps1", "statusline-spend-refresh.ps1")) {
    $target = Join-Path $dest $f
    if (Test-Path $target) {
        Copy-Item $target "$target.bak-claudex" -Force
        Write-Host ">> backed up existing $f -> $f.bak-claudex"
    }
    Copy-Item (Join-Path $src $f) $target -Force
    Write-Host ">> installed $f"
}

# Wire settings.json only if no statusLine is configured
$settingsPath = Join-Path $dest "settings.json"
$cmd = "powershell -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$($dest -replace '\\', '\\')\\statusline.ps1`""
if (Test-Path $settingsPath) {
    $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
    if ($settings.PSObject.Properties.Name -contains "statusLine") {
        Write-Host ">> settings.json already has a statusLine - left untouched. To use this one, point its command at:"
        Write-Host "   $dest\statusline.ps1"
    } else {
        Copy-Item $settingsPath "$settingsPath.bak-claudex" -Force
        $settings | Add-Member -NotePropertyName "statusLine" -NotePropertyValue ([pscustomobject]@{
            type = "command"
            command = "powershell -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$dest\statusline.ps1`""
        })
        $json = $settings | ConvertTo-Json -Depth 20
        [System.IO.File]::WriteAllText($settingsPath, $json, [System.Text.UTF8Encoding]::new($false))
        Write-Host ">> statusLine wired into settings.json (backup: settings.json.bak-claudex)"
    }
} else {
    $json = @{ statusLine = @{ type = "command"; command = "powershell -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$dest\statusline.ps1`"" } } | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($settingsPath, $json, [System.Text.UTF8Encoding]::new($false))
    Write-Host ">> created settings.json with statusLine"
}

Write-Host ">> done - statusline appears on the next Claude Code render (new session or next message)"
