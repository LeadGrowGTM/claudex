# claudex: GPT via CLIProxyAPI (Codex/ChatGPT subscription billing) inside Claude Code.
#
# Model IDs are deliberately Anthropic IDs: Claude Code trims its system prompt,
# tool schemas, and ALL skill descriptions for model IDs it does not recognize
# (exact registry match, not a "claude-" prefix check). The proxy's
# oauth-model-alias maps them to real upstreams:
#   claude-opus-4-8  -> gpt-5.6-sol          (flagship, max effort via --effort max)
#   claude-sonnet-5  -> gpt-5.6-terra        (mid tier, passthrough effort under P1)
#   claude-haiku-4-5 -> gpt-5.3-codex-spark  (fast tier for Haiku-class agents)
#
# CLAUDE_CODE_SUBAGENT_MODEL must stay UNSET: it overrides per-agent model
# frontmatter and would force every subagent onto the flagship tier.
function claudex {
    param(
        [switch]$Yolo,
        [switch]$Auto
    )

    if ($Yolo -and $Auto) {
        Write-Host "claudex: -Yolo and -Auto are mutually exclusive" -ForegroundColor Red
        return
    }

    $proxyDir = "$env:USERPROFILE\.cliproxyapi"
    $keyPath = "$proxyDir\.proxykey"
    $settingsPath = "$proxyDir\claudex.settings.json"
    if (-not (Test-Path $keyPath)) {
        Write-Host "claudex: proxy key not found at $keyPath (run install.ps1 first)" -ForegroundColor Red
        return
    }
    if (-not (Test-Path $settingsPath)) {
        Write-Host "claudex: settings not found at $settingsPath (re-run install.ps1)" -ForegroundColor Red
        return
    }
    try {
        Get-Content $settingsPath -Raw | ConvertFrom-Json | Out-Null
    } catch {
        Write-Host "claudex: invalid settings JSON at $settingsPath (re-run install.ps1)" -ForegroundColor Red
        return
    }

    $nativeCompactionCommit = "725aa9f1bd61c76edb315ae80c7be6215198621a"
    $nativeCompactionMarker = "$proxyDir\.native-compaction-enabled"
    $proxyBin = "$proxyDir\cli-proxy-api.exe"
    if (Test-Path $nativeCompactionMarker) {
        $markedCommit = (Get-Content $nativeCompactionMarker -Raw).Trim()
        if ($markedCommit -ne $nativeCompactionCommit) {
            Write-Host "claudex: unsupported native compaction marker '$markedCommit'" -ForegroundColor Red
            return
        }
        $proxyBin = "$proxyDir\native-compaction-$nativeCompactionCommit\cli-proxy-api.exe"
    }
    if (-not (Test-Path $proxyBin)) {
        Write-Host "claudex: selected proxy binary not found at $proxyBin (re-run install.ps1)" -ForegroundColor Red
        return
    }

    $bin = $null
    $cmd = Get-Command "claude.exe" -ErrorAction SilentlyContinue
    if ($cmd) { $bin = $cmd.Source }
    elseif (Test-Path "$env:USERPROFILE\.local\bin\claude.exe") { $bin = "$env:USERPROFILE\.local\bin\claude.exe" }
    if (-not $bin) {
        Write-Host "claudex: claude.exe not found on PATH or in ~\.local\bin" -ForegroundColor Red
        return
    }

    # Auto-start the selected proxy channel. Refuse a stale process from the
    # other channel so a marker change cannot silently keep old behavior.
    $proxyProc = Get-Process cli-proxy-api -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($proxyProc) {
        $runningPath = $proxyProc.Path
        if (-not $runningPath) {
            Write-Host "claudex: cannot verify the binary for proxy pid $($proxyProc.Id); stop it and retry" -ForegroundColor Red
            return
        }
        if ([System.IO.Path]::GetFullPath($runningPath) -ne [System.IO.Path]::GetFullPath($proxyBin)) {
            Write-Host "claudex: proxy channel changed; stop pid $($proxyProc.Id) and retry" -ForegroundColor Red
            return
        }
    } else {
        Write-Host "claudex: starting CLIProxyAPI..." -ForegroundColor DarkGray
        Start-Process -FilePath $proxyBin -ArgumentList "-config", "$proxyDir\cliproxyapi.conf" -WorkingDirectory $proxyDir -WindowStyle Hidden
        Start-Sleep -Seconds 2
    }

    $proxyKey = (Get-Content $keyPath -Raw).Trim()
    $origBase       = $env:ANTHROPIC_BASE_URL
    $origToken      = $env:ANTHROPIC_AUTH_TOKEN
    $origHaiku      = $env:ANTHROPIC_DEFAULT_HAIKU_MODEL
    $origFirstParty = $env:_CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL
    $origWindow     = $env:CLAUDE_CODE_AUTO_COMPACT_WINDOW
    try {
        $env:ANTHROPIC_BASE_URL = "http://127.0.0.1:8317"
        $env:ANTHROPIC_AUTH_TOKEN = $proxyKey
        $env:ANTHROPIC_DEFAULT_HAIKU_MODEL = "claude-haiku-4-5"
        $env:_CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL = "1"
        # _CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL also satisfies Claude Code's
        # native-1M gate, so claude-opus-4-8 / claude-sonnet-5 would otherwise get
        # a 1,000,000-token budget against a ~258k upstream ceiling and overflow
        # instead of compacting. See profile\claudex-function.sh for the decoded
        # gate and the live /context measurements.
        # 200000 (not 240000): Claude Code counts the window with the Anthropic
        # tokenizer, upstream GPT-5.6-sol counts the same payload 5-12% higher, so
        # a 240k Claude-count could be 260k+ GPT-tokens and 400 - including the
        # compaction request itself, which then can't recover. ~58k buffer absorbs
        # the skew plus a single fat tool result landing between compact checks.
        $env:CLAUDE_CODE_AUTO_COMPACT_WINDOW = "200000"
        # Cap any single MCP result (getleads/nexus can be huge) so one tool
        # response can't spike a request past the ~258k ceiling between checks.
        $origMcpOut = $env:MAX_MCP_OUTPUT_TOKENS
        $env:MAX_MCP_OUTPUT_TOKENS = "25000"
        # Force the permission mode on the command line. Under API-token auth
        # (ANTHROPIC_AUTH_TOKEN) Claude Code does not honor settings.json
        # `defaultMode`, so the CLI flag remains the source of truth.
        # acceptEdits removes routine classifier round trips while explicit
        # deny/ask rules in the Claudex settings remain authoritative. A parent
        # in acceptEdits also keeps subagents on the same policy boundary.
        $extra = @("--settings", $settingsPath, "--permission-mode", "acceptEdits")
        if ($Auto) { $extra = @("--settings", $settingsPath, "--permission-mode", "auto") }
        if ($Yolo) { $extra = @("--settings", $settingsPath, "--dangerously-skip-permissions") }
        # Profile P1: the proxy no longer force-maxes the gpt-5.6-* tier, so the
        # flagship main session sets its own reasoning here. Terra classifier and
        # Spark subagents stay at passthrough effort. A user --effort in @args
        # wins over this default (it comes later on the line).
        $effort = @("--effort", "max")
        & $bin --model claude-opus-4-8 @effort @extra @args
    } finally {
        $env:ANTHROPIC_BASE_URL = $origBase
        $env:ANTHROPIC_AUTH_TOKEN = $origToken
        $env:ANTHROPIC_DEFAULT_HAIKU_MODEL = $origHaiku
        $env:_CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL = $origFirstParty
        $env:CLAUDE_CODE_AUTO_COMPACT_WINDOW = $origWindow
        $env:MAX_MCP_OUTPUT_TOKENS = $origMcpOut
    }
}

# Removed, both verified no-ops or harmful in this configuration:
#   CLAUDE_CODE_ALWAYS_ENABLE_EFFORT=1     Dk() checks its deny-list BEFORE the
#     env var, and claude-opus-4-8 already resolves true via NG(r,"effort").
#   CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY=3 K3g() caps client-side tool execution
#     concurrency (default 10); it does not touch parallel_tool_calls sent to the
#     model. Pure latency cost, and latency is already the measured weak point.
