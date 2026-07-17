# claudex behavior benchmark
#
# Measures how closely GPT-under-claudex matches native Claude behavior inside
# the Claude Code harness. Six deterministic tasks, each scored from artifacts
# and the session transcript (no LLM judging). Three configs:
#   baseline - claudex proxy env, no steering
#   steered  - claudex proxy env + --append-system-prompt bench\steering.md
#   control  - stock claude (no proxy env), real claude-opus-4-8
#
# Work dirs live OUTSIDE the workspace (in %TEMP%) so no ancestor CLAUDE.md
# leaks into the runs. Results land in bench-output\<stamp>\results.json.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File bench\behavior-bench.ps1
#   ... -Reps 2            repetitions per claudex config (control always 1)
#   ... -Only B1,B4        run a subset of tasks
#   ... -SkipControl / -SkipBaseline / -SkipSteered
#   ... -MaxTurns 12       turn cap per run

param(
    [int]$Reps = 2,
    [string[]]$Only = @(),
    [switch]$SkipControl,
    [switch]$SkipBaseline,
    [switch]$SkipSteered,
    [int]$MaxTurns = 12
)

$ErrorActionPreference = "Continue"
$repoRoot = Split-Path $PSScriptRoot -Parent
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$outRoot = Join-Path $repoRoot "bench-output\$stamp"
$workRoot = "$env:TEMP\claudex-bench\$stamp"
New-Item -ItemType Directory -Force $outRoot, $workRoot | Out-Null

$claudeBin = $null
$cmd = Get-Command "claude.exe" -ErrorAction SilentlyContinue
if ($cmd) { $claudeBin = $cmd.Source }
elseif (Test-Path "$env:USERPROFILE\.local\bin\claude.exe") { $claudeBin = "$env:USERPROFILE\.local\bin\claude.exe" }
if (-not $claudeBin) { Write-Host "claude.exe not found" -ForegroundColor Red; exit 1 }

$keyPath = "$env:USERPROFILE\.cliproxyapi\.proxykey"
if (-not (Test-Path $keyPath)) { Write-Host "proxy key not found - run install.ps1" -ForegroundColor Red; exit 1 }
$proxyKey = (Get-Content $keyPath -Raw).Trim()
$steeringText = (Get-Content "$PSScriptRoot\steering.md" -Raw)

# --- transcript helpers -----------------------------------------------------

function Get-Transcript($workdir, $sessionId) {
    if (-not $sessionId) { return $null }
    $projName = ($workdir -replace '[^A-Za-z0-9]', '-')
    $p = "$env:USERPROFILE\.claude\projects\$projName\$sessionId.jsonl"
    if (Test-Path $p) { return $p }
    return $null
}

function Get-ToolUseStats($transcriptPath) {
    # returns per-assistant-API-message tool_use name lists. The transcript
    # JSONL can split one API message across multiple lines (one per content
    # block), so group by message.id - not by line.
    $order = @()
    $byId = @{}
    if (-not $transcriptPath) { return ,@() }
    foreach ($line in (Get-Content $transcriptPath)) {
        $obj = $null
        try { $obj = $line | ConvertFrom-Json } catch { continue }
        if ("$($obj.type)" -ne "assistant") { continue }
        $content = $obj.message.content
        if ($null -eq $content) { continue }
        $mid = "$($obj.message.id)"
        if (-not $mid) { $mid = [Guid]::NewGuid().ToString() }
        $names = @($content | Where-Object { "$($_.type)" -eq "tool_use" } | ForEach-Object { "$($_.name)" })
        if ($names.Count -eq 0) { continue }
        if (-not $byId.ContainsKey($mid)) { $byId[$mid] = @(); $order += $mid }
        $byId[$mid] += $names
    }
    $perMsg = @()
    foreach ($mid in $order) { $perMsg += ,@($byId[$mid]) }
    return ,$perMsg
}

function Get-AllToolNames($perMsg) {
    $all = @()
    foreach ($m in $perMsg) { $all += $m }
    return ,$all
}

# --- task definitions -------------------------------------------------------
# Each task: Id, Name, Setup (param workdir), Prompt (param workdir, rep),
# Score (param ctx) -> @{ Pass=bool; Detail=string }
# ctx: Workdir, Result (final text), TranscriptPath, PerMsg (tool_use per msg)

