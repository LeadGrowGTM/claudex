# Offline contract tests for the optional OpenAI server-compaction channel.
# No proxy process, network request, credential, installer, or Go build is used.
#
# Usage: powershell -ExecutionPolicy Bypass -File test\test-native-compaction-contract.ps1

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path $PSScriptRoot -Parent
$commit = "725aa9f1bd61c76edb315ae80c7be6215198621a"
$sourceRepo = "https://github.com/Johnnybyzhang/CLIProxyAPI.git"

$paths = @{
    InstallPs1 = "$repoRoot\install.ps1"
    InstallSh = "$repoRoot\install.sh"
    ProfilePs1 = "$repoRoot\profile\claudex-function.ps1"
    ProfileSh = "$repoRoot\profile\claudex-function.sh"
    DoctorPs1 = "$repoRoot\doctor.ps1"
    DoctorSh = "$repoRoot\doctor.sh"
    Readme = "$repoRoot\README.md"
}
$content = @{}
foreach ($name in $paths.Keys) {
    $content[$name] = Get-Content $paths[$name] -Raw
}

$pass = 0
$fail = 0
function Check($name, $ok, $detail) {
    if ($ok) {
        Write-Host ("PASS  {0}  {1}" -f $name, $detail) -ForegroundColor Green
        $script:pass++
    } else {
        Write-Host ("FAIL  {0}  {1}" -f $name, $detail) -ForegroundColor Red
        $script:fail++
    }
}

Write-Host "=== native compaction contract ===" -ForegroundColor Cyan

foreach ($name in @("InstallPs1", "InstallSh", "ProfilePs1", "ProfileSh", "DoctorPs1", "DoctorSh", "Readme")) {
    Check "$name exact commit pin" ($content[$name].Contains($commit)) $commit
}
Check "PowerShell exact source repo" ($content.InstallPs1.Contains($sourceRepo)) $sourceRepo
Check "shell exact source repo" ($content.InstallSh.Contains($sourceRepo)) $sourceRepo

Check "official Windows default retained" ($content.InstallPs1 -match '\[string\]\$Version\s*=\s*"7\.2\.83"' -and $content.InstallPs1 -match '\$exe = \$stableExe\s*\r?\nif \(Test-Path \$nativeCompactionMarker\)') "v7.2.83 unless marker exists"
Check "official Linux default retained" ($content.InstallSh -match 'VERSION="7\.2\.83"' -and $content.InstallSh -match 'BIN="\$STABLE_BIN"\s*\r?\nif \[ -f "\$NATIVE_COMPACTION_MARKER" \]') "v7.2.83 unless marker exists"
Check "Windows opt-in flag" ($content.InstallPs1 -match '\[switch\]\$NativeCompaction' -and $content.InstallPs1 -match 'if \(\$NativeCompaction\)') "explicit only"
Check "Linux opt-in flag" ($content.InstallSh -match '--native-compaction\) NATIVE_COMPACTION=1' -and $content.InstallSh -match 'if \[ "\$NATIVE_COMPACTION" -eq 1 \]') "explicit only"
Check "Windows channel flags exclusive" ($content.InstallPs1 -match 'if \(\$NativeCompaction -and \$StableProxy\)') "ambiguous request rejected"
Check "Linux channel flags exclusive" ($content.InstallSh -match 'if \[ "\$NATIVE_COMPACTION" -eq 1 \] && \[ "\$STABLE_PROXY" -eq 1 \]') "ambiguous request rejected"
Check "Windows stable switch" ($content.InstallPs1 -match '\[switch\]\$StableProxy' -and $content.InstallPs1 -match 'Move-Item \$nativeCompactionMarker \$archivedMarker') "marker archived"
Check "Linux stable switch" ($content.InstallSh -match '--stable-proxy\) STABLE_PROXY=1' -and $content.InstallSh -match 'mv "\$NATIVE_COMPACTION_MARKER" "\$ARCHIVED_MARKER"') "marker archived"
Check "no native state deletion" ($content.InstallPs1 -notmatch 'Remove-Item[^\r\n]*nativeCompaction' -and $content.InstallSh -notmatch '(?m)^\s*rm[^\r\n]*NATIVE_COMPACTION') "source and binary retained"
Check "no installer deletion" ($content.InstallPs1 -notmatch 'Remove-Item' -and $content.InstallSh -notmatch '(?m)^\s*rm(?:\s|$)') "installer assets archived"

