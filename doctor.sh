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
NATIVE_COMPACTION_COMMIT="725aa9f1bd61c76edb315ae80c7be6215198621a"
NATIVE_COMPACTION_MARKER="$PROXY_DIR/.native-compaction-enabled"
NATIVE_COMPACTION_SOURCE="$PROXY_DIR/sources/CLIProxyAPI-$NATIVE_COMPACTION_COMMIT"
NATIVE_COMPACTION_BIN="$PROXY_DIR/native-compaction-$NATIVE_COMPACTION_COMMIT/cli-proxy-api"
SELECTED_PROXY_BIN="$PROXY_DIR/cli-proxy-api"
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
check "$([ -x "$PROXY_DIR/cli-proxy-api" ] && echo 1 || echo 0)" "proxy binary: stable" "$PROXY_DIR/cli-proxy-api"
if [ -f "$NATIVE_COMPACTION_MARKER" ]; then
    marked_commit="$(tr -d '[:space:]' <"$NATIVE_COMPACTION_MARKER")"
    check "$([ "$marked_commit" = "$NATIVE_COMPACTION_COMMIT" ] && echo 1 || echo 0)" \
          "proxy channel: native" "pinned commit: $marked_commit"
    check "$([ -x "$NATIVE_COMPACTION_BIN" ] && echo 1 || echo 0)" \
          "native compaction binary" "$NATIVE_COMPACTION_BIN"
    SELECTED_PROXY_BIN="$NATIVE_COMPACTION_BIN"
    if command -v git >/dev/null && [ -d "$NATIVE_COMPACTION_SOURCE/.git" ]; then
        if native_head="$(git -C "$NATIVE_COMPACTION_SOURCE" rev-parse --verify HEAD 2>/dev/null)"; then
            check "$([ "$native_head" = "$NATIVE_COMPACTION_COMMIT" ] && echo 1 || echo 0)" \
                  "native source pin" "HEAD: $native_head"
        else
            bad "native source pin" "could not read HEAD: $NATIVE_COMPACTION_SOURCE"
        fi
        if native_dirty="$(git -C "$NATIVE_COMPACTION_SOURCE" status --porcelain --untracked-files=all 2>/dev/null)"; then
            check "$([ -z "$native_dirty" ] && echo 1 || echo 0)" \
                  "native source clean" "$NATIVE_COMPACTION_SOURCE"
        else
            bad "native source clean" "could not inspect: $NATIVE_COMPACTION_SOURCE"
        fi
    else
        bad "native source pin" "Git or source checkout missing: $NATIVE_COMPACTION_SOURCE"
    fi
    warns "native compaction status" "experimental upstream draft #4465 is active"
else
    ok "proxy channel: stable" "official release binary"
fi
check "$([ -f "$PROXY_DIR/.proxykey" ] && echo 1 || echo 0)" "proxy key" "$PROXY_DIR/.proxykey"
check "$([ -f "$CONF" ] && echo 1 || echo 0)" "config file" "$CONF"

if [ -f "$CONF" ]; then
    check "$(grep -q 'alias:[[:space:]]*"claude-opus-4-8"' "$CONF" && echo 1 || echo 0)" \
          "config: opus alias" "claude-opus-4-8 -> gpt-5.6-sol"
    check "$(grep -q 'alias:[[:space:]]*"claude-sonnet-5"' "$CONF" && echo 1 || echo 0)" \
          "config: sonnet alias" "claude-sonnet-5 -> gpt-5.6-terra"
    check "$(grep -q 'alias:[[:space:]]*"claude-haiku-4-5"' "$CONF" && echo 1 || echo 0)" \
          "config: haiku alias" "claude-haiku-4-5 -> gpt-5.3-codex-spark"
    grep -qE 'debug:[[:space:]]*true|request-log:[[:space:]]*true' "$CONF" && \
        warns "config: debug logging" "request/debug logging is ON - payload logs accumulate in $AUTH_DIR/logs"
    grep -q 'disable-image-generation' "$CONF" || \
        warns "config: image generation" "unset - an unrequested image_generation tool is appended to every request (perturbs the stable tool array prompt-cache prefix matching needs)"
    if grep -q 'name:[[:space:]]*"gpt-5.6-\*"' "$CONF" && grep -q '"reasoning.effort":[[:space:]]*"max"' "$CONF"; then
        warns "config: role effort" "legacy gpt-5.6-* maximum override is active - classifiers and Terra subagents cannot use lower effort"
    else
        ok "config: role effort" "per-request effort reaches classifiers and subagents"
    fi
fi

