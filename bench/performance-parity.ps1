# Claudex performance parity benchmark
#
# Measures routine permission handling, explicit auto-mode classification,
# organic delegation, and custom-agent model routing. No scenario asks for
# Agent use except the routing regression, which is intentionally forced.
#
# This script spends model quota only with -Live.
#
# Examples:
#   powershell -ExecutionPolicy Bypass -File bench\performance-parity.ps1
#   powershell -ExecutionPolicy Bypass -File bench\performance-parity.ps1 -Live -Variants claudex-auto -Scenarios routine,classifier -Profile P0
#   powershell -ExecutionPolicy Bypass -File bench\performance-parity.ps1 -Live -Variants claudex-policy,native-policy -Scenarios routine,organic,routing -Reps 3 -Profile P1

param(
    [switch]$Live,
    [ValidateSet("claudex-auto", "claudex-policy", "claudex-policy-auto", "native-policy")]
    [string[]]$Variants = @("claudex-policy"),
    [ValidateSet("routine", "classifier", "organic", "routing")]
    [string[]]$Scenarios = @("routine", "classifier", "organic", "routing"),
    [ValidateSet("P0", "P1", "P2")]
    [string]$Profile = "P0",
    [ValidateSet("low", "medium", "high", "xhigh", "max")]
    [string]$MainEffort = "max",
    [ValidateRange(1, 10)]
    [int]$Reps = 1,
    [string]$SettingsPath = "",
    [string]$OutputRoot = "",
    [string]$FixtureRoot = ""
)

$ErrorActionPreference = "Continue"
$repoRoot = Split-Path $PSScriptRoot -Parent
if (-not $SettingsPath) { $SettingsPath = Join-Path $repoRoot "config\claudex.settings.json" }
if (-not $OutputRoot) { $OutputRoot = Join-Path $repoRoot "bench-output" }
if (-not $FixtureRoot) { $FixtureRoot = Join-Path $env:TEMP "claudex-performance-parity" }

