# claudex installer (Windows, PowerShell 5.1+)
# Sets up: CLIProxyAPI binary + config + proxy key + autostart + `claudex`
# PowerShell profile function. Idempotent - safe to re-run for upgrades.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File install.ps1
#   ... -Version 7.2.83     pin a CLIProxyAPI release (default below)
#   ... -NativeCompaction   build and activate the pinned Codex compaction bridge
#   ... -StableProxy        return to the official release without deleting the bridge
#   ... -SkipLogin          skip the interactive Codex OAuth step
#   ... -SkipAutostart      don't register the Startup-folder launcher
#   ... -SkipProfile        don't touch the PowerShell profile

param(
    [string]$Version = "7.2.83",
    [switch]$NativeCompaction,
    [switch]$StableProxy,
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
$nativeCompactionRepo = "https://github.com/Johnnybyzhang/CLIProxyAPI.git"
$nativeCompactionCommit = "725aa9f1bd61c76edb315ae80c7be6215198621a"
$nativeCompactionDir = "$proxyDir\native-compaction-$nativeCompactionCommit"
$nativeCompactionExe = "$nativeCompactionDir\cli-proxy-api.exe"
$nativeCompactionSource = "$proxyDir\sources\CLIProxyAPI-$nativeCompactionCommit"
$nativeCompactionMarker = "$proxyDir\.native-compaction-enabled"

function Step($msg) { Write-Host ">> $msg" -ForegroundColor Cyan }
function Warn($msg) { Write-Host "!! $msg" -ForegroundColor Yellow }
function Invoke-NativeExitCode($filePath, [string[]]$argumentList) {
    # Windows PowerShell 5.1 turns native stderr into ErrorRecords. Git writes
    # normal progress there, so EAP=Stop would abort successful fetches.
    $savedErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $nativeOutput = & $filePath @argumentList 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedErrorActionPreference
    }
    $nativeOutput | ForEach-Object { Write-Host "$_" }
    return [int]$exitCode
}

if ($NativeCompaction -and $StableProxy) {
    throw "-NativeCompaction and -StableProxy are mutually exclusive"
}

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
$stableExe = "$proxyDir\cli-proxy-api.exe"
if (Test-Path $stableExe) {
    Step "official binary already present: $stableExe"
} else {
    $asset = "CLIProxyAPI_${Version}_windows_amd64.zip"
    $url = "https://github.com/router-for-me/CLIProxyAPI/releases/download/v$Version/$asset"
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $downloadArchive = "$proxyDir\archive\$stamp-$PID-official-$Version"
    New-Item -ItemType Directory -Force (Split-Path $downloadArchive -Parent) | Out-Null
    New-Item -ItemType Directory $downloadArchive | Out-Null
    $zip = "$downloadArchive\$asset"
    Step "downloading $url"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
    $extract = "$downloadArchive\extract"
    Expand-Archive -Path $zip -DestinationPath $extract
    $found = Get-ChildItem $extract -Recurse -Filter "*.exe" | Select-Object -First 1
    if (-not $found) { throw "no .exe found inside $asset" }
    Copy-Item $found.FullName $stableExe
    Step "installed official binary -> $stableExe"
    Step "retained installer assets -> $downloadArchive"
}

