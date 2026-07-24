# Offline Claudex performance-policy contract.
# No model calls, proxy restarts, settings installation, or external actions.

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path $PSScriptRoot -Parent
$settingsPath = Join-Path $repoRoot "config\claudex.settings.json"
$proxyTemplatePath = Join-Path $repoRoot "config\cliproxyapi.conf.template"
$launcherPsPath = Join-Path $repoRoot "profile\claudex-function.ps1"
$launcherShPath = Join-Path $repoRoot "profile\claudex-function.sh"
$installerPsPath = Join-Path $repoRoot "install.ps1"
$installerShPath = Join-Path $repoRoot "install.sh"
$doctorPsPath = Join-Path $repoRoot "doctor.ps1"
$doctorShPath = Join-Path $repoRoot "doctor.sh"
$benchmarkPath = Join-Path $repoRoot "bench\performance-parity.ps1"
$effortSwitcherPath = Join-Path $repoRoot "bench\set-effort-profile.ps1"

$pass = 0
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    if ($Ok) {
        Write-Host ("PASS  {0}  {1}" -f $Name, $Detail) -ForegroundColor Green
        $script:pass++
    } else {
        Write-Host ("FAIL  {0}  {1}" -f $Name, $Detail) -ForegroundColor Red
        $script:fail++
    }
}

function Contains-All($Values, [string[]]$Required) {
    $actual = @($Values | ForEach-Object { "$_" })
    foreach ($item in $Required) {
        if ($actual -notcontains $item) { return $false }
    }
    return $true
}

function Get-PropertyNames($Value) {
    $names = @()
    if ($null -eq $Value -or $Value -is [string]) { return $names }
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in $Value.Keys) {
            $names += "$key"
            $names += Get-PropertyNames $Value[$key]
        }
        return $names
    }
    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [pscustomobject])) {
        foreach ($item in $Value) { $names += Get-PropertyNames $item }
        return $names
    }
    foreach ($property in $Value.PSObject.Properties) {
        $names += $property.Name
        $names += Get-PropertyNames $property.Value
    }
    return $names
}

$settingsRaw = Get-Content $settingsPath -Raw
$settings = $null
try { $settings = $settingsRaw | ConvertFrom-Json } catch {}
Check "settings JSON parses" ($null -ne $settings) $settingsPath
if (-not $settings) { exit 1 }

$propertyNames = @(Get-PropertyNames $settings)
$secretFields = @($propertyNames | Where-Object { $_ -match '(?i)password|token|api.?key|credential|client.?secret|refresh.?token|private.?key' })
Check "settings has no secret-shaped fields" ($secretFields.Count -eq 0) ("matches=" + ($secretFields -join ','))
Check "settings has no env block" ($propertyNames -notcontains "env") "secrets stay outside settings"

$allow = @($settings.permissions.allow)
$ask = @($settings.permissions.ask)
$deny = @($settings.permissions.deny)

Check "Agent is statically allowed" ($allow -contains "Agent") "Agent"
Check "dedicated file tools allowed" (Contains-All $allow @("Read", "Edit", "Write", "Glob", "Grep")) "Read/Edit/Write/Glob/Grep"
Check "PowerShell inspection allowlist exists" (Contains-All $allow @(
    "PowerShell(Get-ChildItem *)",
    "PowerShell(Test-Path *)",
    "PowerShell(Get-FileHash *)",
    "PowerShell(Measure-Object *)",
    "PowerShell(git status *)",
    "PowerShell(git * status *)"
)) "narrow inspection rules"
Check "PowerShell test commands allowed" (Contains-All $allow @(
    "PowerShell(node *test.js)",
    "PowerShell(node *test.js *)",
    'PowerShell(node "*test.js")',
    'PowerShell(node "*test.js" *)',
    "PowerShell(node --test *test.js)",
    'PowerShell(node --test "*test.js")',
    "PowerShell(node --test '*test.js')",
    "PowerShell(npm test *)",
    "PowerShell(python -m pytest *)",
    "PowerShell(go test *)"
)) "quoted and unquoted deterministic test runners"
$riskyTransforms = @($allow | Where-Object { $_ -in @(
    "PowerShell(Where-Object *)",
    "PowerShell(ForEach-Object *)",
    "PowerShell(Select-Object *)"
) })
Check "PowerShell scriptblock transforms are not broadly allowed" ($riskyTransforms.Count -eq 0) "avoid hidden side effects in scriptblocks"
$allowedBuildHooks = @($allow | Where-Object { $_ -in @(
    "PowerShell(npm run build *)",
    "PowerShell(pnpm run build *)",
    "PowerShell(bun run build *)"
) })
Check "package build hooks are not statically allowed" ($allowedBuildHooks.Count -eq 0) "build scripts can execute arbitrary code"

