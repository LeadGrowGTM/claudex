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
    Check "config: haiku alias" ($conf -match 'alias:\s*"claude-haiku-4-5"') "claude-haiku-4-5 -> gpt-5.3-codex-spark"
    if ($conf -match 'request-log:\s*true' -or $conf -match 'debug:\s*true') {
        Warn "config: debug logging" "request/debug logging is ON - payload logs accumulate in $authDir\logs"
    }
    if ($conf -match 'alias:\s*"claude-sonnet-5"') {
        Warn "config: sonnet-5 alias" "claude-sonnet-5 is native_1m in Claude Code -> 1M budget vs ~258k upstream. Covered by CLAUDE_CODE_AUTO_COMPACT_WINDOW; drop the alias if subagents overflow."
    }
    if ($conf -notmatch 'disable-image-generation') {
        Warn "config: image generation" "unset - an unrequested image_generation tool is appended to every request (perturbs the stable tool array prompt-cache prefix matching needs)"
    }
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
    Check "alias live: claude-haiku-4-5" ($models -contains "claude-haiku-4-5") ""
}

# 6. Codex credential
$cred = Get-ChildItem $authDir -Filter "codex-*.json" -ErrorAction SilentlyContinue | Select-Object -First 1
Check "codex credential" ([bool]$cred) $(if ($cred) { $cred.Name } else { "run: $proxyDir\cli-proxy-api.exe -codex-login" })

# 7. profile function
$hostProfile = "$env:USERPROFILE\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1"
$profileOk = $false
foreach ($p in @($hostProfile, $PROFILE.CurrentUserAllHosts)) {
    if ($p -and (Test-Path $p)) {
        if ((Get-Content $p -Raw) -match [regex]::Escape("# >>> claudex >>>")) { $profileOk = $true; break }
    }
}
Check "profile function installed" $profileOk "marker block in PowerShell profile"

# 7b. the context-window pin must be present, or native_1m aliases
# (claude-opus-4-8, claude-sonnet-5) get a 1M budget against a ~258k upstream.
$fnPinned = $false
foreach ($p in @($hostProfile, $PROFILE.CurrentUserAllHosts)) {
    if ($p -and (Test-Path $p) -and ((Get-Content $p -Raw) -match 'CLAUDE_CODE_AUTO_COMPACT_WINDOW')) { $fnPinned = $true; break }
}
Check "context window pinned" $fnPinned "without it, native_1m aliases get a 1M budget vs ~258k upstream"

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