function Write-Utf8NoBom([string]$Path, [string]$Content) {
    $parent = Split-Path $Path -Parent
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

function Get-ClaudeBinary {
    $cmd = Get-Command "claude.exe" -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $fallback = "$env:USERPROFILE\.local\bin\claude.exe"
    if (Test-Path $fallback) { return $fallback }
    return $null
}

function Get-TranscriptPath([string]$Workdir, [string]$SessionId) {
    if (-not $SessionId) { return $null }
    $projectName = ($Workdir -replace '[^A-Za-z0-9]', '-')
    $path = "$env:USERPROFILE\.claude\projects\$projectName\$SessionId.jsonl"
    if (Test-Path $path) { return $path }
    return $null
}

function Convert-ToTimestamp($Value) {
    if (-not $Value) { return $null }
    try { return [DateTimeOffset]::Parse("$Value") } catch { return $null }
}

function Get-TranscriptStats([string]$TranscriptPath, [string]$SubagentDir) {
    $assistantIds = [System.Collections.Generic.HashSet[string]]::new()
    $toolIds = [System.Collections.Generic.HashSet[string]]::new()
    $agentIds = [System.Collections.Generic.HashSet[string]]::new()
    $nonSearcherAgentIds = [System.Collections.Generic.HashSet[string]]::new()
    $agentTypes = [System.Collections.Generic.HashSet[string]]::new()
    $mainWritePaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $agentByMessage = @{}
    $toolEvents = @{}
    $toolResults = @{}
    $models = [System.Collections.Generic.HashSet[string]]::new()
    $cacheRead = 0L
    $cacheCreate = 0L
    $inputTokens = 0L
    $outputTokens = 0L
    $permissionDeniedIds = [System.Collections.Generic.HashSet[string]]::new()
    $autoUnavailableLines = [System.Collections.Generic.HashSet[string]]::new()
    $explicitAgentModelCount = 0

    if ($TranscriptPath -and (Test-Path $TranscriptPath)) {
        foreach ($line in [System.IO.File]::ReadLines($TranscriptPath)) {
            $obj = $null
            try { $obj = $line | ConvertFrom-Json } catch { continue }

            if ($line -match '(?i)auto.?mode.*(unavailable|cannot determine)|temporarily unavailable.*auto mode|context canceled') {
                [void]$autoUnavailableLines.Add($line)
            }

            if ("$($obj.type)" -eq "assistant") {
                $messageId = "$($obj.message.id)"
                $isNewMessage = $false
                if ($messageId) { $isNewMessage = $assistantIds.Add($messageId) }
                if ($isNewMessage) {
                    $usage = $obj.message.usage
                    if ($usage) {
                        $cacheRead += [long]($usage.cache_read_input_tokens)
                        $cacheCreate += [long]($usage.cache_creation_input_tokens)
                        $inputTokens += [long]($usage.input_tokens)
                        $outputTokens += [long]($usage.output_tokens)
                    }
                    if ($obj.message.model) { [void]$models.Add("$($obj.message.model)") }
                }

                foreach ($block in @($obj.message.content)) {
                    if ("$($block.type)" -ne "tool_use") { continue }
                    $toolId = "$($block.id)"
                    if (-not $toolId -or -not $toolIds.Add($toolId)) { continue }
                    $toolName = "$($block.name)"
                    $timestamp = Convert-ToTimestamp $obj.timestamp
                    $filePath = $null
                    if ($block.input -and $block.input.file_path) { $filePath = "$($block.input.file_path)" }
                    $toolEvents[$toolId] = [ordered]@{
                        id = $toolId
                        name = $toolName
                        messageId = $messageId
                        timestamp = $timestamp
                        filePath = $filePath
                    }
                    if (($toolName -eq "Write" -or $toolName -eq "Edit") -and $filePath) {
                        [void]$mainWritePaths.Add([System.IO.Path]::GetFullPath($filePath))
                    }
                    if ($toolName -eq "Agent") {
                        [void]$agentIds.Add($toolId)
                        $agentType = "$($block.input.subagent_type)"
                        if ($agentType) { [void]$agentTypes.Add($agentType) }
                        if ($agentType -ne "smart-searcher") { [void]$nonSearcherAgentIds.Add($toolId) }
                        if (-not $agentByMessage.ContainsKey($messageId)) { $agentByMessage[$messageId] = 0 }
                        $agentByMessage[$messageId]++
                        if ($block.input -and $block.input.model) { $explicitAgentModelCount++ }
                    }
                }
            }

            if ("$($obj.type)" -eq "user") {
                foreach ($block in @($obj.message.content)) {
                    if ("$($block.type)" -ne "tool_result") { continue }
                    $toolId = "$($block.tool_use_id)"
                    if (-not $toolId) { continue }
                    $toolResults[$toolId] = Convert-ToTimestamp $obj.timestamp
                    $resultText = "$($block.content)"
                    if ($block.is_error -and $resultText -match '(?i)permission|denied|not allowed|cannot determine') {
                        [void]$permissionDeniedIds.Add($toolId)
                    }
                }
            }
        }
    }

    $maxParallelAgents = 0
    foreach ($count in $agentByMessage.Values) {
        if ($count -gt $maxParallelAgents) { $maxParallelAgents = $count }
    }

    $maxPowerShellGap = 0.0
    foreach ($toolId in $toolEvents.Keys) {
        $event = $toolEvents[$toolId]
        if ($event.name -ne "PowerShell" -or -not $event.timestamp -or -not $toolResults.ContainsKey($toolId) -or -not $toolResults[$toolId]) { continue }
        $gap = ($toolResults[$toolId] - $event.timestamp).TotalSeconds
        if ($gap -gt $maxPowerShellGap) { $maxPowerShellGap = $gap }
    }

    $subagentModels = [System.Collections.Generic.HashSet[string]]::new()
    $subagentWritePaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $subagentCount = 0
    $subagentDurationSec = 0.0
    if ($SubagentDir -and (Test-Path $SubagentDir)) {
        foreach ($childPath in @(Get-ChildItem $SubagentDir -Filter "agent-*.jsonl" | ForEach-Object { $_.FullName })) {
            $subagentCount++
            $firstTime = $null
            $lastTime = $null
            foreach ($line in [System.IO.File]::ReadLines($childPath)) {
                $obj = $null
                try { $obj = $line | ConvertFrom-Json } catch { continue }
                $timestamp = Convert-ToTimestamp $obj.timestamp
                if ($timestamp) {
                    if (-not $firstTime -or $timestamp -lt $firstTime) { $firstTime = $timestamp }
                    if (-not $lastTime -or $timestamp -gt $lastTime) { $lastTime = $timestamp }
                }
                if ("$($obj.type)" -ne "assistant") { continue }
                if ($obj.message.model) { [void]$subagentModels.Add("$($obj.message.model)") }
                foreach ($block in @($obj.message.content)) {
                    if ("$($block.type)" -ne "tool_use") { continue }
                    if (("$($block.name)" -eq "Write" -or "$($block.name)" -eq "Edit") -and $block.input.file_path) {
                        [void]$subagentWritePaths.Add([System.IO.Path]::GetFullPath("$($block.input.file_path)"))
                    }
                }
            }
            if ($firstTime -and $lastTime) { $subagentDurationSec += ($lastTime - $firstTime).TotalSeconds }
        }
    }

    $duplicatePaths = @()
    foreach ($path in $mainWritePaths) {
        if ($subagentWritePaths.Contains($path)) { $duplicatePaths += $path }
    }

    return [ordered]@{
        assistantRequestCount = $assistantIds.Count
        toolUseCount = $toolIds.Count
        agentCallCount = $agentIds.Count
        nonSearcherAgentCallCount = $nonSearcherAgentIds.Count
        agentTypes = @($agentTypes)
        maxParallelAgentCalls = $maxParallelAgents
        explicitAgentModelCount = $explicitAgentModelCount
        mainModels = @($models)
        subagentCount = $subagentCount
        subagentModels = @($subagentModels)
        subagentDurationSec = [Math]::Round($subagentDurationSec, 3)
        duplicateWriteCount = $duplicatePaths.Count
        duplicateWritePaths = $duplicatePaths
        permissionDenialCount = $permissionDeniedIds.Count
        autoModeUnavailableCount = $autoUnavailableLines.Count
        maxPowerShellToolGapSec = [Math]::Round($maxPowerShellGap, 3)
        cacheReadInputTokens = $cacheRead
        cacheCreationInputTokens = $cacheCreate
        inputTokens = $inputTokens
        outputTokens = $outputTokens
    }
}

function Get-ProxyErrorLogSet {
    $set = @{}
    $logDir = "$env:USERPROFILE\.cli-proxy-api\logs"
    if (-not (Test-Path $logDir)) { return $set }
    foreach ($file in @(Get-ChildItem $logDir -Filter "error-v1-messages-*.log" -File)) {
        $set[$file.FullName] = [long]$file.Length
    }
    return $set
}

function Get-NewProxyErrors($Before) {
    $segments = @()
    $after = Get-ProxyErrorLogSet
    foreach ($path in $after.Keys) {
        $start = 0L
        if ($Before.ContainsKey($path)) {
            $start = [long]$Before[$path]
            if ([long]$after[$path] -le $start) { continue }
        }
        $segments += [ordered]@{ path = $path; start = $start }
    }

    $http500 = 0
    $http502 = 0
    $http503 = 0
    $authUnavailable = 0
    $contextCanceled = 0
    foreach ($segment in $segments) {
        $skipBody = $false
        $stream = [System.IO.File]::Open($segment.path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            [void]$stream.Seek([long]$segment.start, [System.IO.SeekOrigin]::Begin)
            $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8, $true, 4096, $true)
            try {
                while ($null -ne ($line = $reader.ReadLine())) {
                    if ($line -match '^--- .*REQUEST BODY.*---$') { $skipBody = $true; continue }
                    if ($line -match '^--- .*RESPONSE.*---$') { $skipBody = $false; continue }
                    if ($skipBody -or $line.Length -gt 4096) { continue }
                    if ($line -match '(?i)^status(?: code)?:\s*500\b|HTTP\s+500\b') { $http500++ }
                    if ($line -match '(?i)^status(?: code)?:\s*502\b|HTTP\s+502\b') { $http502++ }
                    if ($line -match '(?i)^status(?: code)?:\s*503\b|HTTP\s+503\b') { $http503++ }
                    if ($line -match '(?i)auth_unavailable|no auth available') { $authUnavailable++ }
                    if ($line -match '(?i)context canceled') { $contextCanceled++ }
                }
            } finally {
                $reader.Dispose()
            }
        } finally {
            $stream.Dispose()
        }
    }

    return [ordered]@{
        errorLogCount = $segments.Count
        http500Count = $http500
        http502Count = $http502
        http503Count = $http503
        authUnavailableCount = $authUnavailable
        contextCanceledCount = $contextCanceled
    }
}

