[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Claude Code pipes session JSON on stdin. Parse defensively - never throw.
$Esc = [char]27
function Color($code, $text) { return "${Esc}[38;5;${code}m$text${Esc}[0m" }

try {
    $raw = [Console]::In.ReadToEnd()
    $data = $raw | ConvertFrom-Json
} catch {
    exit 0
}
# remaining-% color: plenty green, mid yellow, low red
function RemainColor($remaining) {
    if ($remaining -ge 40) { return 71 } elseif ($remaining -ge 15) { return 178 } else { return 196 }
}

# mini bar of what's LEFT: label[████░]62%  (5 cells, filled = remaining)
function UsageBar($label, $remaining) {
    if ($remaining -lt 0) { $remaining = 0 }; if ($remaining -gt 100) { $remaining = 100 }
    $cells = 5
    $filled = [math]::Round(($remaining / 100) * $cells)
    if ($filled -gt $cells) { $filled = $cells }
    $full = [string][char]0x2588
    $empty = [string][char]0x2591
    $bar = ($full * $filled) + ($empty * ($cells - $filled))
    return (Color 250 $label) + (Color (RemainColor $remaining) "[$bar]${remaining}%")
}

$parts = @()

# --- Model display name (orange) + claudex disguise marker ---
# claudex routes through the local CLIProxyAPI; the statusline inherits the
# session env, so the base URL is the reliable tell. The model NAME will say
# Opus/Haiku (alias) but the upstream is GPT - surface that.
$model = $null
try { $model = $data.model.display_name } catch {}
if ([string]::IsNullOrWhiteSpace($model)) { try { $model = $data.model.id } catch {} }
$viaClaudex = ($env:ANTHROPIC_BASE_URL -match '127\.0\.0\.1:8317')
if (-not [string]::IsNullOrWhiteSpace($model)) {
    if ($viaClaudex) {
        $upstream = "GPT"
        try {
            $mid = "$($data.model.id)"
            if ($mid -match 'opus')       { $upstream = "GPT-5.6-sol" }
            elseif ($mid -match 'haiku')  { $upstream = "GPT-5.3-spark" }
        } catch {}
        $parts += ((Color 172 $model) + (Color 201 " claudex:$upstream"))
    } else {
        $parts += (Color 172 $model)
    }
}

# --- Current directory basename (cyan) + git branch ---
$dir = $null
try { $dir = $data.workspace.current_dir } catch {}
if ([string]::IsNullOrWhiteSpace($dir)) { try { $dir = $data.cwd } catch {} }
if (-not [string]::IsNullOrWhiteSpace($dir)) {
    $parts += (Color 39 (Split-Path -Leaf $dir))
    try {
        Push-Location -LiteralPath $dir -ErrorAction Stop
        $branch = (git rev-parse --abbrev-ref HEAD 2>$null)
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($branch)) {
            $dirty = (git status --porcelain 2>$null)
            if (-not [string]::IsNullOrWhiteSpace($dirty)) { $parts += (Color 178 "$branch*") }
            else { $parts += (Color 71 $branch) }
        }
        Pop-Location
    } catch { try { Pop-Location -ErrorAction SilentlyContinue } catch {} }
}

# --- Context-usage fill bar (from transcript) ---
# Context size = input_tokens + cache_read + cache_creation of the latest
# assistant turn. Read it from the transcript JSONL Claude Code points us at.
function Get-ContextTokens($path) {
    if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $tail = Get-Content -LiteralPath $path -Tail 80 -ErrorAction Stop
    } catch { return $null }
    for ($i = $tail.Count - 1; $i -ge 0; $i--) {
        $line = $tail[$i]
        if ($line -notmatch '"usage"') { continue }
        try {
            $obj = $line | ConvertFrom-Json
            $u = $obj.message.usage
            if ($null -eq $u) { $u = $obj.usage }
            if ($null -ne $u -and $null -ne $u.input_tokens) {
                $sum = [int]$u.input_tokens
                if ($u.cache_read_input_tokens)     { $sum += [int]$u.cache_read_input_tokens }
                if ($u.cache_creation_input_tokens) { $sum += [int]$u.cache_creation_input_tokens }
                return $sum
            }
        } catch { continue }
    }
    return $null
}

