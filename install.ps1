# claudex installer (Windows, PowerShell 5.1+)
# Sets up: CLIProxyAPI binary + config + proxy key + autostart + `claudex`
# PowerShell profile function. Idempotent - safe to re-run for upgrades.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File install.ps1
#   ... -Version 7.2.83     pin a CLIProxyAPI release (default below)
#   ... -SkipLogin          skip the interactive Codex OAuth step
#   ... -SkipAutostart      don't register the Startup-folder launcher
#   ... -SkipProfile        don't touch the PowerShell profile

param(
    [string]$Version = "7.2.83",
    [switch]$SkipLogin,
    [switch]$SkipAutostart,
    [switch]$SkipProfile
)

$ErrorActionPreference = "Stop"
$repoRoot = $PSScriptRoot
$proxyDir = "$env:USERPROFILE\.cliproxyapi"
$authDir  = "$env:USERPROFILE\.cli-proxy-api"
$markerStart = "# >>> claudex >>>"
$markerEnd   = "# <<< claudex <<<"

function Step($msg) { Write-Host ">> $msg" -ForegroundColor Cyan }
function Warn($msg) { Write-Host "!! $msg" -ForegroundColor Yellow }

# --- 0. prereq checks -------------------------------------------------------
if ($PSVersionTable.PSVersion.Major -lt 5) { throw "PowerShell 5.1+ required (found $($PSVersionTable.PSVersion))" }

$claudeFound = $null
$cmdCheck = Get-Command "claude.exe" -ErrorAction SilentlyContinue
if ($cmdCheck) { $claudeFound = $cmdCheck.Source }
elseif (Test-Path "$env:USERPROFILE\.local\bin\claude.exe") { $claudeFound = "$env:USERPROFILE\.local\bin\claude.exe" }
if ($claudeFound) { Step "claude CLI found: $claudeFound" }
else { Warn "claude CLI not found - install Claude Code first (https://claude.com/claude-code). Proxy setup will proceed; claudex won't work until claude is installed." }

# port 8317 must be free or already owned by cli-proxy-api
$portConn = Get-NetTCPConnection -LocalPort 8317 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
if ($portConn) {
    $portOwner = (Get-Process -Id $portConn.OwningProcess -ErrorAction SilentlyContinue).ProcessName
    if ($portOwner -ne "cli-proxy-api") {
        throw "port 8317 is already in use by '$portOwner' - stop it or change the port in config\cliproxyapi.conf.template and the profile function before installing"
    }
}

# --- 1. proxy binary -------------------------------------------------------
New-Item -ItemType Directory -Force $proxyDir | Out-Null
$exe = "$proxyDir\cli-proxy-api.exe"
if (Test-Path $exe) {
    Step "binary already present: $exe (delete it to force re-download)"
} else {
    $asset = "CLIProxyAPI_${Version}_windows_amd64.zip"
    $url = "https://github.com/router-for-me/CLIProxyAPI/releases/download/v$Version/$asset"
    $zip = "$env:TEMP\$asset"
    Step "downloading $url"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
    $extract = "$env:TEMP\claudex-extract-$Version"
    if (Test-Path $extract) { Remove-Item $extract -Recurse -Force }
    Expand-Archive -Path $zip -DestinationPath $extract
    $found = Get-ChildItem $extract -Recurse -Filter "*.exe" | Select-Object -First 1
    if (-not $found) { throw "no .exe found inside $asset" }
    Copy-Item $found.FullName $exe
    Step "installed binary -> $exe"
}

# --- 2. proxy key ----------------------------------------------------------
$keyPath = "$proxyDir\.proxykey"
if (Test-Path $keyPath) {
    Step "proxy key already exists"
} else {
    $bytes = New-Object byte[] 24
    $rng = [System.Security.Cryptography.RNGCryptoServiceProvider]::new()
    $rng.GetBytes($bytes)
    $key = ($bytes | ForEach-Object { $_.ToString("x2") }) -join ""
    [System.IO.File]::WriteAllText($keyPath, $key, [System.Text.UTF8Encoding]::new($false))
    Step "generated proxy key -> $keyPath"
}

# --- 3. config -------------------------------------------------------------
$confPath = "$proxyDir\cliproxyapi.conf"
if (Test-Path $confPath) {
    Step "config already exists: $confPath (not overwritten - diff against config\cliproxyapi.conf.template for updates)"
    $confRaw = Get-Content $confPath -Raw
    if ($confRaw -notmatch 'alias:\s*"claude-opus-4-8"' -or $confRaw -notmatch 'alias:\s*"claude-haiku-4-5"') {
        Warn "existing config is MISSING the model aliases - claudex will get the trimmed Claude Code harness (no skill descriptions)."
        Warn "merge the oauth-model-alias block from config\cliproxyapi.conf.template, then restart the proxy. Verify with doctor.ps1."
    }
} else {
    $key = (Get-Content $keyPath -Raw).Trim()
    $conf = (Get-Content "$repoRoot\config\cliproxyapi.conf.template" -Raw).Replace("__PROXY_KEY__", $key)
    [System.IO.File]::WriteAllText($confPath, $conf, [System.Text.UTF8Encoding]::new($false))
    Step "wrote config -> $confPath"
}

