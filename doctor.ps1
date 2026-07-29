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
$nativeCompactionCommit = "725aa9f1bd61c76edb315ae80c7be6215198621a"
$nativeCompactionMarker = "$proxyDir\.native-compaction-enabled"
$nativeCompactionSource = "$proxyDir\sources\CLIProxyAPI-$nativeCompactionCommit"
$nativeCompactionExe = "$proxyDir\native-compaction-$nativeCompactionCommit\cli-proxy-api.exe"
$selectedProxyExe = "$proxyDir\cli-proxy-api.exe"
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
Check "proxy binary: stable" (Test-Path "$proxyDir\cli-proxy-api.exe") "$proxyDir\cli-proxy-api.exe"
if (Test-Path $nativeCompactionMarker) {
    $markedCommit = (Get-Content $nativeCompactionMarker -Raw).Trim()
    $markerOk = ($markedCommit -eq $nativeCompactionCommit)
    Check "proxy channel: native" $markerOk "pinned commit: $markedCommit"
    Check "native compaction binary" (Test-Path $nativeCompactionExe) $nativeCompactionExe
    $selectedProxyExe = $nativeCompactionExe

    $git = Get-Command "git" -ErrorAction SilentlyContinue
    if ($git -and (Test-Path "$nativeCompactionSource\.git")) {
        $nativeHead = (& $git.Source -C $nativeCompactionSource rev-parse --verify HEAD 2>$null | Out-String).Trim()
        $nativeHeadOk = ($LASTEXITCODE -eq 0)
        $nativeDirty = (& $git.Source -C $nativeCompactionSource status --porcelain --untracked-files=all 2>$null | Out-String).Trim()
        $nativeStatusOk = ($LASTEXITCODE -eq 0)
        Check "native source pin" ($nativeHeadOk -and $nativeHead -eq $nativeCompactionCommit) "HEAD: $nativeHead"
        Check "native source clean" ($nativeStatusOk -and -not $nativeDirty) $nativeCompactionSource
    } else {
        Check "native source pin" $false "Git or source checkout missing: $nativeCompactionSource"
    }
    Warn "native compaction status" "experimental upstream draft #4465 is active"
} else {
    Check "proxy channel: stable" $true "official release binary"
}
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

# 3c. agent model drift (read-only, non-fatal - never flips doctor unhealthy).
# Every installed subagent pins a model in its frontmatter. Claude Code matches
# the ID against its registry exactly, then the proxy maps it via
# oauth-model-alias. A dated/variant ID the alias map misses (e.g.
# claude-sonnet-4-6) 502s "unknown provider" at spawn. Warn so the operator adds
# an alias; a bare tier name or an installed-config alias is already resolvable.
$agentsDir = "$env:USERPROFILE\.claude\agents"
if (Test-Path $agentsDir) {
    $resolvable = @("opus", "sonnet", "haiku", "claude-sonnet-5", "claude-haiku-4-5")
    if ($confOk) {
        foreach ($m in [regex]::Matches($conf, 'alias:\s*"([^"]+)"')) {
            $resolvable += $m.Groups[1].Value
        }
    }
    $unmapped = 0
    foreach ($agentFile in @(Get-ChildItem $agentsDir -Filter "*.md" -ErrorAction SilentlyContinue)) {
        $mm = [regex]::Match((Get-Content $agentFile.FullName -Raw), '(?m)^model:\s*(\S+)\s*$')
        if (-not $mm.Success) { continue }
        $model = $mm.Groups[1].Value
        if ($resolvable -notcontains $model) {
            $unmapped++
            Warn "agent model unmapped" "$($agentFile.Name) pins '$model' - no bare tier, installed cliproxyapi.conf alias, or DEFAULT model pin resolves it; add an oauth-model-alias entry"
        }
    }
    if ($unmapped -eq 0) { Check "agent models mapped" $true "all ~\.claude\agents frontmatter models resolve" }
}