Check "Bash deletion denied" (Contains-All $deny @(
    "Bash(rm *)",
    "Bash(rmdir *)",
    "Bash(unlink *)",
    "Bash(shred *)",
    "Bash(truncate *)"
)) "conventional deletion commands"
Check "PowerShell deletion and truncation denied" (Contains-All $deny @(
    "PowerShell(Remove-Item *)",
    "PowerShell(Clear-Content *)",
    "PowerShell(Set-Content *)",
    "PowerShell(Out-File *)"
)) "canonical aliases are covered"
Check "forced overwrite paths denied" (Contains-All $deny @(
    "Bash(sed *-i*)",
    "Bash(cp *--remove-destination*)",
    "Bash(mv * --force *)",
    "PowerShell(New-Item *-Force*)",
    "PowerShell(Copy-Item *-Force*)",
    "PowerShell(Move-Item *-Force*)",
    "PowerShell(Rename-Item *-Force*)",
    "PowerShell(Stop-Process *-Force*)"
)) "acceptEdits cannot force replacement or termination"
Check "cross-shell escapes denied" (Contains-All $deny @(
    "Bash(powershell *)",
    "Bash(pwsh *)",
    "Bash(cmd *)",
    "PowerShell(powershell *)",
    "PowerShell(pwsh *)",
    "PowerShell(cmd *)"
)) "dedicated PowerShell AST remains policy boundary"
Check "destructive Git denied across shells" (Contains-All $deny @(
    "Bash(git clean *)",
    "Bash(git * clean *)",
    "Bash(git reset --hard *)",
    "Bash(git * reset --hard *)",
    "Bash(git rebase *)",
    "Bash(git * rebase *)",
    "Bash(git *--force*)",
    "PowerShell(git clean *)",
    "PowerShell(git * clean *)",
    "PowerShell(git reset --hard *)",
    "PowerShell(git * reset --hard *)",
    "PowerShell(git rebase *)",
    "PowerShell(git * rebase *)",
    "PowerShell(git *--force*)"
)) "direct and option-prefixed forms"

Check "push is a human checkpoint" (Contains-All $ask @(
    "Bash(git push *)",
    "Bash(git * push *)",
    "PowerShell(git push *)",
    "PowerShell(git * push *)"
)) "direct and git -C forms"
Check "PR writes are human checkpoints" (Contains-All $ask @(
    "Bash(gh pr create *)",
    "Bash(gh * pr create *)",
    "Bash(gh pr merge *)",
    "Bash(gh * pr merge *)",
    "PowerShell(gh pr create *)",
    "PowerShell(gh * pr create *)",
    "PowerShell(gh pr merge *)",
    "PowerShell(gh * pr merge *)"
)) "direct and --repo forms"
Check "publication and deployment ask" (Contains-All $ask @(
    "Bash(npm publish *)",
    "PowerShell(npm publish *)",
    "Bash(wrangler deploy *)",
    "PowerShell(wrangler deploy *)",
    "Bash(docker push *)",
    "PowerShell(docker push *)"
)) "outward actions"
Check "option-prefixed outward actions ask" (Contains-All $ask @(
    "Bash(gh * api *)",
    "PowerShell(gh * api *)",
    "Bash(gh * secret *)",
    "PowerShell(gh * secret *)",
    "Bash(npm * publish *)",
    "PowerShell(npm * publish *)",
    "Bash(wrangler * deploy *)",
    "PowerShell(wrangler * deploy *)",
    "Bash(docker * push *)",
    "PowerShell(docker * push *)",
    "Bash(kubectl * apply *)",
    "PowerShell(kubectl * apply *)"
)) "global options cannot bypass checkpoints"

Check "auto allow defaults restored" (@($settings.autoMode.allow) -contains '$defaults') '$defaults'
Check "auto environment defaults restored" (@($settings.autoMode.environment) -contains '$defaults') '$defaults'
Check "auto shell classification is selective" ($settings.autoMode.classifyAllShell -eq $false) "classifyAllShell=false"

$expectedSkills = @(
    "codex-doc-router",
    "codex-harness-checker",
    "codex-harness-maker",
    "codex-harness-planner",
    "codex-harness-prover",
    "codex-smart-searcher",
    "codex-task-orchestrator",
    "codex-tool-runner"
)
$skillOverridesOk = $true
foreach ($skill in $expectedSkills) {
    $property = $settings.skillOverrides.PSObject.Properties[$skill]
    if (-not $property -or "$($property.Value)" -ne "user-invocable-only") { $skillOverridesOk = $false }
}
Check "Codex-only skills hidden from auto routing" $skillOverridesOk "8 user-invocable-only overrides"