# --- 4. autostart ----------------------------------------------------------
if (-not $SkipAutostart) {
    $vbs = "$proxyDir\start-hidden.vbs"
    $vbsContent = "CreateObject(""Wscript.Shell"").Run """"""$exe"""" -config """"$confPath"""""", 0, False"
    [System.IO.File]::WriteAllText($vbs, $vbsContent, [System.Text.UTF8Encoding]::new($false))
    $startup = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup\CLIProxyAPI.vbs"
    Copy-Item $vbs $startup -Force
    Step "autostart registered -> $startup"
}

# --- 5. PowerShell profile function -----------------------------------------
if (-not $SkipProfile) {
    $profilePath = $PROFILE.CurrentUserAllHosts
    if (-not $profilePath) { $profilePath = "$env:USERPROFILE\Documents\WindowsPowerShell\profile.ps1" }
    # Prefer the classic per-host profile if it already exists (common setup)
    $hostProfile = "$env:USERPROFILE\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1"
    if (Test-Path $hostProfile) { $profilePath = $hostProfile }
    if (-not (Test-Path $profilePath)) {
        New-Item -ItemType File -Force $profilePath | Out-Null
    }
    $existing = Get-Content $profilePath -Raw
    if ($null -eq $existing) { $existing = "" }
    # Remove any previous claudex block, then append the current one
    $pattern = "(?s)`r?`n?" + [regex]::Escape($markerStart) + ".*?" + [regex]::Escape($markerEnd) + "`r?`n?"
    $existing = [regex]::Replace($existing, $pattern, "")
    $fn = Get-Content "$repoRoot\profile\claudex-function.ps1" -Raw
    $block = "`r`n$markerStart`r`n$fn$markerEnd`r`n"
    [System.IO.File]::WriteAllText($profilePath, $existing.TrimEnd() + "`r`n" + $block, [System.Text.UTF8Encoding]::new($false))
    Step "claudex function installed into $profilePath (marker-delimited, re-run to upgrade)"
}

# --- 6. start proxy ---------------------------------------------------------
if (-not (Get-Process cli-proxy-api -ErrorAction SilentlyContinue)) {
    Start-Process -FilePath $exe -ArgumentList "-config", $confPath -WorkingDirectory $proxyDir -WindowStyle Hidden
    Start-Sleep -Seconds 2
    Step "proxy started"
} else {
    Step "proxy already running (restart it to pick up config changes: Get-Process cli-proxy-api | Stop-Process; then re-run install.ps1)"
}

# --- 7. Codex OAuth ---------------------------------------------------------
$cred = Get-ChildItem $authDir -Filter "codex-*.json" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($cred) {
    Step "Codex credential already present: $($cred.Name)"
} elseif ($SkipLogin) {
    Step "SKIPPED login - run '$exe -codex-login' manually before first use"
} else {
    Step "launching Codex OAuth login (browser will open, sign in with your ChatGPT account)..."
    & $exe -codex-login
}

# --- 8. smoke test ----------------------------------------------------------
$claudeBin = $null
$cmd = Get-Command "claude.exe" -ErrorAction SilentlyContinue
if ($cmd) { $claudeBin = $cmd.Source }
elseif (Test-Path "$env:USERPROFILE\.local\bin\claude.exe") { $claudeBin = "$env:USERPROFILE\.local\bin\claude.exe" }

$credNow = Get-ChildItem $authDir -Filter "codex-*.json" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($claudeBin -and $credNow) {
    Step "smoke test (flagship + fast tier)..."
    # native-command stderr under EAP=Stop in PS 5.1 becomes a terminating
    # error; relax for the smoke calls only
    $ErrorActionPreference = "Continue"
    $origBase = $env:ANTHROPIC_BASE_URL; $origTok = $env:ANTHROPIC_AUTH_TOKEN; $origFp = $env:_CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL
    try {
        $env:ANTHROPIC_BASE_URL = "http://127.0.0.1:8317"
        $env:ANTHROPIC_AUTH_TOKEN = (Get-Content $keyPath -Raw).Trim()
        $env:_CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL = "1"
        $r1 = & $claudeBin --model claude-opus-4-8 -p "Reply with the single word: ok" 2>$null
        $r2 = & $claudeBin --model claude-haiku-4-5 -p "Reply with the single word: ok" 2>$null
    } finally {
        $env:ANTHROPIC_BASE_URL = $origBase; $env:ANTHROPIC_AUTH_TOKEN = $origTok; $env:_CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL = $origFp
    }
    if ("$r1".Trim() -eq "ok" -and "$r2".Trim() -eq "ok") {
        Write-Host ">> SMOKE TEST PASSED - open a NEW shell and run: claudex" -ForegroundColor Green
    } else {
        Write-Host ">> SMOKE TEST FAILED (flagship='$r1' fast='$r2') - check the proxy is running and the Codex login completed" -ForegroundColor Red
    }
} else {
    Step "smoke test skipped (claude CLI or Codex credential missing). When ready: open a new shell and run claudex"
}
