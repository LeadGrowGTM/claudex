#!/usr/bin/env bash
# claudex doctor (Linux / WSL2) - read-only health check of the whole chain.
# Run any time something feels off. Exits nonzero if any check fails.
#
# Usage:
#   ./doctor.sh
#   ./doctor.sh --smoke     also run live end-to-end calls through both model tiers
set -uo pipefail

SMOKE=0
[ "${1:-}" = "--smoke" ] && SMOKE=1

PROXY_DIR="$HOME/.cliproxyapi"
AUTH_DIR="$HOME/.cli-proxy-api"
CONF="$PROXY_DIR/cliproxyapi.conf"
pass=0; fail=0; warn=0

ok()    { printf '\033[32mOK    %-32s %s\033[0m\n' "$1" "${2:-}"; pass=$((pass+1)); }
bad()   { printf '\033[31mFAIL  %-32s %s\033[0m\n' "$1" "${2:-}"; fail=$((fail+1)); }
warns() { printf '\033[33mWARN  %-32s %s\033[0m\n' "$1" "${2:-}"; warn=$((warn+1)); }
check() { if [ "$1" = "1" ]; then ok "$2" "${3:-}"; else bad "$2" "${3:-}"; fi; }

printf '\033[36m=== claudex doctor ===\033[0m\n'

# 1. claude CLI
CLAUDE_BIN="$(command -v claude 2>/dev/null || true)"
[ -z "$CLAUDE_BIN" ] && [ -x "$HOME/.local/bin/claude" ] && CLAUDE_BIN="$HOME/.local/bin/claude"
check "$([ -n "$CLAUDE_BIN" ] && echo 1 || echo 0)" "claude CLI" "$CLAUDE_BIN"

# 2. proxy binary / key / config
check "$([ -x "$PROXY_DIR/cli-proxy-api" ] && echo 1 || echo 0)" "proxy binary" "$PROXY_DIR/cli-proxy-api"
check "$([ -f "$PROXY_DIR/.proxykey" ] && echo 1 || echo 0)" "proxy key" "$PROXY_DIR/.proxykey"
check "$([ -f "$CONF" ] && echo 1 || echo 0)" "config file" "$CONF"

if [ -f "$CONF" ]; then
    check "$(grep -q 'alias:[[:space:]]*"claude-opus-4-8"' "$CONF" && echo 1 || echo 0)" \
          "config: opus alias" "claude-opus-4-8 -> gpt-5.6-sol"
    check "$(grep -q 'alias:[[:space:]]*"claude-haiku-4-5"' "$CONF" && echo 1 || echo 0)" \
          "config: haiku alias" "claude-haiku-4-5 -> gpt-5.3-codex-spark"
    grep -q 'alias:[[:space:]]*"claude-sonnet-5"' "$CONF" && \
        warns "config: sonnet-5 alias" "claude-sonnet-5 is native_1m in Claude Code -> 1M budget vs ~258k upstream. Covered by CLAUDE_CODE_AUTO_COMPACT_WINDOW; drop the alias if subagents overflow."
    grep -qE 'debug:[[:space:]]*true|request-log:[[:space:]]*true' "$CONF" && \
        warns "config: debug logging" "request/debug logging is ON - payload logs accumulate in $AUTH_DIR/logs"
    grep -q 'disable-image-generation' "$CONF" || \
        warns "config: image generation" "unset - an unrequested image_generation tool is appended to every request (perturbs the stable tool array prompt-cache prefix matching needs)"
fi

# 3. proxy process + port + AGE
PID="$(pgrep -x cli-proxy-api 2>/dev/null | head -1 || true)"
if [ -n "$PID" ]; then
    ok "proxy process" "pid $PID"
else
    bad "proxy process" "not running (claudex auto-starts it, or run install.sh)"
fi

if [ -n "$PID" ]; then
    # The Codex reasoning replay cache is process-local memory with a 1h TTL
    # (CodexReasoningReplayCacheTTL). A proxy younger than the session has lost
    # the reasoning lineage for it - no error is raised, the session just starts
    # forgetting why it did things. Cheapest high-value check in this script.
    UP="$(ps -o etimes= -p "$PID" 2>/dev/null | tr -d ' ' || echo 0)"
    if [ "${UP:-0}" -lt 3600 ]; then
        warns "proxy uptime" "${UP}s (<1h) - if a session predates this restart, its reasoning replay cache is gone; expect repetition/odd tool choices. Restart the session, not the proxy."
    else
        ok "proxy uptime" "${UP}s"
    fi
fi

PORT_OK=0
if command -v ss >/dev/null && ss -ltn 2>/dev/null | grep -q ':8317 '; then
    PORT_OK=1; ok "port 8317" "listening"
elif [ -n "$PID" ]; then
    bad "port 8317" "proxy running but nothing listening on 8317"
else
    warns "port 8317" "nothing listening (expected while proxy is stopped)"
fi

