# claudex orchestration test (portable - no workspace-specific agents needed)
#
# Verifies a claudex (GPT-via-Codex) session can orchestrate fresh subagents:
#   - 2x general-purpose subagents on the default tier (claude-opus-4-8 alias -> gpt-5.6-sol)
#   - 1x general-purpose subagent with model "haiku"   (claude-haiku-4-5 alias -> gpt-5.3-codex-spark)
# No fork-type subagents. Each subagent proves execution by writing an artifact
# file; the main agent aggregates. Checks run against self-generated fixtures
# (known ground truth) plus transcript evidence of real Agent spawns.
#
# Usage: powershell -ExecutionPolicy Bypass -File test\test-orchestration.ps1

$ErrorActionPreference = "Continue"
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$runDir = Join-Path (Split-Path $PSScriptRoot -Parent) "test-output\$stamp"
$fixDir = "$runDir\fixtures"
$outDir = "$runDir\artifacts"
New-Item -ItemType Directory -Force $fixDir, $outDir | Out-Null

# --- fixtures with known ground truth ---
$TRUTH_LINES = 37
$TRUTH_MD = 7
Set-Content "$fixDir\lines.txt" -Value ((1..$TRUTH_LINES | ForEach-Object { "line $_" }) -join "`n") -NoNewline -Encoding Ascii
New-Item -ItemType Directory -Force "$fixDir\rules" | Out-Null
1..$TRUTH_MD | ForEach-Object { Set-Content "$fixDir\rules\rule$_.md" -Value "# rule $_" -Encoding Ascii }

# --- claudex env (mirrors the claudex profile function) ---
$proxyKey = (Get-Content "$env:USERPROFILE\.cliproxyapi\.proxykey" -Raw).Trim()
$env:ANTHROPIC_BASE_URL = "http://127.0.0.1:8317"
$env:ANTHROPIC_AUTH_TOKEN = $proxyKey
$env:ANTHROPIC_DEFAULT_HAIKU_MODEL = "claude-haiku-4-5"
$env:CLAUDE_CODE_ALWAYS_ENABLE_EFFORT = "1"
$env:CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY = "3"
$env:_CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL = "1"

$claudeBin = $null
$cmd = Get-Command "claude.exe" -ErrorAction SilentlyContinue
if ($cmd) { $claudeBin = $cmd.Source }
elseif (Test-Path "$env:USERPROFILE\.local\bin\claude.exe") { $claudeBin = "$env:USERPROFILE\.local\bin\claude.exe" }
if (-not $claudeBin) { Write-Host "claude.exe not found" -ForegroundColor Red; exit 1 }

$prompt = @"
You are being tested on subagent orchestration. Follow these instructions EXACTLY.

Rules:
- You must NOT read files, count anything, or do any task work yourself.
- All work must be delegated via the Agent tool.
- Do NOT use subagent_type "fork" for anything.
- Spawn the three subagents below IN PARALLEL (all three Agent calls in one message).

Subagent 1 - subagent_type "general-purpose": Count the number of lines in
$fixDir\lines.txt and write EXACTLY one line of text
"lines=<number>" to $outDir\agent1.txt

Subagent 2 - subagent_type "general-purpose": Count how many .md files exist
directly in $fixDir\rules and write EXACTLY one line
"rulefiles=<number>" to $outDir\agent2.txt

Subagent 3 - subagent_type "general-purpose" AND set the Agent tool's model
parameter to "haiku": Write EXACTLY one line "spark-alive" to $outDir\agent3.txt

After all three subagents return: read the three files yourself (reading is
allowed for aggregation only) and write $outDir\summary.txt containing all
three values on three lines in the order agent1, agent2, agent3.

Final reply: the single word DONE if all four files were written, otherwise FAILED plus the reason.
"@

Push-Location $runDir
Write-Host ">> launching claudex orchestration run (this takes a few minutes)..." -ForegroundColor Cyan
$json = & $claudeBin --model claude-opus-4-8 -p $prompt --output-format json 2>$null | Out-String
Pop-Location

$result = $null
try {
    $parsed = $json | ConvertFrom-Json
    $result = @($parsed) | Where-Object { $_.type -eq 'result' } | Select-Object -Last 1
    if (-not $result) { $result = @($parsed) | Select-Object -Last 1 }
} catch {}
$sessionId = if ($result) { "$($result.session_id)" } else { $null }
$finalText = if ($result -and $result.result) { "$($result.result)" } else { "<no json result>" }

