# Background refresher for the statusline weekly-spend cache.
# Spawned by statusline.ps1 when the cache is older than its TTL. Never run
# inline - ccusage takes seconds and would lag every statusline render.

$cache = Join-Path $HOME ".claude\.statusline-spend.json"
$lock = "$cache.refreshing"
try {
    $monday = (Get-Date).AddDays(-[int](Get-Date).DayOfWeek + 1).ToString("yyyyMMdd")
    $raw = ccusage weekly -j --offline -s $monday 2>&1
    $jsonStr = ($raw | Where-Object { $_ -notmatch 'WARN|INFO|Fetching|Loaded|Resolving|Resolved|Saved|\[ccusage\]' }) -join ""
    $jsonStr = $jsonStr -replace '^\s*\[ccusage\][^\{]*', ''
    $json = $jsonStr | ConvertFrom-Json
    $spend = [math]::Round($json.totals.totalCost, 2)
    $out = @{ ts = (Get-Date).ToString("o"); spend = $spend } | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText($cache, $out, [System.Text.UTF8Encoding]::new($false))
} catch {
    # leave any previous cache in place
} finally {
    if (Test-Path $lock) { Remove-Item $lock -Force -ErrorAction SilentlyContinue }
}