# 4. proxy answers with the aliases in its model list
if [ "$PORT_OK" = "1" ] && [ -f "$PROXY_DIR/.proxykey" ]; then
    KEY="$(tr -d '[:space:]' <"$PROXY_DIR/.proxykey")"
    MODELS="$(curl -fsS -m 10 -H "Authorization: Bearer $KEY" http://127.0.0.1:8317/v1/models 2>/dev/null || true)"
    check "$([ -n "$MODELS" ] && echo 1 || echo 0)" "proxy /v1/models" "$([ -n "$MODELS" ] && echo "responded" || echo "no response")"
    for m in claude-opus-4-8 claude-haiku-4-5; do
        check "$(printf '%s' "$MODELS" | grep -q "\"$m\"" && echo 1 || echo 0)" "alias live: $m"
    done
fi

# 5. Codex credential
check "$(compgen -G "$AUTH_DIR/codex-*.json" >/dev/null && echo 1 || echo 0)" "codex credential" \
      "$(compgen -G "$AUTH_DIR/codex-*.json" >/dev/null && echo "$AUTH_DIR" || echo "run: $PROXY_DIR/cli-proxy-api -config $CONF -codex-device-login")"

# Sharing one auth dir between a Windows and a Linux proxy rotates the refresh
# token out from under the other; the server then returns refresh_token_reused,
# which CLIProxyAPI treats as non-retryable and marks the auth unavailable.
if [ -d /mnt/c/Users ] && compgen -G "/mnt/c/Users/*/.cli-proxy-api/codex-*.json" >/dev/null 2>&1; then
    warns "windows credential present" "a Windows-side Codex credential also exists. Never point both proxies at the same auth dir - refresh-token rotation will hard-fail one of them."
fi

# 6. shell function
check "$(grep -qF '# >>> claudex >>>' "$HOME/.bashrc" "$HOME/.zshrc" 2>/dev/null && echo 1 || echo 0)" \
      "shell function installed" "marker block in ~/.bashrc or ~/.zshrc"

# 6b. no claudex env vars leaked into this shell.
# claudex scopes them to the child via env(1), so they must never be set here.
# If they are, this shell's plain `claude` loses Remote Control and claude.ai
# features: Remote Control's gate is tqe() -> GUn(), which requires
# ANTHROPIC_BASE_URL unset or api.anthropic.com, and ANTHROPIC_AUTH_TOKEN
# switches auth to api-key mode. Expected to trip only when run from inside a
# claudex session, which is harmless.
LEAKED=""
for v in ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN _CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL; do
    [ -n "${!v:-}" ] && LEAKED="$LEAKED $v"
done
if [ -n "$LEAKED" ]; then
    warns "claudex env leaked" "set in this shell:$LEAKED - plain 'claude' here loses Remote Control and claude.ai features (fine if you are inside a claudex session)"
else
    ok "no claudex env leaked" "plain 'claude' in this shell keeps Remote Control"
fi

# 7. window sizing (the fix that keeps claudex from overflowing upstream)
FN="$PROXY_DIR/claudex-function.sh"
if [ -f "$FN" ]; then
    win=$(grep -oE 'CLAUDE_CODE_AUTO_COMPACT_WINDOW=[0-9]+' "$FN" | grep -oE '[0-9]+')
    check "$([ -n "$win" ] && echo 1 || echo 0)" \
          "context window pinned" "without it, native_1m aliases get a 1M budget vs ~258k upstream"
    # present-but-too-high (e.g. 240k) still 400s: Anthropic tokenizer undercounts
    # GPT-5.6-sol 5-12%, so a thin buffer lands the compaction request over ~258k.
    check "$([ -n "$win" ] && [ "$win" -le 210000 ] && echo 1 || echo 0)" \
          "context window headroom" "AUTO_COMPACT_WINDOW must be <=210000: ~258k ceiling minus tokenizer skew + one fat tool result"
fi

# 8. optional live smoke
if [ "$SMOKE" = "1" ]; then
    if [ -n "$CLAUDE_BIN" ] && [ "$PORT_OK" = "1" ] && compgen -G "$AUTH_DIR/codex-*.json" >/dev/null; then
        printf '\033[36m>> live smoke test (both tiers)...\033[0m\n'
        KEY="$(tr -d '[:space:]' <"$PROXY_DIR/.proxykey")"
        smoke() {
            env ANTHROPIC_BASE_URL="http://127.0.0.1:8317" \
                ANTHROPIC_AUTH_TOKEN="$KEY" \
                _CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL=1 \
                "$CLAUDE_BIN" --model "$1" -p "Reply with the single word: ok" 2>/dev/null | tr -d '[:space:]'
        }
        r1="$(smoke claude-opus-4-8 || true)"; r2="$(smoke claude-haiku-4-5 || true)"
        check "$([ "$r1" = "ok" ] && echo 1 || echo 0)" "smoke: flagship tier" "reply: '$r1'"
        check "$([ "$r2" = "ok" ] && echo 1 || echo 0)" "smoke: fast tier" "reply: '$r2'"
    else
        bad "smoke test" "prerequisites missing (claude CLI / credential / proxy)"
    fi
fi

echo
if [ "$fail" -eq 0 ]; then
    printf '\033[32m=== HEALTHY (%d ok, %d warnings) ===\033[0m\n' "$pass" "$warn"
else
    printf '\033[31m=== %d FAILURES (%d ok, %d warnings) ===\033[0m\n' "$fail" "$pass" "$warn"
    exit 1
fi