# 4. proxy process + port
$proc = Get-Process cli-proxy-api -ErrorAction SilentlyContinue | Select-Object -First 1
Check "proxy process" ([bool]$proc) $(if ($proc) { "pid $($proc.Id)" } else { "not running (claudex auto-starts it, or run install.ps1)" })
if ($proc) {
    if ($proc.Path) {
        $livePath = [System.IO.Path]::GetFullPath($proc.Path)
        $selectedPath = [System.IO.Path]::GetFullPath($selectedProxyExe)
        Check "proxy channel live" ($livePath -eq $selectedPath) "running: $livePath"
    } else {
        Check "proxy channel live" $false "could not inspect binary path for pid $($proc.Id)"
    }
}

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

# 6b. Codex auth-sync watcher (mirrors ~/.codex/auth.json into $cred so Codex
# CLI's own refresh doesn't invalidate cli-proxy-api's refresh_token - both
# authenticate the same OpenAI account under the same OAuth client_id).
$syncStartup = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup\ClaudexAuthSync.vbs"
Check "auth-sync watcher registered" (Test-Path $syncStartup) $(if (Test-Path $syncStartup) { $syncStartup } else { "run install.ps1 (or without -SkipAuthSync)" })
$syncPidPath = "$authDir\logs\sync-codex-auth.pid"
$syncRunning = $false
if (Test-Path $syncPidPath) {
    $syncPid = (Get-Content $syncPidPath -Raw).Trim()
    $syncRunning = [bool](Get-Process -Id $syncPid -ErrorAction SilentlyContinue)
}
Check "auth-sync watcher running" $syncRunning $(if ($syncRunning) { "pid $syncPid" } else { "not running - reboot or run: $PSScriptRoot\auth\sync-codex-auth.ps1 -Watch" })
$codexCliAuth = "$env:USERPROFILE\.codex\auth.json"
if ($cred -and (Test-Path $codexCliAuth)) {
    try {
        $cliTokens = (Get-Content $codexCliAuth -Raw | ConvertFrom-Json).tokens
        $proxyCred = Get-Content $cred.FullName -Raw | ConvertFrom-Json
        Check "auth-sync in sync" ($cliTokens.refresh_token -eq $proxyCred.refresh_token) "Codex CLI and cli-proxy-api share the same refresh_token"
    } catch {
        Warn "auth-sync in sync" "could not compare - $($_.Exception.Message)"
    }
}

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

# 7d. durable backup pin. Claude Code 2.1.219+ resolves the auto-compact window
# from CLAUDE_CODE_AUTO_COMPACT_WINDOW first, then a settings `autoCompactWindow`
# field. claudex.settings.json carries the same 200000 so the window stays pinned
# even if the env var ever fails to propagate. Valid values are JSON numbers whose
# value is an integer in 100000..1000000; invalid values are ignored. Claudex also
# requires the existing 210000 headroom ceiling. An absent property remains fine.
$settingsWindowOk = $true
if ($settings) {
    $settingsWindowProperty = $settings.PSObject.Properties["autoCompactWindow"]
    if ($settingsWindowProperty) {
        $settingsWindowValue = $settingsWindowProperty.Value
        $numericTypes = @([byte], [sbyte], [int16], [uint16], [int32], [uint32], [int64], [uint64], [single], [double], [decimal])
        $settingsWindowIsNumeric = ($null -ne $settingsWindowValue -and $numericTypes -contains $settingsWindowValue.GetType())
        $settingsWindowSchemaOk = ($settingsWindowIsNumeric -and
            $settingsWindowValue -ge 100000 -and
            $settingsWindowValue -le 1000000 -and
            ([decimal]$settingsWindowValue % 1 -eq 0))
        $settingsWindowOk = ($settingsWindowSchemaOk -and $settingsWindowValue -le 210000)
    }
}
Check "settings autoCompactWindow headroom" $settingsWindowOk "claudex.settings.json autoCompactWindow, if set, must be a JSON integer in 100000..1000000 and <=210000 for Claudex headroom"

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