function Test-NodeScript([string]$Path) {
    $node = Get-Command "node.exe" -ErrorAction SilentlyContinue
    if (-not $node) { $node = Get-Command "node" -ErrorAction SilentlyContinue }
    if (-not $node) { return $false }
    & $node.Source $Path *> $null
    return ($LASTEXITCODE -eq 0)
}

$scenarioDefinitions = @{
    routine = @{
        Setup = {
            param($workdir)
            Write-Utf8NoBom "$workdir\sum.js" @'
function sum(values) {
  return values.length;
}
module.exports = { sum };
'@
            Write-Utf8NoBom "$workdir\sum.test.js" @'
const assert = require("assert");
const { sum } = require("./sum");
assert.strictEqual(sum([2, 3, 5]), 10);
console.log("routine-ok");
'@
        }
        Prompt = {
            param($workdir)
            "The test at $workdir\sum.test.js fails because $workdir\sum.js has one implementation bug. Fix only the implementation, run the test, and report the result."
        }
        Score = {
            param($workdir, $result, $stats)
            $nodeTest = Test-NodeScript "$workdir\sum.test.js"
            $noDenials = $stats.permissionDenialCount -eq 0
            $noAutoUnavailable = $stats.autoModeUnavailableCount -eq 0
            $pass = $nodeTest -and $noDenials -and $noAutoUnavailable
            return @{ pass = $pass; detail = "nodeTest=$nodeTest noDenials=$noDenials noAutoUnavailable=$noAutoUnavailable" }
        }
    }
    classifier = @{
        Setup = { param($workdir) }
        Prompt = {
            param($workdir)
            "Use the dedicated PowerShell tool exactly once to evaluate [Math]::Sqrt(81), then reply with only the numeric result."
        }
        Score = {
            param($workdir, $result, $stats)
            $resultOk = "$result".Trim() -match '^9(?:\.0+)?$'
            $noDenials = $stats.permissionDenialCount -eq 0
            $noAutoUnavailable = $stats.autoModeUnavailableCount -eq 0
            $pass = $resultOk -and $noDenials -and $noAutoUnavailable
            return @{ pass = $pass; detail = "result='$($result.Trim())' noDenials=$noDenials noAutoUnavailable=$noAutoUnavailable" }
        }
    }
    organic = @{
        Setup = {
            param($workdir)
            Write-Utf8NoBom "$workdir\CLAUDE.md" "# Fixture rules`r`n`r`n- Do not edit test files.`r`n- Run every test before reporting completion.`r`n"
            New-Item -ItemType Directory -Path "$workdir\alpha", "$workdir\beta", "$workdir\gamma" | Out-Null
            Write-Utf8NoBom "$workdir\alpha\impl.js" @'
function double(value) {
  return value + 2;
}
module.exports = { double };
'@
            Write-Utf8NoBom "$workdir\alpha\test.js" @'
const assert = require("assert");
const { double } = require("./impl");
assert.strictEqual(double(4), 8);
console.log("alpha-ok");
'@
            Write-Utf8NoBom "$workdir\beta\impl.js" @'
function sortNumbers(values) {
  return [...values].sort();
}
module.exports = { sortNumbers };
'@
            Write-Utf8NoBom "$workdir\beta\test.js" @'
const assert = require("assert");
const { sortNumbers } = require("./impl");
assert.deepStrictEqual(sortNumbers([10, 2, 1]), [1, 2, 10]);
console.log("beta-ok");
'@
            Write-Utf8NoBom "$workdir\gamma\impl.js" @'
function normalize(value) {
  return value.toLowerCase();
}
module.exports = { normalize };
'@
            Write-Utf8NoBom "$workdir\gamma\test.js" @'
const assert = require("assert");
const { normalize } = require("./impl");
assert.strictEqual(normalize("  Hello World  "), "hello world");
console.log("gamma-ok");
'@
        }
        Prompt = {
            param($workdir)
            "Three independent modules under $workdir have one implementation defect each. Find and fix all three defects without changing tests, run every test, and report completion."
        }
        Score = {
            param($workdir, $result, $stats)
            $alpha = Test-NodeScript "$workdir\alpha\test.js"
            $beta = Test-NodeScript "$workdir\beta\test.js"
            $gamma = Test-NodeScript "$workdir\gamma\test.js"
            $correct = $alpha -and $beta -and $gamma
            $anyAgent = $stats.agentCallCount -gt 0
            $nonSearcherAgent = $stats.nonSearcherAgentCallCount -gt 0
            $parallel = $stats.maxParallelAgentCalls -ge 2
            $noDuplicate = $stats.duplicateWriteCount -eq 0
            return @{
                pass = $correct -and $noDuplicate
                detail = "tests=$alpha/$beta/$gamma anyAgent=$anyAgent nonSearcherAgent=$nonSearcherAgent parallel=$parallel noDuplicate=$noDuplicate duplicateWrites=$($stats.duplicateWriteCount)"
            }
        }
    }
    routing = @{
        Setup = { param($workdir) }
        Prompt = {
            param($workdir)
            "Use the Agent tool with subagent_type tool-runner to create $workdir\routing.txt containing exactly route-ok. Do not provide the Agent model parameter. After it returns, reply with only ROUTED."
        }
        Score = {
            param($workdir, $result, $stats)
            $fileOk = (Test-Path "$workdir\routing.txt") -and ((Get-Content "$workdir\routing.txt" -Raw).Trim() -eq "route-ok")
            $haiku = @($stats.subagentModels | Where-Object { $_ -like "claude-haiku-4-5*" }).Count -gt 0
            $noExplicitModel = $stats.explicitAgentModelCount -eq 0
            $pass = $fileOk -and $haiku -and $noExplicitModel
            return @{ pass = $pass; detail = "file=$fileOk haiku=$haiku explicitModelCalls=$($stats.explicitAgentModelCount)" }
        }
    }
}