$launcherPs = Get-Content $launcherPsPath -Raw
$launcherSh = Get-Content $launcherShPath -Raw
Check "Windows launcher defaults acceptEdits" ($launcherPs -match '\$extra\s*=\s*@\("--settings",\s*\$settingsPath,\s*"--permission-mode",\s*"acceptEdits"\)') "settings plus acceptEdits"
Check "Linux launcher defaults acceptEdits" ($launcherSh -match 'local extra=\(--settings "\$settings_path" --permission-mode acceptEdits\)') "settings plus acceptEdits"
Check "Windows launcher supports explicit Auto" ($launcherPs -match 'if \(\$Auto\).*--permission-mode", "auto"') "-Auto"
Check "Linux launcher supports explicit Auto" ($launcherSh -match '-Auto\|--auto') "--auto"
Check "Windows launcher keeps explicit Yolo" ($launcherPs -match 'if \(\$Yolo\).*--dangerously-skip-permissions') "-Yolo"
Check "Linux launcher keeps explicit Yolo" ($launcherSh -match '-Yolo\|--yolo') "--yolo"
Check "launcher modes are mutually exclusive" (($launcherPs -match 'mutually exclusive') -and ($launcherSh -match 'mutually exclusive')) "Windows and Linux"
Check "launchers fail closed on missing settings" (($launcherPs -match 'settings not found') -and ($launcherSh -match 'settings not found')) "Windows and Linux"
Check "launchers validate settings JSON" (($launcherPs -match 'ConvertFrom-Json') -and ($launcherSh -match 'jq -e') -and ($launcherSh -match 'python3 -c')) "Windows and Linux"
Check "no launcher wires broad steering" (($launcherPs -notmatch 'append-system-prompt') -and ($launcherSh -notmatch 'append-system-prompt')) "none"
Check "bypass is not launcher default" (($launcherPs.IndexOf('$extra = @("--settings", $settingsPath, "--permission-mode", "acceptEdits")') -lt $launcherPs.IndexOf('if ($Yolo)')) -and ($launcherSh.IndexOf('local extra=(--settings "$settings_path" --permission-mode acceptEdits)') -lt $launcherSh.IndexOf('elif [ "$want_yolo"'))) "Yolo remains conditional"

$installerPs = Get-Content $installerPsPath -Raw
$installerSh = Get-Content $installerShPath -Raw
$psBackupIndex = $installerPs.IndexOf('Copy-Item $settingsPath')
$psInstallIndex = $installerPs.IndexOf('WriteAllText($settingsPath')
$shBackupIndex = $installerSh.IndexOf('cp "$SETTINGS_PATH"')
$shInstallIndex = $installerSh.IndexOf('install -m 0644 "$SETTINGS_SOURCE" "$SETTINGS_PATH"')
Check "Windows installs Claudex settings" (($installerPs -match 'config\\claudex.settings.json') -and ($installerPs -match '\\claudex.settings.json')) "source and destination"
Check "Linux installs Claudex settings" (($installerSh -match 'config/claudex.settings.json') -and ($installerSh -match '\$PROXY_DIR/claudex.settings.json')) "source and destination"
Check "installers require Terra alias" (($installerPs -match 'claude-sonnet-5') -and ($installerSh -match 'claude-sonnet-5')) "Windows and Linux"
Check "Windows backs up settings before replacement" (($psBackupIndex -ge 0) -and ($psInstallIndex -gt $psBackupIndex)) "backup index=$psBackupIndex install index=$psInstallIndex"
Check "Linux backs up settings before replacement" (($shBackupIndex -ge 0) -and ($shInstallIndex -gt $shBackupIndex)) "backup index=$shBackupIndex install index=$shInstallIndex"

$doctorPs = Get-Content $doctorPsPath -Raw
$doctorSh = Get-Content $doctorShPath -Raw
Check "doctors require Terra alias" (($doctorPs -match 'config: sonnet alias') -and ($doctorSh -match 'config: sonnet alias')) "Windows and Linux"
Check "doctors verify live Terra alias" (($doctorPs -match 'alias live: claude-sonnet-5') -and ($doctorSh -match 'claude-opus-4-8 claude-sonnet-5 claude-haiku-4-5')) "Windows and Linux"

