# claudex doctor - read-only health check of the whole chain.
# Run any time something feels off. Exits nonzero if any check fails.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File doctor.ps1
#   ... -Smoke     also run live end-to-end calls through both model tiers

param([switch]$Smoke)

$ErrorActionPreference = "Continue"
$proxyDir = "$env:USERPROFILE\.cliproxyapi"
$authDir  = "$env:USERPROFILE\.cli-proxy-api"
$pass = 0; $fail = 0; $warn = 0

function Check($name, $ok, $detail) {
    if ($ok) { Write-Host ("OK    {0}  {1}" -f $name, $detail) -ForegroundColor Green; $script:pass++ }
    else     { Write-Host ("FAIL  {0}  {1}" -f $name, $detail) -ForegroundColor Red;   $script:fail++ }
}
function Warn($name, $detail) { Write-Host ("WARN  {0}  {1}" -f $name, $detail) -ForegroundColor Yellow; $script:warn++ }

Write-Host "=== claudex doctor ===" -ForegroundColor Cyan

# 1. PowerShell version
Check "powershell version" ($PSVersionTable.PSVersion.Major -ge 5) "$($PSVersionTable.PSVersion)"

# 2. claude CLI
$claudeBin = $null
$cmd = Get-Command "claude.exe" -ErrorAction SilentlyContinue
if ($cmd) { $claudeBin = $cmd.Source }
elseif (Test-Path "$env:USERPROFILE\.local\bin\claude.exe") { $claudeBin = "$env:USERPROFILE\.local\bin\claude.exe" }
Check "claude CLI" ([bool]$claudeBin) "$claudeBin"

# 3. proxy binary / key / config
Check "proxy binary" (Test-Path "$proxyDir\cli-proxy-api.exe") "$proxyDir\cli-proxy-api.exe"
Check "proxy key" (Test-Path "$proxyDir\.proxykey") "$proxyDir\.proxykey"
$confPath = "$proxyDir\cliproxyapi.conf"
$confOk = Test-Path $confPath
Check "config file" $confOk $confPath
if ($confOk) {
    $conf = Get-Content $confPath -Raw
    Check "config: opus alias" ($conf -match 'alias:\s*"claude-opus-4-8"') "claude-opus-4-8 -> gpt-5.6-sol"
    Check "config: sonnet alias" ($conf -match 'alias:\s*"claude-sonnet-5"') "claude-sonnet-5 -> gpt-5.6-terra"
    Check "config: haiku alias" ($conf -match 'alias:\s*"claude-haiku-4-5"') "claude-haiku-4-5 -> gpt-5.3-codex-spark"
    if ($conf -match 'request-log:\s*true' -or $conf -match 'debug:\s*true') {
        Warn "config: debug logging" "request/debug logging is ON - payload logs accumulate in $authDir\logs"
    }
    if ($conf -notmatch 'disable-image-generation') {
        Warn "config: image generation" "unset - an unrequested image_generation tool is appended to every request (perturbs the stable tool array prompt-cache prefix matching needs)"
    }
    if ($conf -match 'name:\s*"gpt-5\.6-\*"[\s\S]*?"reasoning\.effort":\s*"max"') {
        Warn "config: role effort" "legacy gpt-5.6-* maximum override is active - classifiers and Terra subagents cannot use lower effort"
    } else {
        Check "config: role effort" $true "per-request effort reaches classifiers and subagents"
    }
}

# 3b. Claudex-only policy and routing settings
$settingsPath = "$proxyDir\claudex.settings.json"
$settings = $null
Check "Claudex settings file" (Test-Path $settingsPath) $settingsPath
if (Test-Path $settingsPath) {
    try { $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json } catch {}
    Check "Claudex settings JSON" ([bool]$settings) "valid JSON"
}
if ($settings) {
    $allow = @($settings.permissions.allow)
    $ask = @($settings.permissions.ask)
    $deny = @($settings.permissions.deny)
    Check "policy: Agent allowed" ($allow -contains "Agent") "static allow avoids classifier startup"
    Check "policy: PowerShell inspection" ($allow -contains "PowerShell(Get-ChildItem *)") "dedicated tool parity"
    Check "policy: deletion denied" (($deny -contains "Bash(rm *)") -and ($deny -contains "PowerShell(Remove-Item *)")) "Bash and PowerShell"
    Check "policy: push asks" (($ask -contains "Bash(git push *)") -and ($ask -contains "PowerShell(git push *)")) "human checkpoint"
    Check "policy: auto defaults" ((@($settings.autoMode.allow) -contains '$defaults') -and (@($settings.autoMode.environment) -contains '$defaults')) "allow and environment"
    $codexOverrides = @($settings.skillOverrides.PSObject.Properties | Where-Object { $_.Name -like "codex-*" -and "$($_.Value)" -eq "user-invocable-only" })
    Check "routing: Codex-only skills" ($codexOverrides.Count -eq 8) "$($codexOverrides.Count)/8 hidden from automatic routing"
}