# Window: env override wins; else 1M if model marked [1m]/1m, else 200k.
$window = 200000
if ($raw -match '(?i)\[?1m\]?') { $window = 1000000 }
if ($env:CTX_WINDOW) { try { $window = [int]$env:CTX_WINDOW } catch {} }

# Prefer Claude Code's own context_window numbers (exact, window-aware);
# fall back to transcript parsing for older CLI versions.
$pct = $null; $ctx = $null
try {
    if ($null -ne $data.context_window.used_percentage) {
        $pct = [int]$data.context_window.used_percentage
        $cu = $data.context_window.current_usage
        if ($cu) { $ctx = [int]$cu.input_tokens + [int]$cu.cache_read_input_tokens + [int]$cu.cache_creation_input_tokens }
    }
} catch {}
if ($null -eq $pct) {
    $tpath = $null
    try { $tpath = $data.transcript_path } catch {}
    $ctx = Get-ContextTokens $tpath
    if ($null -ne $ctx -and $window -gt 0) { $pct = [math]::Round(($ctx / $window) * 100) }
}
if ($null -ne $pct) {
    if ($pct -gt 100) { $pct = 100 }
    $cells = 10
    $filled = [math]::Floor($pct / 10)
    if ($filled -gt $cells) { $filled = $cells }
    $full = [string][char]0x2588   # full block
    $empty = [string][char]0x2591  # light shade
    $bar = ($full * $filled) + ($empty * ($cells - $filled))
    # color: green < 60, yellow < 85, red otherwise
    $c = if ($pct -lt 60) { 71 } elseif ($pct -lt 85) { 178 } else { 196 }
    $suffix = ""
    if ($null -ne $ctx -and $ctx -gt 0) { $suffix = " ($([math]::Round($ctx / 1000))k)" }
    $parts += (Color $c "[$bar] ${pct}%$suffix")
}

# --- Anthropic rate limits: % REMAINING for 5h session + 7d week ---
try {
    $rl = $data.rate_limits
    if ($rl -and $null -ne $rl.five_hour.used_percentage) {
        $sRem = 100 - [int]$rl.five_hour.used_percentage
        $wRem = 100 - [int]$rl.seven_day.used_percentage
        $parts += ((UsageBar "A:5h" $sRem) + (Color 250 " ") + (UsageBar "wk" $wRem))
    }
} catch {}

# --- Codex rate limits: % REMAINING (cached; background refresh, 30 min TTL) ---
try {
    $xcache = Join-Path $HOME ".claude\.statusline-codex.json"
    $xj = $null
    if (Test-Path -LiteralPath $xcache) {
        $xj = Get-Content -LiteralPath $xcache -Raw -ErrorAction Stop | ConvertFrom-Json
        if (((Get-Date) - [datetime]$xj.ts).TotalMinutes -ge 30) {
            $xlock = "$xcache.refreshing"
            $xfree = $true
            if (Test-Path -LiteralPath $xlock) { $xfree = (((Get-Date) - (Get-Item -LiteralPath $xlock).LastWriteTime).TotalMinutes -gt 5) }
            $xref = Join-Path $HOME ".claude\statusline-codex-refresh.ps1"
            if ($xfree -and (Test-Path -LiteralPath $xref)) {
                New-Item -ItemType File -Force -Path $xlock | Out-Null
                Start-Process powershell -ArgumentList "-NoProfile","-NonInteractive","-WindowStyle","Hidden","-ExecutionPolicy","Bypass","-File",$xref -WindowStyle Hidden
            }
        }
    } else {
        $xref = Join-Path $HOME ".claude\statusline-codex-refresh.ps1"
        if (Test-Path -LiteralPath $xref) {
            Start-Process powershell -ArgumentList "-NoProfile","-NonInteractive","-WindowStyle","Hidden","-ExecutionPolicy","Bypass","-File",$xref -WindowStyle Hidden
        }
    }
    if ($xj -and $null -ne $xj.week_used) {
        $xwRem = 100 - [int]$xj.week_used
        $seg = UsageBar "X:wk" $xwRem
        if ($null -ne $xj.session_used) {
            $xsRem = 100 - [int]$xj.session_used
            $seg = (UsageBar "X:5h" $xsRem) + (Color 250 " ") + (UsageBar "wk" $xwRem)
        }
        if ($null -ne $xj.spark_used) {
            $xpRem = 100 - [int]$xj.spark_used
            $seg += (Color 250 " ") + (UsageBar "spk" $xpRem)
        }
        $parts += $seg
    }
} catch {}