if (-not $Live) {
    Write-Host "Dry plan only. No model calls made." -ForegroundColor Yellow
    Write-Host "profile: $Profile"
    Write-Host "main effort: $MainEffort"
    Write-Host "variants: $($Variants -join ', ')"
    Write-Host "scenarios: $($Scenarios -join ', ')"
    Write-Host "repetitions: $Reps"
    Write-Host "settings: $SettingsPath"
    Write-Host "fixture root: $FixtureRoot"
    Write-Host "Add -Live to spend quota and run the matrix."
    exit 0
}

$claudeBin = Get-ClaudeBinary
if (-not $claudeBin) { throw "claude.exe not found" }

$usesPolicy = @($Variants | Where-Object { $_ -match 'policy' }).Count -gt 0
if ($usesPolicy) {
    if (-not (Test-Path $SettingsPath)) { throw "settings file not found: $SettingsPath" }
    try { Get-Content $SettingsPath -Raw | ConvertFrom-Json | Out-Null } catch { throw "invalid settings JSON: $SettingsPath" }
}

$usesProxy = @($Variants | Where-Object { $_ -like 'claudex-*' }).Count -gt 0
$proxyKey = $null
if ($usesProxy) {
    $keyPath = "$env:USERPROFILE\.cliproxyapi\.proxykey"
    if (-not (Test-Path $keyPath)) { throw "proxy key not found: $keyPath" }
    $proxyKey = (Get-Content $keyPath -Raw).Trim()
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss-fff"
$runRoot = Join-Path $OutputRoot "performance-$stamp"
$workRoot = Join-Path $FixtureRoot "performance-$stamp"
New-Item -ItemType Directory -Path $runRoot, $workRoot | Out-Null
$resultsPath = Join-Path $runRoot "results.json"
$manifestPath = Join-Path $runRoot "manifest.json"
$proxyConfigPath = "$env:USERPROFILE\.cliproxyapi\cliproxyapi.conf"
$proxyBinaryPath = "$env:USERPROFILE\.cliproxyapi\cli-proxy-api.exe"
$claudeVersion = (& $claudeBin --version 2>$null | Out-String).Trim()
$manifest = [ordered]@{
    startedAt = [DateTimeOffset]::Now.ToString("o")
    profile = $Profile
    mainEffort = $MainEffort
    variants = @($Variants)
    scenarios = @($Scenarios)
    repetitions = $Reps
    fixtureRoot = $workRoot
    claudeVersion = $claudeVersion
    proxyChannel = $(if ($usesProxy) { "stable" } else { $null })
    proxyBinaryPath = $(if ($usesProxy) { $proxyBinaryPath } else { $null })
    proxyBinarySha256 = $(if ($usesProxy -and (Test-Path $proxyBinaryPath)) { (Get-FileHash $proxyBinaryPath -Algorithm SHA256).Hash.ToLowerInvariant() } else { $null })
    proxyConfigSha256 = $(if ($usesProxy -and (Test-Path $proxyConfigPath)) { (Get-FileHash $proxyConfigPath -Algorithm SHA256).Hash.ToLowerInvariant() } else { $null })
    settingsSha256 = $(if ($usesPolicy) { (Get-FileHash $SettingsPath -Algorithm SHA256).Hash.ToLowerInvariant() } else { $null })
}
Write-Utf8NoBom $manifestPath ($manifest | ConvertTo-Json -Depth 5)

$environmentNames = @(
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_BASE_URL",
    "ANTHROPIC_AUTH_TOKEN",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL",
    "CLAUDE_CODE_SUBAGENT_MODEL",
    "_CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL",
    "CLAUDE_CODE_AUTO_COMPACT_WINDOW",
    "MAX_MCP_OUTPUT_TOKENS"
)

function Invoke-PerformanceRun([string]$Variant, [string]$Scenario, [int]$Rep) {
    $workdir = Join-Path $workRoot "$Variant\$Scenario-r$Rep"
    New-Item -ItemType Directory -Path $workdir | Out-Null
    $definition = $scenarioDefinitions[$Scenario]
    & $definition.Setup $workdir
    $prompt = & $definition.Prompt $workdir

    $originalEnvironment = @{}
    foreach ($name in $environmentNames) { $originalEnvironment[$name] = [Environment]::GetEnvironmentVariable($name) }

    $permissionMode = if ($Variant -match 'auto$') { "auto" } else { "acceptEdits" }
    $isNative = $Variant -eq "native-policy"
    $sessionId = [Guid]::NewGuid().ToString()
    $stderrPath = Join-Path $workdir "claude.stderr.log"
    $beforeErrors = Get-ProxyErrorLogSet
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $json = ""
    try {
        foreach ($name in $environmentNames) { [Environment]::SetEnvironmentVariable($name, $null) }
        if (-not $isNative) {
            $env:ANTHROPIC_BASE_URL = "http://127.0.0.1:8317"
            $env:ANTHROPIC_AUTH_TOKEN = $proxyKey
            $env:ANTHROPIC_DEFAULT_HAIKU_MODEL = "claude-haiku-4-5"
            $env:_CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL = "1"
            $env:CLAUDE_CODE_AUTO_COMPACT_WINDOW = "200000"
            $env:MAX_MCP_OUTPUT_TOKENS = "25000"
        }

        $arguments = @(
            "--model", "claude-opus-4-8",
            "--effort", $MainEffort,
            "--permission-mode", $permissionMode,
            "--session-id", $sessionId,
            "-p", $prompt,
            "--output-format", "json"
        )
        if ($Variant -match 'policy') { $arguments += @("--settings", $SettingsPath) }

        Push-Location $workdir
        try { $json = & $claudeBin @arguments 2> $stderrPath | Out-String } finally { Pop-Location }
    } finally {
        $stopwatch.Stop()
        foreach ($name in $environmentNames) { [Environment]::SetEnvironmentVariable($name, $originalEnvironment[$name]) }
    }

    $resultText = ""
    $numTurns = $null
    $resultPermissionDenials = 0
    $parseError = $null
    try {
        $parsed = $json | ConvertFrom-Json
        $resultRecord = @($parsed) | Where-Object { $_.type -eq "result" } | Select-Object -Last 1
        if (-not $resultRecord) { $resultRecord = @($parsed) | Select-Object -Last 1 }
        $resultText = "$($resultRecord.result)"
        $numTurns = $resultRecord.num_turns
        $resultPermissionDenials = @($resultRecord.permission_denials).Count
        if ($resultRecord.session_id) { $sessionId = "$($resultRecord.session_id)" }
    } catch {
        $parseError = "$_"
    }

    $transcriptPath = Get-TranscriptPath $workdir $sessionId
    $projectName = ($workdir -replace '[^A-Za-z0-9]', '-')
    $subagentDir = "$env:USERPROFILE\.claude\projects\$projectName\$sessionId\subagents"
    $stats = Get-TranscriptStats $transcriptPath $subagentDir
    $stats.permissionDenialCount += $resultPermissionDenials
    $proxyErrors = Get-NewProxyErrors $beforeErrors

    $score = $null
    try { $score = & $definition.Score $workdir $resultText $stats } catch { $score = @{ pass = $false; detail = "scorer error: $_" } }

    return [ordered]@{
        profile = $Profile
        mainEffort = $MainEffort
        variant = $Variant
        permissionMode = $permissionMode
        scenario = $Scenario
        rep = $Rep
        pass = [bool]$score.pass
        detail = "$($score.detail)"
        durationSec = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 3)
        numTurns = $numTurns
        sessionId = $sessionId
        transcriptPath = $transcriptPath
        parseError = $parseError
        metrics = $stats
        proxyErrors = $proxyErrors
    }
}

