# Background refresher for the statusline Codex-usage cache.
# Reads the CLIProxyAPI codex OAuth credential (kept fresh by the proxy) and
# queries ChatGPT's wham/usage endpoint for rate-limit windows. Never run
# inline from the statusline - network call.

$cache = Join-Path $HOME ".claude\.statusline-codex.json"
$lock = "$cache.refreshing"
try {
    $credFile = Get-ChildItem "$env:USERPROFILE\.cli-proxy-api" -Filter "codex-*.json" -ErrorAction Stop | Select-Object -First 1
    if (-not $credFile) { return }
    $cred = Get-Content $credFile.FullName -Raw | ConvertFrom-Json
    $h = @{
        Authorization        = "Bearer $($cred.access_token)"
        "chatgpt-account-id" = $cred.account_id
        originator           = "codex_cli_rs"
        "User-Agent"         = "codex_cli_rs"
    }
    $r = Invoke-RestMethod -Uri "https://chatgpt.com/backend-api/wham/usage" -Headers $h -TimeoutSec 20

    $mainUsed = $null; $sessionUsed = $null; $sparkUsed = $null
    if ($r.rate_limit.primary_window) { $mainUsed = [int]$r.rate_limit.primary_window.used_percent }
    if ($r.rate_limit.secondary_window) { $sessionUsed = [int]$r.rate_limit.secondary_window.used_percent }
    foreach ($extra in @($r.additional_rate_limits)) {
        if ($extra.limit_name -match 'Spark' -and $extra.rate_limit.primary_window) {
            $sparkUsed = [int]$extra.rate_limit.primary_window.used_percent
        }
    }
    $out = @{
        ts           = (Get-Date).ToString("o")
        plan         = "$($r.plan_type)"
        week_used    = $mainUsed
        session_used = $sessionUsed
        spark_used   = $sparkUsed
    } | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText($cache, $out, [System.Text.UTF8Encoding]::new($false))
} catch {
    # token expired or offline - keep previous cache; the proxy refreshes the
    # token during normal claudex use
} finally {
    if (Test-Path $lock) { Remove-Item $lock -Force -ErrorAction SilentlyContinue }
}
