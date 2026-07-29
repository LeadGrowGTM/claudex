# Mirrors ~/.codex/auth.json (Codex CLI's own OAuth session) into cli-proxy-api's
# codex-*.json credential (~/.cli-proxy-api). Both log in to the same OpenAI
# account under the same OAuth client_id, and OpenAI allows only one live
# refresh_token per (client_id, account) - whichever program refreshes last
# invalidates the other's copy. Codex CLI is the source of truth here: this
# script only ever copies its tokens into cli-proxy-api's file, never the
# other direction, and never triggers a refresh itself.
#
# Usage:
#   powershell -File sync-codex-auth.ps1            one sync pass, then exit
#   powershell -File sync-codex-auth.ps1 -Watch      sync once, then watch and
#                                                     re-sync on every change

param([switch]$Watch)

$ErrorActionPreference = "Stop"
$codexAuthPath = "$env:USERPROFILE\.codex\auth.json"
$proxyAuthDir  = "$env:USERPROFILE\.cli-proxy-api"
$proxyDir      = "$env:USERPROFILE\.cliproxyapi"
$logPath       = "$proxyAuthDir\logs\sync-codex-auth.log"
$nativeCompactionCommit = "725aa9f1bd61c76edb315ae80c7be6215198621a"
$nativeCompactionMarker = "$proxyDir\.native-compaction-enabled"
$nativeCompactionExe    = "$proxyDir\native-compaction-$nativeCompactionCommit\cli-proxy-api.exe"
$confPath = "$proxyDir\cliproxyapi.conf"

function Write-SyncLog($msg) {
    New-Item -ItemType Directory -Force (Split-Path $logPath -Parent) | Out-Null
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg
    Add-Content -Path $logPath -Value $line
    Write-Host $line
}

function Sync-CodexAuth {
    if (-not (Test-Path $codexAuthPath)) {
        Write-SyncLog "SKIP - Codex CLI auth file not found: $codexAuthPath"
        return
    }
    $dest = Get-ChildItem $proxyAuthDir -Filter "codex-*.json" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $dest) {
        Write-SyncLog "SKIP - no cli-proxy-api codex credential to sync into. Run: cli-proxy-api.exe -codex-login"
        return
    }

    try {
        $src = Get-Content $codexAuthPath -Raw | ConvertFrom-Json
        $dst = Get-Content $dest.FullName -Raw | ConvertFrom-Json
    } catch {
        Write-SyncLog "SKIP - failed to parse JSON ($($_.Exception.Message))"
        return
    }
    if (-not $src.tokens -or -not $src.tokens.refresh_token) {
        Write-SyncLog "SKIP - Codex CLI auth file has no tokens block"
        return
    }
    if ($dst.refresh_token -eq $src.tokens.refresh_token) {
        return # already in sync - stay quiet, this fires on every fs event
    }

    $dst.access_token  = $src.tokens.access_token
    $dst.id_token      = $src.tokens.id_token
    $dst.refresh_token = $src.tokens.refresh_token
    $dst.account_id    = $src.tokens.account_id
    $dst.last_refresh  = $src.last_refresh

    $tmpPath = "$($dest.FullName).sync-tmp"
    $json = $dst | ConvertTo-Json -Depth 10 -Compress
    [System.IO.File]::WriteAllText($tmpPath, $json, [System.Text.UTF8Encoding]::new($false))
    Move-Item -Path $tmpPath -Destination $dest.FullName -Force
    Write-SyncLog "synced -> $($dest.Name) (last_refresh: $($src.last_refresh))"

    # cli-proxy-api keeps the loaded credential in memory and can persist that
    # in-memory copy back over ours a few seconds later - a bare file swap
    # does not reliably stick. Bounce the process so it loads what we just wrote.
    Restart-Proxy
}

function Restart-Proxy {
    $proc = Get-Process cli-proxy-api -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $proc) { return }
    if (-not (Test-Path $confPath)) {
        Write-SyncLog "WARN - proxy running but no config at $confPath, not restarting"
        return
    }
    $exe = "$proxyDir\cli-proxy-api.exe"
    if ((Test-Path $nativeCompactionMarker) -and (Test-Path $nativeCompactionExe)) {
        $exe = $nativeCompactionExe
    }
    $proc | Stop-Process
    $proc.WaitForExit(5000) | Out-Null
    Start-Process -FilePath $exe -ArgumentList "-config", $confPath -WorkingDirectory $proxyDir -WindowStyle Hidden
    Write-SyncLog "restarted proxy ($exe) to pick up synced credential"
}

Sync-CodexAuth

if ($Watch) {
    $pidPath = "$proxyAuthDir\logs\sync-codex-auth.pid"
    if (Test-Path $pidPath) {
        $existingPid = (Get-Content $pidPath -Raw).Trim()
        $existingProc = Get-Process -Id $existingPid -ErrorAction SilentlyContinue
        if ($existingProc -and $existingProc.ProcessName -match "powershell") {
            Write-SyncLog "already watching under pid $existingPid - exiting"
            return
        }
    }
    New-Item -ItemType Directory -Force (Split-Path $pidPath -Parent) | Out-Null
    [System.IO.File]::WriteAllText($pidPath, "$PID", [System.Text.UTF8Encoding]::new($false))

    $codexAuthDir = Split-Path $codexAuthPath -Parent
    New-Item -ItemType Directory -Force $codexAuthDir | Out-Null

    $watcher = New-Object System.IO.FileSystemWatcher
    $watcher.Path = $codexAuthDir
    $watcher.Filter = Split-Path $codexAuthPath -Leaf
    $watcher.NotifyFilter = [System.IO.NotifyFilters]::LastWrite
    $watcher.EnableRaisingEvents = $true
    Write-SyncLog "watching $codexAuthPath for changes"

    $action = { Sync-CodexAuth }
    Register-ObjectEvent -InputObject $watcher -EventName Changed -Action $action | Out-Null
    Register-ObjectEvent -InputObject $watcher -EventName Created -Action $action | Out-Null
    Register-ObjectEvent -InputObject $watcher -EventName Renamed -Action $action | Out-Null

    while ($true) {
        Wait-Event -Timeout 60 | Remove-Event
    }
}