$tasks = @(
    @{
        Id = "B1"; Name = "parallel tool batching"
        Setup = {
            param($w)
            Set-Content "$w\f1.txt" -Value ((1..3 | ForEach-Object { "a$_" }) -join "`n") -NoNewline -Encoding Ascii
            Set-Content "$w\f2.txt" -Value ((1..5 | ForEach-Object { "b$_" }) -join "`n") -NoNewline -Encoding Ascii
            Set-Content "$w\f3.txt" -Value ((1..7 | ForEach-Object { "c$_" }) -join "`n") -NoNewline -Encoding Ascii
        }
        Prompt = {
            param($w, $rep)
            "Use the Read tool to read these three files: $w\f1.txt and $w\f2.txt and $w\f3.txt. Then reply with ONLY one line 'total=<sum of the line counts of all three files>' and nothing else."
        }
        Score = {
            param($ctx)
            $batched = $false
            foreach ($m in $ctx.PerMsg) {
                if (@($m | Where-Object { $_ -eq "Read" }).Count -ge 2) { $batched = $true }
            }
            $correct = "$($ctx.Result)".Trim() -eq "total=15"
            @{ Pass = ($batched -and $correct); Detail = "batchedReads=$batched correctTotal=$correct result='$("$($ctx.Result)".Trim())'" }
        }
    },
    @{
        Id = "B2"; Name = "dedicated file tools over shell"
        Setup = { param($w) }
        Prompt = {
            param($w, $rep)
            "Create a file $w\out.txt containing exactly the single word 'hello' and then verify its content by reading it back. Reply with ONLY the word VERIFIED once done."
        }
        Score = {
            param($ctx)
            $all = Get-AllToolNames $ctx.PerMsg
            $usedWrite = @($all | Where-Object { $_ -eq "Write" }).Count -gt 0
            $usedRead = @($all | Where-Object { $_ -eq "Read" }).Count -gt 0
            $usedShell = @($all | Where-Object { $_ -eq "Bash" -or $_ -eq "PowerShell" }).Count -gt 0
            $fileOk = (Test-Path "$($ctx.Workdir)\out.txt") -and ((Get-Content "$($ctx.Workdir)\out.txt" -Raw).Trim() -eq "hello")
            @{ Pass = ($usedWrite -and $usedRead -and $fileOk -and -not $usedShell); Detail = "Write=$usedWrite Read=$usedRead shell=$usedShell fileOk=$fileOk" }
        }
    },
    @{
        Id = "B3"; Name = "exact output contract"
        Setup = { param($w) }
        Prompt = {
            param($w, $rep)
            "Create a file $w\marker.txt containing the text 'bench'. Then your ENTIRE final reply must be exactly the single word DONE - nothing before it, nothing after it."
        }
        Score = {
            param($ctx)
            $fileOk = (Test-Path "$($ctx.Workdir)\marker.txt")
            $exact = "$($ctx.Result)".Trim() -ceq "DONE"
            @{ Pass = ($fileOk -and $exact); Detail = "fileOk=$fileOk exactReply=$exact result='$("$($ctx.Result)".Trim())'" }
        }
    },
    @{
        Id = "B4"; Name = "CLAUDE.md rule adherence"
        Setup = {
            param($w)
            $md = "# Project rules`n`n- NEVER use the word 'leverage' in any reply.`n- Every reply MUST end with the token [LG-OK] as the last thing.`n"
            Set-Content "$w\CLAUDE.md" -Value $md -Encoding Ascii
        }
        Prompt = {
            param($w, $rep)
            "In 2-3 sentences, describe how an early-stage startup can use partnerships to grow revenue."
        }
        Score = {
            param($ctx)
            $r = "$($ctx.Result)".Trim()
            $endsOk = $r.EndsWith("[LG-OK]")
            $noBanned = $r -notmatch "(?i)leverage"
            @{ Pass = ($endsOk -and $noBanned); Detail = "endsWithToken=$endsOk avoidsBannedWord=$noBanned" }
        }
    },
    @{
        Id = "B5"; Name = "slash command execution"
        Setup = {
            param($w)
            New-Item -ItemType Directory -Force "$w\.claude\commands" | Out-Null
            $cmdMd = "---`ndescription: bench ping`n---`n`nReply with exactly this single line and nothing else:`n`nCLAUDEX_CMD_OK `$ARGUMENTS`n"
            Set-Content "$w\.claude\commands\bench-ping.md" -Value $cmdMd -Encoding Ascii
        }
        Prompt = { param($w, $rep) "/bench-ping run$rep" }
        Score = {
            param($ctx)
            $ok = "$($ctx.Result)".Trim() -eq "CLAUDEX_CMD_OK run$($ctx.Rep)"
            @{ Pass = $ok; Detail = "result='$("$($ctx.Result)".Trim())'" }
        }
    },
    @{
        Id = "B6"; Name = "subagent delegation"
        Setup = { param($w) }
        Prompt = {
            param($w, $rep)
            "Spawn exactly one subagent via the Agent tool (subagent_type general-purpose) whose task is to write a file $w\agent.txt containing exactly 'sub-ok'. You must NOT write the file yourself. After the subagent returns, reply with ONLY the word DELEGATED."
        }
        Score = {
            param($ctx)
            $all = Get-AllToolNames $ctx.PerMsg
            $usedAgent = @($all | Where-Object { $_ -eq "Agent" }).Count -gt 0
            $wroteItself = @($all | Where-Object { $_ -eq "Write" }).Count -gt 0
            $fileOk = (Test-Path "$($ctx.Workdir)\agent.txt") -and ((Get-Content "$($ctx.Workdir)\agent.txt" -Raw).Trim() -eq "sub-ok")
            @{ Pass = ($usedAgent -and $fileOk -and -not $wroteItself); Detail = "Agent=$usedAgent mainWroteItself=$wroteItself fileOk=$fileOk" }
        }
    }
)

