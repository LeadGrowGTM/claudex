#!/usr/bin/env bash
# claudex-aware statusline (Linux/WSL counterpart of statusline.ps1).
#
# Superset of a plain statusline: identical output for normal claude sessions,
# plus a marker naming the REAL upstream model when the session is running
# through the claudex proxy.
#
# Why the marker matters: claudex aliases GPT upstreams to real Anthropic model
# IDs on purpose - Claude Code strips ~73% of skill-description tokens for model
# IDs it does not recognize (measured: Skills 10k -> 2.7k, same proxy, same
# upstream, only the ID varied). So the wire must say claude-opus-4-8 while the
# model answering is gpt-5.6-sol. Without this marker a claudex session and a
# real Opus session are visually identical.
#
# Install: settings.json -> statusLine.command = this file's path.
set -uo pipefail

input=$(cat)
j() { printf '%s' "$input" | jq -r "$1" 2>/dev/null; }

model=$(j '.model.display_name // "?"')
model_id=$(j '.model.id // ""')
cost=$(j '.cost.total_cost_usd // 0')
ctx=$(j '.context_window.used_percentage // 0')
added=$(j '.cost.total_lines_added // 0')
removed=$(j '.cost.total_lines_removed // 0')
week=$(j '.rate_limits.seven_day.used_percentage // empty')

# Resolve the true upstream by reverse-mapping model.id through the proxy config.
# ANTHROPIC_BASE_URL is inherited by the statusline process, so its presence is
# the claudex signal - same detection the PowerShell version uses.
marker=""
dollar='$'
conf="$HOME/.cliproxyapi/cliproxyapi.conf"
if [ -n "${ANTHROPIC_BASE_URL:-}" ] && [ -f "$conf" ] && [ -n "$model_id" ]; then
    upstream=$(awk -v id="$model_id" '
        /name:/  { n = $0 }
        $0 ~ ("alias:[ \t]*\"" id "\"") {
            sub(/.*name:[ \t]*"/, "", n); sub(/".*/, "", n); print n; exit
        }' "$conf")
    # ponytail: unresolved alias still gets a marker - "you are proxied" is the
    # load-bearing half; the exact upstream is the nicety.
    marker=" claudex:${upstream:-proxied}"
    # Cost is a floor, not a figure: the Codex->Claude translator never sets
    # cache_creation_input_tokens, and this is priced at Anthropic rates anyway.
    dollar='~$'
fi

out=$(printf '%s%s | %s%.2f | Context: %.0f%% | +%s/-%s lines' \
    "$model" "$marker" "$dollar" "$cost" "$ctx" "$added" "$removed")
[ -n "$week" ] && out="$out | Wk: $(printf '%.0f' "$week")%"
printf '%s' "$out"