$windowsPinOk = $content.InstallPs1.Contains('"fetch", "--depth", "1", "origin", $nativeCompactionCommit') -and
    $content.InstallPs1.Contains('"checkout", "--detach", $nativeCompactionCommit') -and
    $content.InstallPs1 -match 'rev-parse --verify HEAD' -and
    $content.InstallPs1 -match '\$nativeHead -ne \$nativeCompactionCommit'
Check "Windows immutable checkout" $windowsPinOk "fetch, detach, verify"
Check "Windows source origin locked" ($content.InstallPs1 -match 'remote get-url origin' -and $content.InstallPs1 -match '\$nativeOrigin -ne \$nativeCompactionRepo') "exact fork"
Check "Windows interrupted checkout recovery" ($content.InstallPs1 -match '\$sourceItems = @\(Get-ChildItem' -and $content.InstallPs1 -match 'if \(-not \$hasNativeHead\)' -and $content.InstallPs1 -match 'incomplete native compaction checkout is not clean') "resume empty dir or clean no-HEAD checkout"

$linuxPinOk = $content.InstallSh -match 'fetch --depth 1 origin "\$NATIVE_COMPACTION_COMMIT"' -and
    $content.InstallSh -match 'checkout --detach "\$NATIVE_COMPACTION_COMMIT"' -and
    $content.InstallSh -match 'rev-parse --verify HEAD' -and
    $content.InstallSh -match '"\$native_head" = "\$NATIVE_COMPACTION_COMMIT"'
Check "Linux immutable checkout" $linuxPinOk "fetch, detach, verify"
Check "Linux source origin locked" ($content.InstallSh -match 'remote get-url origin' -and $content.InstallSh -match '"\$native_origin" = "\$NATIVE_COMPACTION_REPO"') "exact fork"
Check "Linux interrupted checkout recovery" ($content.InstallSh -match 'first_source_entry=.*find' -and $content.InstallSh -match 'if native_head=.*rev-parse --verify HEAD' -and $content.InstallSh -match 'incomplete native compaction checkout is not clean') "resume empty dir or clean no-HEAD checkout"

Check "Windows clean source required" ($content.InstallPs1 -match 'status --porcelain --untracked-files=all' -and $content.InstallPs1 -match 'native compaction source is not clean') "fail closed"
Check "Linux clean source required" ($content.InstallSh -match 'status --porcelain --untracked-files=all' -and $content.InstallSh -match 'native compaction source is not clean') "fail closed"
Check "Windows Go floor" ($content.InstallPs1 -match 'Go 1\.26\+' -and $content.InstallPs1 -match '\$goMinor -lt 26') "Go 1.26+"
Check "Linux Go floor" ($content.InstallSh -match 'Go 1\.26\+' -and $content.InstallSh -match '"\$GO_MINOR" -lt 26') "Go 1.26+"
$windowsSideBySide = $content.InstallPs1.Contains('$nativeCompactionDir = "$proxyDir\native-compaction-$nativeCompactionCommit"') -and
    $content.InstallPs1.Contains('$nativeCompactionExe = "$nativeCompactionDir\cli-proxy-api.exe"')
$linuxSideBySide = $content.InstallSh.Contains('NATIVE_COMPACTION_DIR="$PROXY_DIR/native-compaction-$NATIVE_COMPACTION_COMMIT"') -and
    $content.InstallSh.Contains('NATIVE_COMPACTION_BIN="$NATIVE_COMPACTION_DIR/cli-proxy-api"')
Check "side-by-side Windows binary" $windowsSideBySide "stable binary untouched"
Check "side-by-side Linux binary" $linuxSideBySide "stable binary untouched"