# 4. proxy process + port
$proc = Get-Process cli-proxy-api -ErrorAction SilentlyContinue
Check "proxy process" ([bool]$proc) $(if ($proc) { "pid $($proc.Id)" } else { "not running (claudex auto-starts it, or run install.ps1)" })

# The Codex reasoning replay cache is process-local memory with a 1h TTL
# (CodexReasoningReplayCacheTTL). A proxy younger than the session has lost the
# reasoning lineage for it - no error is raised, the session just starts
# forgetting why it did things. Cheapest high-value check in this script.
if ($proc) {
    $up = [int]((Get-Date) - $proc.StartTime).TotalSeconds
    if ($up -lt 3600) {
        Warn "proxy uptime" "${up}s (<1h) - if a session predates this restart, its reasoning replay cache is gone; expect repetition/odd tool choices. Restart the session, not the proxy."
    } else {
        Check "proxy uptime" $true "${up}s"
    }
}

$portOwnedByProxy = $false
$conn = Get-NetTCPConnection -LocalPort 8317 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
if ($conn) {
    $owner = (Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue).ProcessName
    $portOwnedByProxy = ($owner -eq "cli-proxy-api")
    Check "port 8317 owner" $portOwnedByProxy "listener: $owner"
} elseif ($proc) {
    Check "port 8317 owner" $false "proxy running but nothing listening on 8317"
} else {
    Warn "port 8317" "nothing listening (expected while proxy is stopped)"
}

# 5. proxy answers with both aliases in its model list
if ($portOwnedByProxy -and (Test-Path "$proxyDir\.proxykey")) {
    $key = (Get-Content "$proxyDir\.proxykey" -Raw).Trim()
    $models = @()
    try {
        $r = Invoke-RestMethod -Uri "http://127.0.0.1:8317/v1/models" -Headers @{ Authorization = "Bearer $key" } -TimeoutSec 10
        $models = @($r.data | ForEach-Object { $_.id })
    } catch {}
    Check "proxy /v1/models" ($models.Count -gt 0) "$($models.Count) models"
    Check "alias live: claude-opus-4-8" ($models -contains "claude-opus-4-8") ""
    Check "alias live: claude-sonnet-5" ($models -contains "claude-sonnet-5") ""
    Check "alias live: claude-haiku-4-5" ($models -contains "claude-haiku-4-5") ""
}

# 6. Codex credential
$cred = Get-ChildItem $authDir -Filter "codex-*.json" -ErrorAction SilentlyContinue | Select-Object -First 1
Check "codex credential" ([bool]$cred) $(if ($cred) { $cred.Name } else { "run: $proxyDir\cli-proxy-api.exe -codex-login" })

# 7. profile function
$hostProfile = "$env:USERPROFILE\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1"
$profileOk = $false
$installedFunctionRaw = ""
foreach ($p in @($hostProfile, $PROFILE.CurrentUserAllHosts)) {
    if ($p -and (Test-Path $p)) {
        $candidate = Get-Content $p -Raw
        if ($candidate -match [regex]::Escape("# >>> claudex >>>")) {
            $profileOk = $true
            $installedFunctionRaw = $candidate
            break
        }
    }
}
Check "profile function installed" $profileOk "marker block in PowerShell profile"
if ($profileOk) {
    Check "profile: settings wired" ($installedFunctionRaw -match '--settings') "$settingsPath"
    Check "profile: default permission" ($installedFunctionRaw -match 'permission-mode",\s*"acceptEdits"') "acceptEdits"
    Check "profile: explicit auto" ($installedFunctionRaw -match 'if \(\$Auto\).*permission-mode",\s*"auto"') "-Auto"
}

# 7b. the context-window pin must be present AND set with real headroom under the
# ~258k upstream ceiling. Present-but-too-high (e.g. 240k) still 400s: Claude Code
# counts with the Anthropic tokenizer, GPT-5.6-sol counts 5-12% higher, so a thin
# buffer lands the compaction request itself over the ceiling. Cap at 210000.
$fnPinned = $false
$fnHeadroom = $false
foreach ($p in @($hostProfile, $PROFILE.CurrentUserAllHosts)) {
    if ($p -and (Test-Path $p)) {
        $raw = Get-Content $p -Raw
        if ($raw -match 'CLAUDE_CODE_AUTO_COMPACT_WINDOW\s*=\s*"(\d+)"') {
            $fnPinned = $true
            if ([int]$Matches[1] -le 210000) { $fnHeadroom = $true }
            break
        }
    }
}
Check "context window pinned" $fnPinned "without it, native_1m aliases get a 1M budget vs ~258k upstream"
Check "context window headroom" $fnHeadroom "AUTO_COMPACT_WINDOW must be <=210000: ~258k ceiling minus tokenizer skew + one fat tool result"

