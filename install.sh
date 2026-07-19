#!/usr/bin/env bash
# claudex installer (Linux / WSL2)
# Sets up: CLIProxyAPI binary + config + proxy key + `claudex` shell function.
# Idempotent - safe to re-run for upgrades. Mirrors install.ps1's layout.
#
# Usage:
#   ./install.sh
#   ./install.sh --version 7.2.83   pin a CLIProxyAPI release (default below)
#   ./install.sh --skip-login       skip the Codex OAuth step
#   ./install.sh --skip-profile     don't touch ~/.bashrc
#   ./install.sh --systemd          also install a systemd --user unit
#
# Upstream also ships its own bash installer (router-for-me/cliproxyapi-installer).
# We don't use it: it installs to ~/cliproxyapi with its own config.yaml and
# systemd unit, which would fight this repo's config as a second source of truth.
set -euo pipefail

VERSION="7.2.83"   # keep in sync with install.ps1 - a version skew between a
                   # Windows and a Linux proxy is a miserable thing to debug
SKIP_LOGIN=0; SKIP_PROFILE=0; WANT_SYSTEMD=0
while [ $# -gt 0 ]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        --skip-login) SKIP_LOGIN=1; shift ;;
        --skip-profile) SKIP_PROFILE=1; shift ;;
        --systemd) WANT_SYSTEMD=1; shift ;;
        *) echo "unknown flag: $1" >&2; exit 2 ;;
    esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROXY_DIR="$HOME/.cliproxyapi"
AUTH_DIR="$HOME/.cli-proxy-api"
MARKER_START="# >>> claudex >>>"
MARKER_END="# <<< claudex <<<"

step() { printf '\033[36m>> %s\033[0m\n' "$1"; }
warn() { printf '\033[33m!! %s\033[0m\n' "$1"; }

# --- 0. prereq checks -------------------------------------------------------
for t in curl tar; do
    command -v "$t" >/dev/null || { echo "missing required tool: $t" >&2; exit 1; }
done

if CLAUDE_BIN=$(command -v claude 2>/dev/null); then
    step "claude CLI found: $CLAUDE_BIN"
elif [ -x "$HOME/.local/bin/claude" ]; then
    CLAUDE_BIN="$HOME/.local/bin/claude"
    step "claude CLI found: $CLAUDE_BIN"
else
    CLAUDE_BIN=""
    warn "claude CLI not found - install Claude Code first (https://claude.com/claude-code). Proxy setup will proceed; claudex won't work until claude is installed."
fi

# port 8317 must be free or already owned by cli-proxy-api
if command -v ss >/dev/null && ss -ltnp 2>/dev/null | grep -q ':8317 '; then
    if ! ss -ltnp 2>/dev/null | grep ':8317 ' | grep -q 'cli-proxy-api'; then
        echo "port 8317 is already in use by another process - stop it, or change the port in config/cliproxyapi.conf.template and the profile function before installing" >&2
        ss -ltnp 2>/dev/null | grep ':8317 ' >&2
        exit 1
    fi
fi

# WSL2 note: a Windows-side proxy on 127.0.0.1:8317 is reachable from WSL only
# under networkingMode=mirrored. This installer sets up a Linux-native proxy, so
# that doesn't matter - but do NOT point both at the same auth dir (see README).

# --- 1. proxy binary -------------------------------------------------------
mkdir -p "$PROXY_DIR"
BIN="$PROXY_DIR/cli-proxy-api"
if [ -x "$BIN" ]; then
    step "binary already present: $BIN (delete it to force re-download)"
