# claudex: GPT via CLIProxyAPI (Codex/ChatGPT subscription billing) inside Claude Code.
#
# Model IDs are deliberately Anthropic IDs: Claude Code trims its system prompt,
# tool schemas, and ALL skill descriptions for model IDs it does not recognize
# (exact registry match, not a "claude-" prefix check). The proxy's
# oauth-model-alias maps them to real upstreams:
#   claude-opus-4-8  -> gpt-5.6-sol         (flagship, reasoning effort forced high)
#   claude-haiku-4-5 -> gpt-5.3-codex-spark (fast tier for haiku-class subagents)
#
# CLAUDE_CODE_SUBAGENT_MODEL must stay UNSET: it overrides per-agent model
# frontmatter and would force every subagent onto the flagship tier.
function claudex {
    param([switch]$Yolo)

    $proxyDir = "$env:USERPROFILE\.cliproxyapi"
    $keyPath = "$proxyDir\.proxykey"
    if (-not (Test-Path $keyPath)) {
        Write-Host "claudex: proxy key not found at $keyPath (run install.ps1 first)" -ForegroundColor Red
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

    # Auto-start the proxy if it is not already running
    if (-not (Get-Process cli-proxy-api -ErrorAction SilentlyContinue)) {
        Write-Host "claudex: starting CLIProxyAPI..." -ForegroundColor DarkGray
        Start-Process -FilePath "$proxyDir\cli-proxy-api.exe" -ArgumentList "-config", "$proxyDir\cliproxyapi.conf" -WorkingDirectory $proxyDir -WindowStyle Hidden
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
        # `defaultMode`, so a claudex session would otherwise start read-only.
        # The CLI flag takes precedence and restores the intended mode.
        $extra = @("--permission-mode", "auto")
        if ($Yolo) { $extra = @("--dangerously-skip-permissions") }
        & $bin --model claude-opus-4-8 @extra @args
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