# 7c. no claudex env vars leaked into this shell. The function scopes them to its
# own invocation and restores them in a finally block, so they must not be set
# here. If they are, this shell's plain `claude` loses Remote Control (gate is
# tqe() -> GUn(), which requires ANTHROPIC_BASE_URL unset or api.anthropic.com)
# and claude.ai features (ANTHROPIC_AUTH_TOKEN forces api-key auth).
$leaked = @("ANTHROPIC_BASE_URL","ANTHROPIC_AUTH_TOKEN","_CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL") |
    Where-Object { [Environment]::GetEnvironmentVariable($_) }
if ($leaked) {
    Warn "claudex env leaked" "set in this shell: $($leaked -join ', ') - plain 'claude' here loses Remote Control and claude.ai features (fine if you are inside a claudex session)"
} else {
    Check "no claudex env leaked" $true "plain 'claude' in this shell keeps Remote Control"
}

# 7d. recent proxy failures, metadata only. Request-body sections are skipped.
$errorLogDir = "$authDir\logs"
$error500 = 0; $error502 = 0; $error503 = 0; $authUnavailable = 0; $contextCanceled = 0
$recentErrorFiles = @(Get-ChildItem $errorLogDir -Filter "error-v1-messages-*.log" -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge (Get-Date).AddHours(-24) })
foreach ($file in $recentErrorFiles) {
    $skipBody = $false
    foreach ($line in [System.IO.File]::ReadLines($file.FullName)) {
        if ($line -match '^--- .*REQUEST BODY.*---$') { $skipBody = $true; continue }
        if ($line -match '^--- .*RESPONSE.*---$') { $skipBody = $false; continue }
        if ($skipBody -or $line.Length -gt 4096) { continue }
        if ($line -match '(?i)^status(?: code)?:\s*500\b|HTTP\s+500\b') { $error500++ }
        if ($line -match '(?i)^status(?: code)?:\s*502\b|HTTP\s+502\b') { $error502++ }
        if ($line -match '(?i)^status(?: code)?:\s*503\b|HTTP\s+503\b') { $error503++ }
        if ($line -match '(?i)auth_unavailable|no auth available') { $authUnavailable++ }
        if ($line -match '(?i)context canceled') { $contextCanceled++ }
    }
}
if ($recentErrorFiles.Count -gt 0) {
    Warn "proxy errors (24h)" "files=$($recentErrorFiles.Count) HTTP500=$error500 HTTP502=$error502 HTTP503=$error503 auth_unavailable=$authUnavailable context_canceled=$contextCanceled"
} else {
    Check "proxy errors (24h)" $true "none"
}

# 8. optional live smoke
if ($Smoke) {
    if ($claudeBin -and $cred -and $portOwnedByProxy) {
        Write-Host ">> live smoke test (both tiers)..." -ForegroundColor Cyan
        $key = (Get-Content "$proxyDir\.proxykey" -Raw).Trim()
        $origBase = $env:ANTHROPIC_BASE_URL; $origTok = $env:ANTHROPIC_AUTH_TOKEN; $origFp = $env:_CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL
        try {
            $env:ANTHROPIC_BASE_URL = "http://127.0.0.1:8317"
            $env:ANTHROPIC_AUTH_TOKEN = $key
            $env:_CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL = "1"
            $r1 = & $claudeBin --model claude-opus-4-8 -p "Reply with the single word: ok" 2>$null
            $r2 = & $claudeBin --model claude-haiku-4-5 -p "Reply with the single word: ok" 2>$null
        } finally {
            $env:ANTHROPIC_BASE_URL = $origBase; $env:ANTHROPIC_AUTH_TOKEN = $origTok; $env:_CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL = $origFp
        }
        Check "smoke: flagship tier" ("$r1".Trim() -eq "ok") "reply: '$("$r1".Trim())'"
        Check "smoke: fast tier" ("$r2".Trim() -eq "ok") "reply: '$("$r2".Trim())'"
    } else {
        Check "smoke test" $false "prerequisites missing (claude CLI / credential / proxy)"
    }
}

Write-Host ""
$verdict = if ($fail -eq 0) { "HEALTHY ($pass ok, $warn warnings)" } else { "$fail FAILURES ($pass ok, $warn warnings)" }
$color = if ($fail -eq 0) { "Green" } else { "Red" }
Write-Host "=== $verdict ===" -ForegroundColor $color
if ($fail -gt 0) { exit 1 }