# --- Thinking / effort level ---
try {
    $eff = $null
    if ($data.effort -and $data.effort.level) { $eff = "$($data.effort.level)" }
    $thinkOn = $true
    if ($data.thinking -and $null -ne $data.thinking.enabled) { $thinkOn = [bool]$data.thinking.enabled }
    if (-not $thinkOn) { $parts += (Color 245 "th:off") }
    elseif ($eff) { $parts += (Color 117 "th:$eff") }
} catch {}

# --- Knowledge graph scope (nexus) ---
# Nexus auto-scopes to one client when a .nexus.json marker exists in the tree.
# A statusline cannot call the MCP, so show scope only: KG client or KG all.
$kg = "all"
try {
    $probe = if (-not [string]::IsNullOrWhiteSpace($dir)) { $dir } else { (Get-Location).Path }
    while (-not [string]::IsNullOrWhiteSpace($probe)) {
        $marker = Join-Path $probe ".nexus.json"
        if (Test-Path -LiteralPath $marker) {
            try {
                $nj = Get-Content -LiteralPath $marker -Raw -ErrorAction Stop | ConvertFrom-Json
                if ($nj.client)      { $kg = [string]$nj.client }
                elseif ($nj.slug)    { $kg = [string]$nj.slug }
                elseif ($nj.name)    { $kg = [string]$nj.name }
            } catch {}
            break
        }
        $parent = Split-Path -Parent $probe
        if ($parent -eq $probe) { break }
        $probe = $parent
    }
} catch {}
$parts += (Color 141 "KG:$kg")

# --- Weekly spend (cached; ccusage refreshed in background, 30 min TTL) ---
try {
    $cache = Join-Path $HOME ".claude\.statusline-spend.json"
    $spend = $null; $fresh = $false
    if (Test-Path -LiteralPath $cache) {
        $cj = Get-Content -LiteralPath $cache -Raw -ErrorAction Stop | ConvertFrom-Json
        $spend = $cj.spend
        $fresh = (((Get-Date) - [datetime]$cj.ts).TotalMinutes -lt 30)
    }
    if (-not $fresh) {
        $lock = "$cache.refreshing"
        $lockFree = $true
        if (Test-Path -LiteralPath $lock) {
            # stale locks (crashed refresher) expire after 5 minutes
            $lockFree = (((Get-Date) - (Get-Item -LiteralPath $lock).LastWriteTime).TotalMinutes -gt 5)
        }
        $refresher = Join-Path $HOME ".claude\statusline-spend-refresh.ps1"
        if ($lockFree -and (Test-Path -LiteralPath $refresher)) {
            New-Item -ItemType File -Force -Path $lock | Out-Null
            Start-Process powershell -ArgumentList "-NoProfile","-NonInteractive","-WindowStyle","Hidden","-ExecutionPolicy","Bypass","-File",$refresher -WindowStyle Hidden
        }
    }
    if ($null -ne $spend) { $parts += (Color 208 ("wk `$" + $spend)) }
} catch {}

# --- Caveman mode tag (orange) ---
try {
    $cfgDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME ".claude" }
    $flag = Join-Path $cfgDir ".caveman-active"
    if (Test-Path $flag) {
        $item = Get-Item -LiteralPath $flag -Force -ErrorAction Stop
        if (-not ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -and $item.Length -le 64) {
            $mode = ((Get-Content -LiteralPath $flag -TotalCount 1 -ErrorAction Stop) | Out-String).Trim().ToLowerInvariant()
            $mode = ($mode -replace '[^a-z0-9-]', '')
            $valid = @('off','lite','full','ultra','wenyan-lite','wenyan','wenyan-full','wenyan-ultra','commit','review','compress')
            if ($valid -contains $mode -and $mode -ne 'off') {
                if ($mode -eq 'full') { $parts += (Color 172 "[CAVEMAN]") }
                else { $parts += (Color 172 ("[CAVEMAN:" + $mode.ToUpperInvariant() + "]")) }
            }
        }
    }
} catch {}

[Console]::Write(($parts -join (Color 240 " | ")))