$rows = @()
foreach ($variant in $Variants) {
    foreach ($scenario in $Scenarios) {
        if ($scenario -eq "classifier" -and $variant -notmatch 'auto$') { continue }
        for ($rep = 1; $rep -le $Reps; $rep++) {
            Write-Host (">> {0} / {1} / rep {2}" -f $variant, $scenario, $rep) -ForegroundColor Cyan
            $row = Invoke-PerformanceRun $variant $scenario $rep
            $rows += $row
            Write-Utf8NoBom $resultsPath ($rows | ConvertTo-Json -Depth 10)
            $tag = if ($row.pass) { "PASS" } else { "FAIL" }
            $color = if ($row.pass) { "Green" } else { "Red" }
            Write-Host ("   {0} {1}s agents={2} nonSearcher={3} parallel={4} denials={5} autoUnavailable={6}" -f $tag, $row.durationSec, $row.metrics.agentCallCount, $row.metrics.nonSearcherAgentCallCount, $row.metrics.maxParallelAgentCalls, $row.metrics.permissionDenialCount, $row.metrics.autoModeUnavailableCount) -ForegroundColor $color
        }
    }
}

Write-Host ""
Write-Host "=== Claudex performance parity benchmark ===" -ForegroundColor Cyan
foreach ($variant in $Variants) {
    $variantRows = @($rows | Where-Object { $_.variant -eq $variant })
    $passed = @($variantRows | Where-Object { $_.pass }).Count
    Write-Host ("{0}: {1}/{2} scenario gates passed" -f $variant, $passed, $variantRows.Count)
}
Write-Host "manifest: $manifestPath"
Write-Host "results: $resultsPath"
Write-Host "work: $workRoot"