# 2b. Claudex-only policy and routing settings
SETTINGS="$PROXY_DIR/claudex.settings.json"
check "$([ -f "$SETTINGS" ] && echo 1 || echo 0)" "Claudex settings file" "$SETTINGS"
SETTINGS_VALID=0
if [ -f "$SETTINGS" ]; then
    if command -v jq >/dev/null 2>&1; then
        jq -e . "$SETTINGS" >/dev/null 2>&1 && SETTINGS_VALID=1
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c 'import json,sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$SETTINGS" 2>/dev/null && SETTINGS_VALID=1
    else
        warns "Claudex settings JSON" "jq or python3 is required for validation"
    fi
    check "$SETTINGS_VALID" "Claudex settings JSON" "valid JSON"
fi
if [ "$SETTINGS_VALID" = "1" ]; then
    check "$(grep -q '"Agent"' "$SETTINGS" && echo 1 || echo 0)" "policy: Agent allowed" "static allow avoids classifier startup"
    check "$(grep -q 'PowerShell(Get-ChildItem \*)' "$SETTINGS" && echo 1 || echo 0)" "policy: PowerShell inspection" "dedicated tool parity"
    check "$(grep -q 'Bash(rm \*)' "$SETTINGS" && grep -q 'PowerShell(Remove-Item \*)' "$SETTINGS" && echo 1 || echo 0)" "policy: deletion denied" "Bash and PowerShell"
    check "$(grep -q 'Bash(git push \*)' "$SETTINGS" && grep -q 'PowerShell(git push \*)' "$SETTINGS" && echo 1 || echo 0)" "policy: push asks" "human checkpoint"
    DEFAULT_COUNT="$(grep -c '"\$defaults"' "$SETTINGS" || true)"
    check "$([ "$DEFAULT_COUNT" -ge 2 ] && echo 1 || echo 0)" "policy: auto defaults" "allow and environment"
    CODEX_COUNT="$(grep -c '"codex-.*":[[:space:]]*"user-invocable-only"' "$SETTINGS" || true)"
    check "$([ "$CODEX_COUNT" -eq 8 ] && echo 1 || echo 0)" "routing: Codex-only skills" "$CODEX_COUNT/8 hidden from automatic routing"
fi