$benchmark = Get-Content $benchmarkPath -Raw
Check "benchmark requires explicit Live" (($benchmark -match 'if \(-not \$Live\)') -and ($benchmark -match 'Add -Live')) "quota guard"
Check "benchmark fixtures stay outside workspace" (($benchmark -match 'Join-Path \$env:TEMP "claudex-performance-parity"') -and ($benchmark -match 'fixtureRoot = \$workRoot')) "TEMP fixtures plus manifest path"
Check "routine gate rejects permission failures" (($benchmark -match '\$pass = \$nodeTest -and \$noDenials -and \$noAutoUnavailable') -and ($benchmark -match 'nodeTest=\$nodeTest noDenials=\$noDenials noAutoUnavailable=\$noAutoUnavailable')) "correctness plus zero denials"
$organicPromptMatch = [regex]::Match($benchmark, '(?s)organic\s*=\s*@\{.*?Prompt\s*=\s*\{(?<body>.*?)\}\s*Score\s*=')
$organicPrompt = if ($organicPromptMatch.Success) { $organicPromptMatch.Groups['body'].Value } else { "" }
Check "organic prompt has no delegation hint" (($organicPrompt -match 'Three independent modules under \$workdir') -and ($organicPrompt -notmatch '(?i)\bAgent\b|subagent|parallel')) "outcome-only organic fixture"
Check "routing regression omits model" ($benchmark -match 'Do not provide the Agent model parameter') "tool-runner frontmatter test"
Check "benchmark tracks parallel Agent calls" ($benchmark -match 'maxParallelAgentCalls') "message-id grouping"
Check "benchmark separates mandatory search delegation" (($benchmark -match 'nonSearcherAgentCallCount') -and ($benchmark -match '\$agentType -ne "smart-searcher"')) "organic evidence excludes required smart-searcher"
Check "benchmark skips proxy request bodies" ($benchmark -match '\$skipBody -or \$line.Length -gt 4096') "metadata only"
Check "benchmark detects appended proxy logs" (($benchmark -match '\$set\[\$file.FullName\] = \[long\]\$file.Length') -and ($benchmark -match '\$stream.Seek\(\[long\]\$segment.start')) "new files and appended bytes"
Check "benchmark writes reproducibility manifest" (($benchmark -match 'proxyChannel') -and ($benchmark -match 'proxyConfigSha256') -and ($benchmark -match 'settingsSha256') -and ($benchmark -match 'claudeVersion')) "channel and hashes"

$effortSwitcher = Get-Content $effortSwitcherPath -Raw
Check "effort switcher profiles are bounded" ($effortSwitcher -match 'ValidateSet\("P0", "P1", "P2"\)') "P0/P1/P2 only"
Check "effort switcher backs up only public state" (($effortSwitcher -match 'effort-profile.json') -and ($effortSwitcher -match 'configSha256') -and ($effortSwitcher -match 'effortBlock')) "hash plus effort block"
Check "effort switcher backup path is collision-safe" (($effortSwitcher -match 'while \(Test-Path \$backupDir\)') -and ($effortSwitcher -match '\$suffix\+\+')) "no backup overwrite"
Check "effort switcher never copies full config" (($effortSwitcher -notmatch 'Copy-Item\s+\$ConfigPath') -and ($effortSwitcher -notmatch '\[System\.IO\.File\]::Copy')) "no key-bearing backup"
Check "effort switcher rejects unknown payload" ($effortSwitcher -match 'proxy payload differs.*refusing to modify') "exact-layout guard"
Check "effort switcher verifies post-write state" ($effortSwitcher -match 'effort profile verification failed after write') "fail closed"

$proxyTemplate = Get-Content $proxyTemplatePath -Raw
$profile = "unknown"
if ($proxyTemplate -match 'name:\s*"gpt-5\.6-\*"' -and $proxyTemplate -match '"reasoning\.effort":\s*"max"') {
    $profile = "P0"
} elseif (($launcherPs -match '--effort",\s*"max"') -and ($launcherSh -match '--effort max')) {
    $profile = "P1"
} elseif (($launcherPs -match '--effort",\s*"high"') -and ($launcherSh -match '--effort high')) {
    $profile = "P2"
}
Check "effort profile is recognized" ($profile -ne "unknown") "profile=$profile"

Write-Host ""
$total = $pass + $fail
if ($fail -eq 0) {
    Write-Host "=== ALL PASS ($pass/$total), effort profile $profile ===" -ForegroundColor Green
    exit 0
}
Write-Host "=== FAILURES: $fail of $total ===" -ForegroundColor Red
exit 1
