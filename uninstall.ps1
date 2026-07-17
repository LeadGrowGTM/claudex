# claudex uninstaller. Stops the proxy, removes autostart and the profile
# function. Deliberately does NOT delete binaries, config, keys, or OAuth
# credentials - those are printed at the end for manual cleanup.

$ErrorActionPreference = "Continue"
$markerStart = "# >>> claudex >>>"
$markerEnd   = "# <<< claudex <<<"

$proc = Get-Process cli-proxy-api -ErrorAction SilentlyContinue
if ($proc) { $proc | Stop-Process -Force; Write-Host ">> proxy stopped" }

$startup = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup\CLIProxyAPI.vbs"
if (Test-Path $startup) { Remove-Item $startup; Write-Host ">> autostart removed" }

$hostProfile = "$env:USERPROFILE\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1"
foreach ($profilePath in @($hostProfile, $PROFILE.CurrentUserAllHosts)) {
    if ($profilePath -and (Test-Path $profilePath)) {
        $existing = Get-Content $profilePath -Raw
        $pattern = "(?s)`r?`n?" + [regex]::Escape($markerStart) + ".*?" + [regex]::Escape($markerEnd) + "`r?`n?"
        $cleaned = [regex]::Replace($existing, $pattern, "")
        if ($cleaned -ne $existing) {
            [System.IO.File]::WriteAllText($profilePath, $cleaned, [System.Text.UTF8Encoding]::new($false))
            Write-Host ">> claudex function removed from $profilePath"
        }
    }
}

Write-Host ""
Write-Host "Left in place (remove manually if desired):"
Write-Host "  $env:USERPROFILE\.cliproxyapi        (binary, config, proxy key)"
Write-Host "  $env:USERPROFILE\.cli-proxy-api      (Codex OAuth credential + logs)"