# The native compaction bridge is an upstream draft, so it is explicit opt-in
# and built from one immutable, signed commit. The official release stays beside
# it as the default and rollback path.
if ($NativeCompaction) {
    $git = Get-Command "git" -ErrorAction SilentlyContinue
    if (-not $git) { throw "git is required for -NativeCompaction" }

    if (-not (Test-Path $nativeCompactionSource)) {
        New-Item -ItemType Directory -Force (Split-Path $nativeCompactionSource -Parent) | Out-Null
        New-Item -ItemType Directory $nativeCompactionSource | Out-Null
    }
    if (-not (Test-Path $nativeCompactionSource -PathType Container)) {
        throw "native compaction source path is not a directory: $nativeCompactionSource"
    }
    if (-not (Test-Path "$nativeCompactionSource\.git")) {
        $sourceItems = @(Get-ChildItem $nativeCompactionSource -Force)
        if ($sourceItems.Count -gt 0) {
            throw "native compaction source exists but is not an empty or valid Git checkout: $nativeCompactionSource"
        }
        $gitExit = Invoke-NativeExitCode $git.Source @("-C", $nativeCompactionSource, "init")
        if ($gitExit -ne 0) { throw "git init failed for $nativeCompactionSource" }
    }

    $nativeOrigin = (& $git.Source -C $nativeCompactionSource remote get-url origin 2>$null | Out-String).Trim()
    $hasNativeOrigin = ($LASTEXITCODE -eq 0 -and [bool]$nativeOrigin)
    if ($hasNativeOrigin) {
        if ($nativeOrigin -ne $nativeCompactionRepo) {
            throw "native compaction source origin must be $nativeCompactionRepo (found '$nativeOrigin')"
        }
    } else {
        $gitExit = Invoke-NativeExitCode $git.Source @("-C", $nativeCompactionSource, "remote", "add", "origin", $nativeCompactionRepo)
        if ($gitExit -ne 0) { throw "git remote add failed for $nativeCompactionSource" }
    }

    $nativeHead = (& $git.Source -C $nativeCompactionSource rev-parse --verify HEAD 2>$null | Out-String).Trim()
    $hasNativeHead = ($LASTEXITCODE -eq 0)
    if ($hasNativeHead -and $nativeHead -ne $nativeCompactionCommit) {
        throw "native compaction source must be exactly $nativeCompactionCommit (found '$nativeHead')"
    }
    if (-not $hasNativeHead) {
        $partialDirty = (& $git.Source -C $nativeCompactionSource status --porcelain --untracked-files=all | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or $partialDirty) {
            throw "incomplete native compaction checkout is not clean: $nativeCompactionSource"
        }
        $gitExit = Invoke-NativeExitCode $git.Source @("-C", $nativeCompactionSource, "fetch", "--depth", "1", "origin", $nativeCompactionCommit)
        if ($gitExit -ne 0) { throw "git fetch failed for native compaction commit $nativeCompactionCommit" }
        $gitExit = Invoke-NativeExitCode $git.Source @("-C", $nativeCompactionSource, "checkout", "--detach", $nativeCompactionCommit)
        if ($gitExit -ne 0) { throw "git checkout failed for native compaction commit $nativeCompactionCommit" }
    }

    $nativeHead = (& $git.Source -C $nativeCompactionSource rev-parse --verify HEAD | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $nativeHead -ne $nativeCompactionCommit) {
        throw "native compaction source must be exactly $nativeCompactionCommit (found '$nativeHead')"
    }
    $nativeDirty = (& $git.Source -C $nativeCompactionSource status --porcelain --untracked-files=all | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $nativeDirty) {
        throw "native compaction source is not clean: $nativeCompactionSource"
    }

    if (-not (Test-Path $nativeCompactionExe)) {
        $go = Get-Command "go" -ErrorAction SilentlyContinue
        if (-not $go) { throw "Go 1.26+ is required to build native compaction" }
        $goVersion = (& $go.Source version | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or $goVersion -notmatch 'go(\d+)\.(\d+)') {
            throw "could not parse Go version: '$goVersion'"
        }
        $goMajor = [int]$Matches[1]
        $goMinor = [int]$Matches[2]
        if ($goMajor -lt 1 -or ($goMajor -eq 1 -and $goMinor -lt 26)) {
            throw "Go 1.26+ is required to build native compaction (found '$goVersion')"
        }

        New-Item -ItemType Directory -Force $nativeCompactionDir | Out-Null
        $buildingExe = "$nativeCompactionExe.building-$PID"
        if (Test-Path $buildingExe) { throw "stale build output exists: $buildingExe" }
        Push-Location $nativeCompactionSource
        try {
            $goExit = Invoke-NativeExitCode $go.Source @("build", "-trimpath", "-o", $buildingExe, "./cmd/server")
            if ($goExit -ne 0) { throw "native compaction build failed" }
        } finally {
            Pop-Location
        }
        Move-Item $buildingExe $nativeCompactionExe
        Step "built native compaction binary -> $nativeCompactionExe"
    } else {
        Step "native compaction binary already present: $nativeCompactionExe"
    }

    if (Test-Path $nativeCompactionMarker) {
        $markedCommit = (Get-Content $nativeCompactionMarker -Raw).Trim()
        if ($markedCommit -ne $nativeCompactionCommit) {
            throw "native compaction marker names an unsupported commit: '$markedCommit'"
        }
    } else {
        [System.IO.File]::WriteAllText($nativeCompactionMarker, "$nativeCompactionCommit`n", [System.Text.UTF8Encoding]::new($false))
    }
    Step "native compaction channel activated at $nativeCompactionCommit"
}

if ($StableProxy -and (Test-Path $nativeCompactionMarker)) {
    $archiveDir = "$proxyDir\archive"
    New-Item -ItemType Directory -Force $archiveDir | Out-Null
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $archivedMarker = "$archiveDir\$stamp-$PID-native-compaction.enabled"
    Move-Item $nativeCompactionMarker $archivedMarker
    Step "stable channel activated; native marker retained at $archivedMarker"
}

