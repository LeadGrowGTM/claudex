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
    $origEffort     = $env:CLAUDE_CODE_ALWAYS_ENABLE_EFFORT
    $origConc       = $env:CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY
    $origFirstParty = $env:_CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL
    try {
        $env:ANTHROPIC_BASE_URL = "http://127.0.0.1:8317"
        $env:ANTHROPIC_AUTH_TOKEN = $proxyKey
        $env:ANTHROPIC_DEFAULT_HAIKU_MODEL = "claude-haiku-4-5"
        $env:CLAUDE_CODE_ALWAYS_ENABLE_EFFORT = "1"
        $env:CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY = "3"
        $env:_CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL = "1"
        $extra = @()
        if ($Yolo) { $extra += "--dangerously-skip-permissions" }
        & $bin --model claude-opus-4-8 @extra @args
    } finally {
        $env:ANTHROPIC_BASE_URL = $origBase
        $env:ANTHROPIC_AUTH_TOKEN = $origToken
        $env:ANTHROPIC_DEFAULT_HAIKU_MODEL = $origHaiku
        $env:CLAUDE_CODE_ALWAYS_ENABLE_EFFORT = $origEffort
        $env:CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY = $origConc
        $env:_CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL = $origFirstParty
    }
}