# --- checks ---
$pass = 0; $fail = 0
function Check($name, $ok, $detail) {
    if ($ok) { Write-Host ("PASS  {0}  {1}" -f $name, $detail) -ForegroundColor Green; $script:pass++ }
    else     { Write-Host ("FAIL  {0}  {1}" -f $name, $detail) -ForegroundColor Red;   $script:fail++ }
}

Write-Host ""
Write-Host "=== claudex orchestration test results ($stamp) ===" -ForegroundColor Cyan
Write-Host "final agent reply: $($finalText.Trim())"
Write-Host ""

$a1 = if (Test-Path "$outDir\agent1.txt") { (Get-Content "$outDir\agent1.txt" -Raw).Trim() } else { $null }
$a2 = if (Test-Path "$outDir\agent2.txt") { (Get-Content "$outDir\agent2.txt" -Raw).Trim() } else { $null }
$a3 = if (Test-Path "$outDir\agent3.txt") { (Get-Content "$outDir\agent3.txt" -Raw).Trim() } else { $null }

$a1val = if ($a1 -match 'lines=(\d+)') { [int]$Matches[1] } else { -999 }
Check "agent1 artifact (flagship tier)" ([Math]::Abs($a1val - $TRUTH_LINES) -le 1) "got '$a1', truth lines=$TRUTH_LINES"

$a2val = if ($a2 -match 'rulefiles=(\d+)') { [int]$Matches[1] } else { -999 }
Check "agent2 artifact (flagship tier)" ($a2val -eq $TRUTH_MD) "got '$a2', truth rulefiles=$TRUTH_MD"

Check "agent3 artifact (haiku/spark tier)" ($a3 -eq 'spark-alive') "got '$a3'"

$sum = if (Test-Path "$outDir\summary.txt") { (Get-Content "$outDir\summary.txt" -Raw) } else { "" }
$sumOk = $sum -match 'lines=' -and $sum -match 'rulefiles=' -and $sum -match 'spark-alive'
Check "main-agent aggregation (summary.txt)" $sumOk "content: $($sum.Trim() -replace "`r`n", ' | ')"

# transcript evidence: project dir is the munged cwd of the run
$projName = ($runDir -replace '[^A-Za-z0-9]', '-')
$projDir = "$env:USERPROFILE\.claude\projects\$projName"
$transcript = if ($sessionId) { "$projDir\$sessionId.jsonl" } else { $null }
$subDir = if ($sessionId) { "$projDir\$sessionId\subagents" } else { $null }
if ($transcript -and (Test-Path $transcript)) {
    $raw = Get-Content $transcript -Raw
    $agentCalls = ([regex]::Matches($raw, '"name":"Agent"')).Count
    Check "Agent tool invoked >= 3x" ($agentCalls -ge 3) "found $agentCalls Agent tool calls"

    $forkUse = ([regex]::Matches($raw, '"subagent_type"\s*:\s*"fork"')).Count
    Check "no fork subagents used" ($forkUse -eq 0) "fork spawns: $forkUse"

    $metas = @(if ($subDir -and (Test-Path $subDir)) { Get-ChildItem $subDir -Filter "*.meta.json" })
    Check "3 fresh subagent transcripts" ($metas.Count -ge 3) "found $($metas.Count) in $subDir"

    $haikuMsgs = 0
    if ($subDir -and (Test-Path $subDir)) {
        Get-ChildItem $subDir -Filter "agent-*.jsonl" | ForEach-Object {
            $haikuMsgs += ([regex]::Matches((Get-Content $_.FullName -Raw), '"model":"claude-haiku-4-5"')).Count
        }
    }
    Check "haiku tier (spark) actually used" ($haikuMsgs -gt 0) "found $haikuMsgs haiku-alias messages in subagent transcripts"
} else {
    Check "transcript found" $false "session_id=$sessionId, expected $transcript"
}

Write-Host ""
$verdict = if ($fail -eq 0) { "ALL PASS ($pass/$($pass+$fail))" } else { "FAILURES: $fail of $($pass+$fail)" }
$color = if ($fail -eq 0) { "Green" } else { "Red" }
Write-Host "=== $verdict ===" -ForegroundColor $color
Write-Host "artifacts: $outDir"
if ($transcript) { Write-Host "transcript: $transcript" }
if ($fail -gt 0) { exit 1 }