# 2c. agent model drift (read-only, non-fatal - never flips doctor unhealthy).
# Every installed subagent pins a model in its frontmatter. Claude Code matches
# the ID exactly, then the proxy maps it via oauth-model-alias. A dated/variant ID
# the alias map misses (e.g. claude-sonnet-4-6) 502s "unknown provider" at spawn.
# Warn so the operator adds an alias; a bare tier name or an installed-config
# alias is already resolvable.
AGENTS_DIR="$HOME/.claude/agents"
if [ -d "$AGENTS_DIR" ]; then
    RESOLVABLE=" opus sonnet haiku claude-sonnet-5 claude-haiku-4-5 "
    if [ -f "$CONF" ]; then
        for a in $(grep -oE 'alias:[[:space:]]*"[^"]+"' "$CONF" | sed -E 's/.*"([^"]+)".*/\1/'); do
            RESOLVABLE="$RESOLVABLE$a "
        done
    fi
    UNMAPPED=0
    for agent_file in "$AGENTS_DIR"/*.md; do
        [ -e "$agent_file" ] || continue
        model="$(awk '/^model:/{print $2; exit}' "$agent_file")"
        [ -z "$model" ] && continue
        case "$RESOLVABLE" in
            *" $model "*) ;;
            *) UNMAPPED=$((UNMAPPED+1))
               warns "agent model unmapped" "$(basename "$agent_file") pins '$model' - no bare tier, installed cliproxyapi.conf alias, or DEFAULT model pin resolves it; add an oauth-model-alias entry" ;;
        esac
    done
    [ "$UNMAPPED" -eq 0 ] && ok "agent models mapped" "all ~/.claude/agents frontmatter models resolve"
fi

# 3. proxy process + port + AGE
PID="$(pgrep -x cli-proxy-api 2>/dev/null | head -1 || true)"
if [ -n "$PID" ]; then
    ok "proxy process" "pid $PID"
    live_path="$(readlink -f "/proc/$PID/exe" 2>/dev/null || true)"
    selected_path="$(readlink -f "$SELECTED_PROXY_BIN" 2>/dev/null || true)"
    check "$([ -n "$live_path" ] && [ "$live_path" = "$selected_path" ] && echo 1 || echo 0)" \
          "proxy channel live" "running: $live_path"
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
    for m in claude-opus-4-8 claude-sonnet-5 claude-haiku-4-5; do
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
FN="$PROXY_DIR/claudex-function.sh"
if [ -f "$FN" ]; then
    check "$(grep -q -- '--settings "$settings_path"' "$FN" && echo 1 || echo 0)" "function: settings wired" "$SETTINGS"
    check "$(grep -q -- '--permission-mode acceptEdits' "$FN" && echo 1 || echo 0)" "function: default permission" "acceptEdits"
    check "$(grep -q -- '-Auto|--auto' "$FN" && echo 1 || echo 0)" "function: explicit auto" "--auto"
fi

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
    win=$(grep -v '^[[:space:]]*#' "$FN" | grep -oE 'CLAUDE_CODE_AUTO_COMPACT_WINDOW=[0-9]+' | grep -oE '[0-9]+' | head -1)
    check "$([ -n "$win" ] && echo 1 || echo 0)" \
          "context window pinned" "without it, native_1m aliases get a 1M budget vs ~258k upstream"
    # present-but-too-high (e.g. 240k) still 400s: Anthropic tokenizer undercounts
    # GPT-5.6-sol 5-12%, so a thin buffer lands the compaction request over ~258k.
    check "$([ -n "$win" ] && [ "$win" -le 210000 ] && echo 1 || echo 0)" \
          "context window headroom" "AUTO_COMPACT_WINDOW must be <=210000: ~258k ceiling minus tokenizer skew + one fat tool result"
fi

# 7d. durable backup pin. Claude Code 2.1.219+ resolves the auto-compact window
# from CLAUDE_CODE_AUTO_COMPACT_WINDOW first, then a settings autoCompactWindow
# field. claudex.settings.json carries the same 200000 so the window stays pinned
# even if the env var fails to propagate. If present it must respect the same
# 100000..210000 band; absent is fine because the env pin above covers it.
sw=$(grep -oE '"autoCompactWindow"[[:space:]]*:[[:space:]]*[0-9]+' "$SETTINGS" 2>/dev/null | grep -oE '[0-9]+$' | head -1)
check "$(if [ -z "$sw" ] || { [ "$sw" -ge 100000 ] && [ "$sw" -le 210000 ]; }; then echo 1; else echo 0; fi)" \
      "settings autoCompactWindow headroom" "claudex.settings.json autoCompactWindow, if set, must be 100000..210000"

# 7b. recent proxy failures, metadata only. Request-body sections are skipped.
RECENT_FILES=0; ERROR_500=0; ERROR_502=0; ERROR_503=0; AUTH_UNAVAILABLE=0; CONTEXT_CANCELED=0
while IFS= read -r -d '' file; do
    RECENT_FILES=$((RECENT_FILES+1))
    SKIP_BODY=0
    while IFS= read -r line; do
        [[ "$line" =~ ^---.*REQUEST[[:space:]]BODY.*---$ ]] && { SKIP_BODY=1; continue; }
        [[ "$line" =~ ^---.*RESPONSE.*---$ ]] && { SKIP_BODY=0; continue; }
        [ "$SKIP_BODY" -eq 1 ] && continue
        [ "${#line}" -gt 4096 ] && continue
        lower="${line,,}"
        [[ "$lower" =~ ^status([[:space:]]code)?:[[:space:]]*500([^0-9]|$)|http[[:space:]]+500([^0-9]|$) ]] && ERROR_500=$((ERROR_500+1))
        [[ "$lower" =~ ^status([[:space:]]code)?:[[:space:]]*502([^0-9]|$)|http[[:space:]]+502([^0-9]|$) ]] && ERROR_502=$((ERROR_502+1))
        [[ "$lower" =~ ^status([[:space:]]code)?:[[:space:]]*503([^0-9]|$)|http[[:space:]]+503([^0-9]|$) ]] && ERROR_503=$((ERROR_503+1))
        [[ "$lower" == *auth_unavailable* || "$lower" == *"no auth available"* ]] && AUTH_UNAVAILABLE=$((AUTH_UNAVAILABLE+1))
        [[ "$lower" == *"context canceled"* ]] && CONTEXT_CANCELED=$((CONTEXT_CANCELED+1))
    done <"$file"
done < <(find "$AUTH_DIR/logs" -maxdepth 1 -type f -name 'error-v1-messages-*.log' -mmin -1440 -print0 2>/dev/null)
if [ "$RECENT_FILES" -gt 0 ]; then
    warns "proxy errors (24h)" "files=$RECENT_FILES HTTP500=$ERROR_500 HTTP502=$ERROR_502 HTTP503=$ERROR_503 auth_unavailable=$AUTH_UNAVAILABLE context_canceled=$CONTEXT_CANCELED"
else
    ok "proxy errors (24h)" "none"
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