Check "Windows marker stores commit only" ($content.InstallPs1 -match 'WriteAllText\(\$nativeCompactionMarker, "\$nativeCompactionCommit`n"') "no credential fields"
Check "Linux marker stores commit only" ($content.InstallSh.Contains('printf ''%s\n'' "$NATIVE_COMPACTION_COMMIT" >"$NATIVE_COMPACTION_MARKER"')) "no credential fields"
Check "Windows installer rejects marker mismatch" ($content.InstallPs1 -match 'marker names an unsupported commit') "fail closed"
Check "Linux installer rejects marker mismatch" ($content.InstallSh -match 'marker names an unsupported commit') "fail closed"
Check "Windows launcher validates marker" ($content.ProfilePs1 -match '\$markedCommit -ne \$nativeCompactionCommit' -and $content.ProfilePs1 -match 'proxy channel changed') "rejects stale channel"
Check "Linux launcher validates marker" ($content.ProfileSh -match '"\$marked_commit" != "\$native_compaction_commit"' -and $content.ProfileSh -match 'proxy channel changed') "rejects stale channel"
Check "Windows doctor verifies source and live path" ($content.DoctorPs1 -match 'native source pin' -and $content.DoctorPs1 -match '\$nativeStatusOk -and -not \$nativeDirty' -and $content.DoctorPs1 -match 'proxy channel live') "channel proof"
Check "Linux doctor verifies source and live path" ($content.DoctorSh -match 'native source pin' -and $content.DoctorSh -match 'if native_dirty=.*status --porcelain' -and $content.DoctorSh -match 'proxy channel live') "channel proof"

$docsOk = $content.Readme -match 'Experimental OpenAI server compaction' -and
    $content.Readme -match 'PR #4465' -and
    $content.Readme -match 'draft with merge conflicts' -and
    $content.Readme -match '/responses/compact' -and
    $content.Readme -match 'opaque compacted item' -and
    $content.Readme -match '-StableProxy' -and
    $content.Readme -match '--stable-proxy'
Check "risk and data behavior documented" $docsOk "draft, endpoint, capsule, rollback"

foreach ($path in @($paths.InstallPs1, $paths.ProfilePs1, $paths.DoctorPs1, $PSCommandPath)) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors) | Out-Null
    Check "PowerShell parses: $([System.IO.Path]::GetFileName($path))" ($errors.Count -eq 0) $(if ($errors.Count) { $errors[0].Message } else { "syntax OK" })
}

$bash = Get-Command "bash" -ErrorAction SilentlyContinue
if ($bash) {
    $bashKernel = (& $bash.Source -lc "uname -s").Trim()
    function ConvertTo-BashPath($path) {
        if ($bashKernel -eq "Linux" -and $path -match '^([A-Za-z]):\\(.*)$') {
            return "/mnt/$($Matches[1].ToLower())/$($Matches[2].Replace("\", "/"))"
        }
        return $path.Replace("\", "/")
    }
    $installShForBash = ConvertTo-BashPath $paths.InstallSh
    $profileShForBash = ConvertTo-BashPath $paths.ProfileSh
    $doctorShForBash = ConvertTo-BashPath $paths.DoctorSh
    # Git may materialize CRLF in a Windows worktree. Parse normalized streams,
    # matching the LF files produced by a Linux clone.
    & $bash.Source -lc "tr -d '\r' < '$installShForBash' | bash -n"
    $installShOk = ($LASTEXITCODE -eq 0)
    & $bash.Source -lc "tr -d '\r' < '$profileShForBash' | bash -n"
    $profileShOk = ($LASTEXITCODE -eq 0)
    & $bash.Source -lc "tr -d '\r' < '$doctorShForBash' | bash -n"
    $doctorShOk = ($LASTEXITCODE -eq 0)
    Check "bash parses: install.sh" $installShOk "syntax check"
    Check "bash parses: claudex-function.sh" $profileShOk "syntax check"
    Check "bash parses: doctor.sh" $doctorShOk "syntax check"
} else {
    Write-Host "SKIP  bash parser unavailable" -ForegroundColor Yellow
}

Write-Host ""
if ($fail -gt 0) {
    Write-Host "=== FAILURES: $fail of $($pass + $fail) ===" -ForegroundColor Red
    exit 1
}
Write-Host "=== ALL PASS ($pass/$pass) ===" -ForegroundColor Green