else
    case "$(uname -m)" in
        x86_64|amd64)  ARCH="amd64" ;;
        aarch64|arm64) ARCH="aarch64" ;;
        *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;;
    esac
    # musl (Alpine/OpenWrt) needs the no-plugin build; glibc gets the default
    VARIANT=""
    ldd --version 2>&1 | grep -qi musl && VARIANT="_no-plugin"
    ASSET="CLIProxyAPI_${VERSION}_linux_${ARCH}${VARIANT}.tar.gz"
    URL="https://github.com/router-for-me/CLIProxyAPI/releases/download/v${VERSION}/${ASSET}"
    TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
    step "downloading $URL"
    curl -fsSL "$URL" -o "$TMP/$ASSET"
    tar -xzf "$TMP/$ASSET" -C "$TMP"        # tarball is flat, no top-level dir
    found="$(find "$TMP" -name cli-proxy-api -type f -print -quit)"
    [ -n "$found" ] || { echo "no cli-proxy-api binary inside $ASSET" >&2; exit 1; }
    install -m 0755 "$found" "$BIN"
    step "installed binary -> $BIN"
fi

# --- 2. proxy key ----------------------------------------------------------
KEY_PATH="$PROXY_DIR/.proxykey"
if [ -f "$KEY_PATH" ]; then
    step "proxy key already exists"
else
    umask 077
    od -An -tx1 -N24 /dev/urandom | tr -d ' \n' >"$KEY_PATH"
    step "generated proxy key -> $KEY_PATH"
fi

# --- 3. config -------------------------------------------------------------
CONF_PATH="$PROXY_DIR/cliproxyapi.conf"
if [ -f "$CONF_PATH" ]; then
    step "config already exists: $CONF_PATH (not overwritten - diff against config/cliproxyapi.conf.template for updates)"
    grep -q 'alias:[[:space:]]*"claude-opus-4-8"' "$CONF_PATH" && \
    grep -q 'alias:[[:space:]]*"claude-haiku-4-5"' "$CONF_PATH" || {
        warn "existing config is MISSING the model aliases - claudex will get the trimmed Claude Code harness (no skill descriptions)."
        warn "merge the oauth-model-alias block from config/cliproxyapi.conf.template, then restart the proxy. Verify with doctor.sh."
    }
    grep -q 'disable-image-generation' "$CONF_PATH" || \
        warn "config is missing 'disable-image-generation' - an unrequested image_generation tool is appended to every request, perturbing the tool array that prompt-cache prefix matching needs stable."
else
    key="$(tr -d '[:space:]' <"$KEY_PATH")"
    sed "s|__PROXY_KEY__|${key}|" "$REPO_ROOT/config/cliproxyapi.conf.template" >"$CONF_PATH"
    chmod 600 "$CONF_PATH"
    step "wrote config -> $CONF_PATH"
fi

# --- 4. shell function ------------------------------------------------------
if [ "$SKIP_PROFILE" -eq 0 ]; then
    # Copy the function next to the config and source it, so re-running the
    # installer upgrades the function without rewriting ~/.bashrc.
    install -m 0644 "$REPO_ROOT/profile/claudex-function.sh" "$PROXY_DIR/claudex-function.sh"
    RC="$HOME/.bashrc"
    [ -n "${ZSH_VERSION:-}" ] && RC="$HOME/.zshrc"
    touch "$RC"
    if ! grep -qF "$MARKER_START" "$RC"; then
        {
            printf '\n%s\n' "$MARKER_START"
            printf '[ -f "$HOME/.cliproxyapi/claudex-function.sh" ] && . "$HOME/.cliproxyapi/claudex-function.sh"\n'
            printf '%s\n' "$MARKER_END"
        } >>"$RC"
        step "claudex function sourced from $RC"
    else
        step "claudex function already wired into $RC (function body refreshed)"
    fi
fi

# --- 5. systemd (optional) --------------------------------------------------
if [ "$WANT_SYSTEMD" -eq 1 ]; then
    UNIT_DIR="$HOME/.config/systemd/user"
    mkdir -p "$UNIT_DIR"
    cat >"$UNIT_DIR/cliproxyapi.service" <<EOF
[Unit]
Description=CLIProxyAPI (claudex)
After=network.target