if ($Only.Count -gt 0) { $tasks = @($tasks | Where-Object { $Only -contains $_.Id }) }

# --- runner -----------------------------------------------------------------

function Invoke-BenchRun($config, $task, $rep) {
    $workdir = Join-Path $workRoot "$config\$($task.Id)-r$rep"
    New-Item -ItemType Directory -Force $workdir | Out-Null
    & $task.Setup $workdir
    $prompt = & $task.Prompt $workdir $rep

    # env per config (set then always restore)
    $orig = @{}
    foreach ($k in "ANTHROPIC_BASE_URL","ANTHROPIC_AUTH_TOKEN","ANTHROPIC_DEFAULT_HAIKU_MODEL","CLAUDE_CODE_ALWAYS_ENABLE_EFFORT","_CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL") {
        $orig[$k] = [Environment]::GetEnvironmentVariable($k)
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        if ($config -eq "control") {
            foreach ($k in $orig.Keys) { [Environment]::SetEnvironmentVariable($k, $null) }
        } else {
            $env:ANTHROPIC_BASE_URL = "http://127.0.0.1:8317"
            $env:ANTHROPIC_AUTH_TOKEN = $proxyKey
            $env:ANTHROPIC_DEFAULT_HAIKU_MODEL = "claude-haiku-4-5"
            $env:CLAUDE_CODE_ALWAYS_ENABLE_EFFORT = "1"
            $env:_CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL = "1"
        }
        $extra = @()
        if ($config -eq "steered") { $extra += @("--append-system-prompt", $steeringText) }
        Push-Location $workdir
        $json = & $claudeBin --model claude-opus-4-8 -p $prompt --output-format json --max-turns $MaxTurns --dangerously-skip-permissions @extra 2>$null | Out-String
        Pop-Location
    } finally {
        $sw.Stop()
        foreach ($k in $orig.Keys) { [Environment]::SetEnvironmentVariable($k, $orig[$k]) }
    }

    $result = $null; $sessionId = $null; $numTurns = $null
    try {
        $parsed = $json | ConvertFrom-Json
        $res = @($parsed) | Where-Object { $_.type -eq 'result' } | Select-Object -Last 1
        if (-not $res) { $res = @($parsed) | Select-Object -Last 1 }
        $result = "$($res.result)"; $sessionId = "$($res.session_id)"; $numTurns = $res.num_turns
    } catch {}

    $transcriptPath = Get-Transcript $workdir $sessionId
    $perMsg = Get-ToolUseStats $transcriptPath
    $ctx = @{ Workdir = $workdir; Result = $result; TranscriptPath = $transcriptPath; PerMsg = $perMsg; Rep = $rep }
    $score = $null
    try { $score = & $task.Score $ctx } catch { $score = @{ Pass = $false; Detail = "scorer error: $_" } }

    return @{
        config = $config; task = $task.Id; taskName = $task.Name; rep = $rep
        pass = [bool]$score.Pass; detail = "$($score.Detail)"
        durationSec = [Math]::Round($sw.Elapsed.TotalSeconds, 1); numTurns = $numTurns
        sessionId = $sessionId
    }
}

# --- main loop ---------------------------------------------------------------

$configs = @()
if (-not $SkipBaseline) { $configs += @{ Name = "baseline"; Reps = $Reps } }
if (-not $SkipSteered)  { $configs += @{ Name = "steered";  Reps = $Reps } }
if (-not $SkipControl)  { $configs += @{ Name = "control";  Reps = 1 } }

$rows = @()
foreach ($cfg in $configs) {
    foreach ($task in $tasks) {
        for ($r = 1; $r -le $cfg.Reps; $r++) {
            Write-Host (">> {0} / {1} rep {2} ..." -f $cfg.Name, $task.Id, $r) -ForegroundColor Cyan
            $row = Invoke-BenchRun $cfg.Name $task $r
            $rows += $row
            $tag = if ($row.pass) { "PASS" } else { "FAIL" }
            $color = if ($row.pass) { "Green" } else { "Red" }
            Write-Host ("   {0}  {1}s  {2}" -f $tag, $row.durationSec, $row.detail) -ForegroundColor $color
            $rows | ConvertTo-Json -Depth 5 | Set-Content "$outRoot\results.json" -Encoding UTF8
        }
    }
}

# --- summary -----------------------------------------------------------------

Write-Host ""
Write-Host "=== claudex behavior bench ($stamp) ===" -ForegroundColor Cyan
foreach ($cfg in $configs) {
    $cfgRows = @($rows | Where-Object { $_.config -eq $cfg.Name })
    $p = @($cfgRows | Where-Object { $_.pass }).Count
    Write-Host ("{0}: {1}/{2} passed" -f $cfg.Name, $p, $cfgRows.Count)
}
Write-Host "results: $outRoot\results.json"
Write-Host "workdirs: $workRoot"
