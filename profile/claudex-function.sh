# claudex: GPT via CLIProxyAPI (Codex/ChatGPT subscription billing) inside Claude Code.
# Linux/WSL counterpart of profile/claudex-function.ps1 - keep the two in sync.
#
# Model IDs are deliberately Anthropic IDs: Claude Code trims its system prompt,
# tool schemas, and ALL skill descriptions for model IDs it does not recognize
# (exact registry match, not a "claude-" prefix check). The proxy's
# oauth-model-alias maps them to real upstreams:
#   claude-opus-4-8  -> gpt-5.6-sol         (flagship, max effort)
#   claude-sonnet-5  -> gpt-5.6-terra       (mid tier, max effort)
#   claude-haiku-4-5 -> gpt-5.3-codex-spark (fast tier)
#
# CLAUDE_CODE_SUBAGENT_MODEL must stay UNSET: it overrides per-agent model
# frontmatter and would force every subagent onto the flagship tier.
claudex() {
    local proxy_dir="$HOME/.cliproxyapi"
    local key_path="$proxy_dir/.proxykey"
    local bin conf key

    if [ ! -f "$key_path" ]; then
        echo "claudex: proxy key not found at $key_path (run install.sh first)" >&2
        return 1
    fi

    bin=$(command -v claude 2>/dev/null) || bin="$HOME/.local/bin/claude"
    if [ ! -x "$bin" ]; then
        echo "claudex: claude not found on PATH or in ~/.local/bin" >&2
        return 1
    fi

    # Auto-start the proxy if it is not already running.
    # `setsid --fork` detaches into a new session and returns immediately; a plain
    # `nohup ... &` leaves the daemon parented here, so a non-interactive shell
    # blocks in wait() and `claudex -p ...` never returns.
    if ! pgrep -x cli-proxy-api >/dev/null 2>&1; then
        echo "claudex: starting CLIProxyAPI..." >&2
        conf="$proxy_dir/cliproxyapi.conf"
        ( cd "$proxy_dir" && setsid --fork ./cli-proxy-api -config "$conf" \
            >>"$proxy_dir/proxy.log" 2>&1 </dev/null )
        sleep 2
    fi

    key=$(tr -d '[:space:]' <"$key_path")

    # Force the permission mode on the command line. Under API-token auth
    # (ANTHROPIC_AUTH_TOKEN) Claude Code does not honor settings.json
    # `defaultMode`, so a claudex session would otherwise start read-only.
    # auto also covers every Task/Agent subagent: a parent in auto forces
    # subagents to inherit auto and ignores any permissionMode in their
    # frontmatter, so no separate subagent-permission handling is needed.
    local extra=(--permission-mode auto)
    if [ "$1" = "-Yolo" ] || [ "$1" = "--yolo" ]; then
        extra=(--dangerously-skip-permissions)
        shift
    fi

    # ponytail: `env` scopes these to the child, so there is no save/restore
    # dance like the PowerShell version needs. Your plain `claude` is untouched.
    env \
        ANTHROPIC_BASE_URL="http://127.0.0.1:8317" \
        ANTHROPIC_AUTH_TOKEN="$key" \
        ANTHROPIC_DEFAULT_HAIKU_MODEL="claude-haiku-4-5" \
        _CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL=1 \
        CLAUDE_CODE_AUTO_COMPACT_WINDOW=200000 \
        MAX_MCP_OUTPUT_TOKENS=25000 \
        "$bin" --model claude-opus-4-8 "${extra[@]}" "$@"
}

# --- why this env var is set, and why two others were removed ----------------
#
# CLAUDE_CODE_AUTO_COMPACT_WINDOW=200000
#   _CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL=1 (needed so Claude Code treats the
#   proxy as first-party) also satisfies Claude Code's native-1M gate:
#       TM(): if(!ctx?.native_1m) return false; if(provider==="firstParty" && Nd()) return true  -> 1e6
#       Nd(): if(_CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL) return true
#   claude-opus-4-8 and claude-sonnet-5 are both native_1m, so without this
#   override a claudex session gets a 1,000,000-token budget against an upstream
#   ceiling of ~258k (272k catalog x 0.95 effective) and overflows instead of
#   compacting. Verified live via /context:
#       (none)                        -> 1m
#       AUTO_COMPACT_WINDOW=250000    -> 250k
#       MAX_CONTEXT_TOKENS=272000     -> 1m  (ignored: gated to non-"claude-" IDs)
#       DISABLE_COMPACT + MAX_CONTEXT -> 272k (but kills /compact entirely)
#   200000 (was 240000): Claude Code counts the window with the Anthropic
#   tokenizer; upstream GPT-5.6-sol counts the same payload 5-12% higher, so a
#   240k Claude-count can be 260k+ GPT-tokens and 400 - the compaction request
#   itself included, which then cannot recover (observed: hard 400 mid-session).
#   ~58k buffer absorbs the tokenizer skew plus one fat tool result landing
#   between compact checks. ponytail: single global value; per-tier windows would
#   need a wrapper per model.
#
# MAX_MCP_OUTPUT_TOKENS=25000
#   Auto-compact fires between turns; a single huge MCP result (getleads/nexus)
#   injected mid-turn can spike one request past ~258k before the next check.
#   Capping the per-result size removes that spike path.
#
# NOT SET, and verified correct to leave unset - ENABLE_TOOL_SEARCH=false
#   Claude Code disables deferred tool search for non-first-party hosts ("Set
#   ENABLE_TOOL_SEARCH=true if your proxy forwards tool_reference blocks"), but
#   that check is `vn()==="firstParty" && !Nd()` - so the assume-first-party flag
#   above defeats it and tool search stays on. That turns out to be fine:
#   CLIProxyAPI does forward tool_reference blocks. Verified through the proxy -
#   /context reports tools deferred, and a prompt needing the deferred WebFetch
#   tool made GPT load the schema via ToolSearch and complete the fetch. Setting
#   it false would send every schema up front, ~5k extra tokens, for no gain.
#
# REMOVED - CLAUDE_CODE_ALWAYS_ENABLE_EFFORT=1
#   No-op in this configuration. Dk() checks its deny-list BEFORE the env var,
#   and claude-opus-4-8 already resolves true via NG(r,"effort").
#
# REMOVED - CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY=3
#   K3g() caps client-side tool *execution* concurrency (default 10); it does not
#   touch parallel_tool_calls sent to the model. Pure latency cost, and latency is
#   already claudex's measured weak point (BENCHMARKS.md).