$exe = $stableExe
if (Test-Path $nativeCompactionMarker) {
    $markedCommit = (Get-Content $nativeCompactionMarker -Raw).Trim()
    if ($markedCommit -ne $nativeCompactionCommit) {
        throw "native compaction marker names an unsupported commit: '$markedCommit'"
    }
    if (-not (Test-Path $nativeCompactionExe)) {
        throw "native compaction is active but its binary is missing: $nativeCompactionExe"
    }
    $exe = $nativeCompactionExe
    Step "proxy channel: native compaction ($nativeCompactionCommit)"
} else {
    Step "proxy channel: official release v$Version"
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
    if ($confRaw -notmatch 'alias:\s*"claude-opus-4-8"' -or $confRaw -notmatch 'alias:\s*"claude-sonnet-5"' -or $confRaw -notmatch 'alias:\s*"claude-haiku-4-5"') {
        Warn "existing config is MISSING one or more model aliases - claudex routing or the full Claude Code harness will fail."
        Warn "merge the oauth-model-alias block from config\cliproxyapi.conf.template, then restart the proxy. Verify with doctor.ps1."
    }
    # An existing config is never overwritten, so upgrades silently skip new
    # keys. Call this one out by name - it is the difference between a stable
    # tool array and one that defeats prompt-cache prefix matching.
    if ($confRaw -notmatch 'disable-image-generation') {
        Warn "existing config is missing 'disable-image-generation' - CLIProxyAPI appends an unrequested image_generation tool to every request, mutating the tool array that prompt-cache prefix matching needs byte-identical."
        Warn "add 'disable-image-generation: chat' at the TOP LEVEL of $confPath (it is a 4-state enum: off|true|chat|passthrough, not a boolean), then restart the proxy."
    }
} else {
    $key = (Get-Content $keyPath -Raw).Trim()
    $conf = (Get-Content "$repoRoot\config\cliproxyapi.conf.template" -Raw).Replace("__PROXY_KEY__", $key)
    [System.IO.File]::WriteAllText($confPath, $conf, [System.Text.UTF8Encoding]::new($false))
    Step "wrote config -> $confPath"
}

# --- 4. Claudex settings ---------------------------------------------------
$settingsSource = "$repoRoot\config\claudex.settings.json"
$settingsPath = "$proxyDir\claudex.settings.json"
$settingsRaw = Get-Content $settingsSource -Raw
try {
    $settingsRaw | ConvertFrom-Json | Out-Null
} catch {
    throw "invalid Claudex settings JSON: $settingsSource"
}

if ((Test-Path $settingsPath) -and (Get-Content $settingsPath -Raw) -eq $settingsRaw) {
    Step "Claudex settings already current: $settingsPath"
} else {
    if (Test-Path $settingsPath) {
        $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $backupDir = "$proxyDir\archive\$stamp-$PID-claudex-settings"
        New-Item -ItemType Directory -Path $backupDir | Out-Null
        Copy-Item $settingsPath "$backupDir\claudex.settings.json"
        Step "backed up previous Claudex settings -> $backupDir\claudex.settings.json"
    }
    [System.IO.File]::WriteAllText($settingsPath, $settingsRaw, [System.Text.UTF8Encoding]::new($false))
    Step "installed Claudex settings -> $settingsPath"
}

# --- 5. autostart ----------------------------------------------------------
if (-not $SkipAutostart) {
    $vbs = "$proxyDir\start-hidden.vbs"
    $vbsContent = "CreateObject(""Wscript.Shell"").Run """"""$exe"""" -config """"$confPath"""""", 0, False"
    [System.IO.File]::WriteAllText($vbs, $vbsContent, [System.Text.UTF8Encoding]::new($false))
    $startup = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup\CLIProxyAPI.vbs"
    Copy-Item $vbs $startup -Force
    Step "autostart registered -> $startup"
}

# --- 6. PowerShell profile function -----------------------------------------
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

# --- 7. start proxy ---------------------------------------------------------
if (-not (Get-Process cli-proxy-api -ErrorAction SilentlyContinue)) {
    Start-Process -FilePath $exe -ArgumentList "-config", $confPath -WorkingDirectory $proxyDir -WindowStyle Hidden
    Start-Sleep -Seconds 2
    Step "proxy started"
} else {
    Step "proxy already running (restart it to pick up config changes: Get-Process cli-proxy-api | Stop-Process; then re-run install.ps1)"
}

# --- 8. Codex OAuth ---------------------------------------------------------
$cred = Get-ChildItem $authDir -Filter "codex-*.json" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($cred) {
    Step "Codex credential already present: $($cred.Name)"
} elseif ($SkipLogin) {
    Step "SKIPPED login - run '$exe -codex-login' manually before first use"
} else {
    Step "launching Codex OAuth login (browser will open, sign in with your ChatGPT account)..."
    & $exe -codex-login
}

# --- 9. smoke test ----------------------------------------------------------
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