[Service]
Type=simple
WorkingDirectory=$PROXY_DIR
ExecStart=$BIN -config $CONF_PATH
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
EOF
    step "wrote $UNIT_DIR/cliproxyapi.service"
    if systemctl --user show-environment >/dev/null 2>&1; then
        systemctl --user daemon-reload
        systemctl --user enable --now cliproxyapi.service
        step "systemd user unit enabled and started"
        warn "WSL2: needs '[boot] systemd=true' in /etc/wsl.conf, and 'loginctl enable-linger $USER' or the unit dies at logout."
    else
        warn "systemd --user not available (WSL2 needs '[boot] systemd=true' in /etc/wsl.conf). Unit written but not enabled; claudex auto-starts the proxy anyway."
    fi
fi

# --- 6. start proxy ---------------------------------------------------------
# `setsid --fork` detaches into a new session and returns immediately. A plain
# `nohup ... &` leaves the daemon as a child of this script, so bash blocks in
# wait() at exit and the installer never returns even though it finished.
# stdin from /dev/null so it can never inherit and hold a pipe either.
if ! pgrep -x cli-proxy-api >/dev/null 2>&1; then
    ( cd "$PROXY_DIR" && setsid --fork "$BIN" -config "$CONF_PATH" \
        >>"$PROXY_DIR/proxy.log" 2>&1 </dev/null )
    sleep 2
    step "proxy started (log: $PROXY_DIR/proxy.log)"
else
    step "proxy already running (restart to pick up config changes: pkill -x cli-proxy-api; then re-run install.sh)"
fi

# --- 7. Codex OAuth ---------------------------------------------------------
mkdir -p "$AUTH_DIR"
if compgen -G "$AUTH_DIR/codex-*.json" >/dev/null; then
    step "Codex credential already present"
elif [ "$SKIP_LOGIN" -eq 1 ]; then
    step "SKIPPED login - run '$BIN -config $CONF_PATH -codex-device-login' manually before first use"
else
    # Device-code flow: no local callback port, no browser needed. The
    # -codex-login browser flow binds :1455 and its -oauth-callback-port flag is
    # broken (RedirectURI is hardcoded), so device login is the right default here.
    # -config is REQUIRED: without it the binary defaults to $(pwd)/config.yaml
    # and dies before login, and it needs the config to know where auth-dir is.
    step "launching Codex device login (open the printed URL, enter the code)..."
    "$BIN" -config "$CONF_PATH" -codex-device-login \
        || warn "device login did not complete - re-run: $BIN -config $CONF_PATH -codex-device-login"
fi

# --- 8. smoke test ----------------------------------------------------------
if [ -n "$CLAUDE_BIN" ] && compgen -G "$AUTH_DIR/codex-*.json" >/dev/null; then
    step "smoke test (flagship + fast tier)..."
    key="$(tr -d '[:space:]' <"$KEY_PATH")"
    smoke() {
        env ANTHROPIC_BASE_URL="http://127.0.0.1:8317" \
            ANTHROPIC_AUTH_TOKEN="$key" \
            _CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL=1 \
            "$CLAUDE_BIN" --model "$1" -p "Reply with the single word: ok" 2>/dev/null | tr -d '[:space:]'
    }
    r1="$(smoke claude-opus-4-8 || true)"
    r2="$(smoke claude-haiku-4-5 || true)"
    if [ "$r1" = "ok" ] && [ "$r2" = "ok" ]; then
        printf '\033[32m>> SMOKE TEST PASSED - open a NEW shell and run: claudex\033[0m\n'
    else
        printf '\033[31m>> SMOKE TEST FAILED (flagship=%s fast=%s) - check the proxy is running and the Codex login completed\033[0m\n' "'$r1'" "'$r2'"
        exit 1
    fi
else
    step "smoke test skipped (claude CLI or Codex credential missing). When ready: open a new shell and run claudex"
fi
