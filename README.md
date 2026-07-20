# claudex

Run OpenAI GPT models inside Claude Code on your ChatGPT/Codex subscription - with the FULL Claude Code harness: complete system prompt, tool schemas, skill descriptions, subagent orchestration, hooks, rules, and memory.

```
claudex                    # interactive GPT-5.6 Sol session in Claude Code
claudex -Yolo              # same, with --dangerously-skip-permissions
claudex -p "do the thing"  # headless one-shot
```

## Why this exists (the model-ID trim problem)

Pointing Claude Code at a non-Anthropic model via `ANTHROPIC_BASE_URL` mostly works - but Claude Code silently degrades the harness for any model ID it does not recognize (exact internal-registry match; a `claude-` prefix is NOT enough):

Measured with `/context` through the same proxy, same upstream, **only the model ID varied**:

| Payload section | unknown ID (`gpt-5.6-sol`) | recognized ID (`claude-opus-4-8`) |
|---|---|---|
| **Skills** | **2.7k** - names only, descriptions stripped | **10k** - full descriptions |
| System prompt | 1.4k minimal stub | 1.6k full |
| Tool schemas | 5.9k sent up front - tool search is disabled for unrecognized IDs, so nothing can be deferred | deferred |
| MCP servers | 1.1k - loaded | 1.1k - loaded |
| Custom agents | 2.3k | 2.3k |
| Memory files | 3.9k | 3.9k |

Stripped skill descriptions are the killer: **73% of the skill payload disappears**, so the model sees skill names but cannot know when to invoke any of them.

Two things this measurement corrected, both previously asserted here without evidence: MCP servers are **not** dropped for unrecognized IDs, and tool schemas are not "compact" - an unrecognized ID actually sends *more* tool tokens up front, because deferred tool search is unavailable to it.

**The fix:** [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) runs as a local proxy authenticated to your ChatGPT account, and its `oauth-model-alias` exposes GPT upstreams under real Anthropic model IDs:

| Claude Code sees | Actual upstream | Reasoning effort |
|---|---|---|
| `claude-opus-4-8` | `gpt-5.6-sol` | high (forced) |
| `claude-haiku-4-5` | `gpt-5.3-codex-spark` | default (fast) |

Claude Code believes it is talking to Anthropic models and sends full prompts; the proxy routes to Codex. Two tiers means haiku-class subagents (discovery/mechanical work) stay fast while the flagship handles reasoning - mirroring a native Claude Code cheap/expensive split.

## Install (Windows)

Prereqs (the installer validates these):
- Windows PowerShell 5.1+ (stock Windows 11)
- Claude Code installed (`claude.exe` on PATH or `~\.local\bin`) - warned if missing, proxy still installs
- A ChatGPT plan with Codex access (for the OAuth login step)
- Port 8317 free (hard error if another app owns it)

```powershell
gh repo clone LeadGrowGTM/claudex   # private repo - use gh, or git clone with credentials
cd claudex
powershell -ExecutionPolicy Bypass -File install.ps1
```

The installer (idempotent, re-run any time to upgrade or repair):
1. Validates prereqs (PowerShell version, claude CLI, port 8317)
2. Downloads the pinned CLIProxyAPI release to `~\.cliproxyapi\`
3. Generates a random local proxy key (`~\.cliproxyapi\.proxykey`)
4. Writes `cliproxyapi.conf` (model aliases + effort override) from the template; if a config already exists it is left alone, but the installer warns loudly when the model aliases are missing from it
5. Registers a hidden autostart launcher in your Startup folder
6. Installs the `claudex` function into your PowerShell profile (marker-delimited block, replaced on re-run)
7. Starts the proxy and runs the interactive Codex OAuth login (browser)
8. Smoke-tests both model tiers end-to-end

Flags: `-Version <x.y.z>`, `-SkipLogin`, `-SkipAutostart`, `-SkipProfile`.

## Install (Linux / WSL2)

Same layout, same config, same pinned proxy version - a bash port of the above.

```bash
git clone https://github.com/LeadGrowGTM/claudex && cd claudex
./install.sh                 # add --systemd for a systemd --user unit
```

Flags: `--version <x.y.z>`, `--skip-login`, `--skip-profile`, `--systemd`.

Differences from the Windows path:
- **Login uses the device-code flow** - prints a URL and a code, no browser or callback port needed. The `-codex-login` browser flow binds `:1455` and its `-oauth-callback-port` flag is broken (the redirect URI is hardcoded), so device login is the default here. To re-run it by hand, `-config` is **required** - the binary otherwise defaults to `$(pwd)/config.yaml` and dies before login:
  ```bash
  ~/.cliproxyapi/cli-proxy-api -config ~/.cliproxyapi/cliproxyapi.conf -codex-device-login
  ```
- **No autostart by default.** The `claudex` function starts the proxy on demand; `--systemd` writes a user unit instead. On WSL2 that needs `[boot] systemd=true` in `/etc/wsl.conf` plus `loginctl enable-linger $USER`, or the unit dies at logout.
- **The function is sourced, not inlined** into `~/.bashrc`, so re-running the installer upgrades it without rewriting your rc file.

**Do not run a Windows proxy and a Linux proxy against the same auth dir.** Credentials are portable plain JSON, but refresh tokens rotate: the second instance to refresh gets `refresh_token_reused`, which CLIProxyAPI treats as non-retryable and marks the auth unavailable. There is no cross-process locking and the credential write is a non-atomic in-place truncate. One machine, one login. (`doctor.sh` warns if it spots a Windows-side credential.)

Under WSL2 with `networkingMode=mirrored`, a Windows-side proxy on `127.0.0.1:8317` *is* reachable from WSL - so you can point a WSL `claudex` at a Windows proxy instead of installing a second one. That keeps one credential, at the cost of depending on an `[experimental]` `.wslconfig` setting.

## Health check

```powershell
powershell -ExecutionPolicy Bypass -File doctor.ps1          # read-only chain check
powershell -ExecutionPolicy Bypass -File doctor.ps1 -Smoke   # + live calls through both tiers
```

```bash
./doctor.sh            # read-only chain check
./doctor.sh --smoke    # + live calls through both tiers
```

Checks every link: PowerShell version, claude CLI, binary, key, config (both aliases present, debug logging off), proxy process, port 8317 ownership, live `/v1/models` listing both aliases, Codex credential, profile function. Exits nonzero on any failure - first thing to run when claudex misbehaves.

## Test the harness

```powershell
powershell -ExecutionPolicy Bypass -File test\test-orchestration.ps1
```

Spawns a headless claudex run that must orchestrate 3 parallel fresh subagents (no fork-type), two on the flagship tier and one on the fast tier, each proving execution by writing artifacts checked against known ground truth - plus transcript checks (Agent tool calls, zero forks, subagent transcript files, haiku-alias usage). 8 checks, exits nonzero on failure. Run it after any Claude Code update, proxy upgrade, or config change.

## Behavior benchmarks

Does GPT-under-claudex behave like native Claude in the harness? Measured across six deterministic dimensions (parallel tool batching, dedicated-tool choice, exact output contracts, CLAUDE.md adherence, slash commands, subagent delegation): **12/12 at baseline, matching native Claude's 6/6**. A steering system prompt added zero pass-rate gain and was left out of the claudex function. Native Claude remains faster on multi-step tasks. Full method, results, and latency tables: `BENCHMARKS.md`. Rerun with `bench\behavior-bench.ps1`.

![claudex behavior benchmark results](bench/results/2026-07-17/benchmark.png)

## How it fits together

```
claudex (PowerShell fn)                 sets ANTHROPIC_BASE_URL=127.0.0.1:8317 + aliased model IDs
  -> claude.exe --model claude-opus-4-8    full harness: skills, hooks, rules, memory, subagents
    -> CLIProxyAPI (local, port 8317)      oauth-model-alias: opus-4-8 -> sol, haiku-4-5 -> spark
      -> chatgpt.com Codex backend          your ChatGPT subscription, no API key billing
```

Your normal `claude` command is untouched - claudex sets env vars only inside its own invocation and restores them afterwards.

## Design decisions / gotchas

- **`CLAUDE_CODE_SUBAGENT_MODEL` must stay unset.** It overrides per-agent model frontmatter and forces every subagent onto the flagship tier (found via the orchestration test).
- **Alias must be an exact known Anthropic ID.** `claude-gpt-5.6-sol` still gets the trimmed harness; the registry check is exact-match.
- **The context window is pinned to 240k by the claudex function, and this is load-bearing.** `_CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL=1` (needed so Claude Code treats the proxy as first-party) also satisfies Claude Code's native-1M gate: `TM()` returns `1e6` when the model is `native_1m` and `provider==="firstParty" && Nd()`, and `Nd()` returns true for exactly that env var. Both `claude-opus-4-8` and `claude-sonnet-5` are `native_1m`, so an unpinned claudex session gets a **1,000,000-token budget against a ~258k upstream ceiling** (272k catalog x 0.95 effective) and overflows instead of compacting. `CLAUDE_CODE_AUTO_COMPACT_WINDOW=240000` moves the trigger below the real ceiling. Verified live via `/context`: unset -> `1m`; `AUTO_COMPACT_WINDOW=250000` -> `250k`; `CLAUDE_CODE_MAX_CONTEXT_TOKENS=272000` alone -> `1m` (ignored - `aNc()` gates it to model IDs that do *not* start with `claude-`); `DISABLE_COMPACT=1` + `MAX_CONTEXT_TOKENS=272000` -> `272k`, but that also removes `/compact` entirely.
- **The fast tier is still oversized.** `claude-haiku-4-5` is not `native_1m`, so it gets Claude Code's 200k default - against `gpt-5.3-codex-spark`'s real 128k. `CLAUDE_CODE_AUTO_COMPACT_WINDOW` is global, so it can't fix one tier without lowering all of them. Keep haiku-tier subagent work short.
- **Deferred tool search runs under claudex, and that's fine - leave `ENABLE_TOOL_SEARCH` unset.** Claude Code disables it for non-first-party hosts (*"Set ENABLE_TOOL_SEARCH=true if your proxy forwards tool_reference blocks"*), but that check is `vn()==="firstParty" && !Nd()`, which the assume-first-party flag defeats - so tool search stays on. Verified working end to end: `/context` reports tools as deferred, and a prompt requiring the deferred `WebFetch` tool caused GPT to load the schema via ToolSearch and complete the fetch. CLIProxyAPI does forward `tool_reference` blocks. Setting `ENABLE_TOOL_SEARCH=false` would switch to `standard` mode and send every schema up front - about 5k extra tokens per session on this loadout, for no gain.
- **Vision works.** Verified: a claudex session read a PNG off disk and returned its contents correctly. Upstream CLIProxyAPI #2931 (Claude URL images not preserved) does not affect local file reads.
- **Cache-write tokens are invisible, so cost readouts are a floor.** CLIProxyAPI's Codex->Claude translator never sets `cache_creation_input_tokens` (the sibling Codex->OpenAI translator does map it), and cache writes bill at 1.25x uncached input. The statusline `wk $` and `ccusage` structurally under-report claudex spend.
- **claude.ai connectors and cloud features don't work under claudex** (Clay/Google connectors, the `schedule` skill): any `ANTHROPIC_AUTH_TOKEN` disables claude.ai-account features. Local MCP servers (stdio/http with keys) work fine.
- **Remote Control cannot work inside a claudex session** - by design, not a bug. Three independent blockers per the official docs (https://code.claude.com/docs/en/remote-control.md): (1) since Claude Code v2.1.196 Remote Control is disabled whenever `ANTHROPIC_BASE_URL` points anywhere other than `api.anthropic.com`; (2) it requires claude.ai subscription OAuth, and `ANTHROPIC_AUTH_TOKEN` takes auth precedence over the OAuth login; (3) Remote Control traffic registers and polls through the Anthropic API itself, so it cannot be split off from proxied model traffic. Plain `claude` sessions are unaffected - the claudex function scopes its env vars and restores them on exit.
- **Slash commands and skills work normally under claudex** (that is the whole point of the known-ID alias). Verified headless: project `.claude/commands` expand and execute, and plugin skills invoke, under the proxy env.
- **Native harness tools work normally under claudex** - the toolset comes from Claude Code, not the model, and the known-ID alias keeps it untrimmed. Verified: Agent/Skill/Read/Write/Grep plus MCP tools all invoke under the proxy env. `AskUserQuestion` is interactive-only: headless `-p` reports "exists but is not enabled in this context" *identically* on stock claude - mode gating, not a claudex limitation.
- **The proxy key is a local-loopback-only self-generated secret**, not a cloud credential. The Codex OAuth credential lives in `~\.cli-proxy-api\` (created by the login flow).
- **Model identity:** inside claudex, `/context` and self-reports say "Opus 4.8" - it is GPT underneath. The alias is a routing disguise, not a lie you should forget.

## Optional: claudex-aware statusline

```powershell
powershell -ExecutionPolicy Bypass -File statusline\install-statusline.ps1
```

Replaces (with backup) your Claude Code statusline with one that renders:

```
Opus 4.8 claudex:GPT-5.6-sol | repo | branch* | [███░░░░░░░] 34% (69k) | A:5h[█████]94% wk[███░░]59% | X:wk[█████]91% spk[█████]98% | th:high | wk $10.04
```

- magenta `claudex:GPT-...` marker whenever the session runs through the proxy (detected via inherited `ANTHROPIC_BASE_URL`) - the model name says Opus/Haiku, the marker tells the truth
- `A:` Anthropic budget LEFT (5h session + week) as 5-cell bars, live from Claude Code's rate-limit feed
- `X:` Codex budget LEFT (week + spark meter) from ChatGPT's usage API, cached 30 min, refreshed in the background via the proxy's OAuth credential
- `th:` thinking/effort level; context bar uses Claude Code's exact window numbers
- `wk $` estimated week spend via `ccusage` (optional; note claudex sessions inflate it at Opus rates - read as Opus-equivalent burn, not invoice)

### Linux statusline

`install.sh` drops a claudex-aware statusline at `~/.cliproxyapi/statusline.sh` but does **not** wire it up. To use it, point `~/.claude/settings.json` at it (back the file up first):

```json
"statusLine": { "type": "command", "command": "/home/you/.cliproxyapi/statusline.sh" }
```

It is a superset of a plain statusline - identical output for normal sessions - and adds a marker naming the real upstream when the session runs through the proxy, resolved by reverse-mapping `model.id` through `cliproxyapi.conf`:

```
Opus 4.8 claudex:gpt-5.6-sol | ~$1.23 | Context: 8% | +5/-2 lines | Wk: 59%
```

The `~$` is deliberate: that figure is a floor, priced at Anthropic rates and missing cache-write tokens the translator drops. Without this marker a claudex session and a real Opus session look identical, which matters once you run both.

## Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File uninstall.ps1
```

Stops the proxy, removes autostart + the profile function. Binaries, config, keys, and OAuth credentials are left in place (paths printed) for manual removal.

## Troubleshooting

Run `doctor.ps1` first - it pinpoints the broken link. Common fixes:

- `502 unknown provider for model claude-opus-4-8` - the alias block is missing from `~\.cliproxyapi\cliproxyapi.conf`; re-run `install.ps1` after removing the conf, or merge `config\cliproxyapi.conf.template`.
- Proxy not running - `claudex` auto-starts it; manually: `~\.cliproxyapi\start-hidden.vbs` or check `tasklist | findstr cli-proxy-api`.
- Login expired - `~\.cliproxyapi\cli-proxy-api.exe -codex-login`.
- Config changed but behavior didn't - restart the proxy: `Get-Process cli-proxy-api | Stop-Process -Force` then run `claudex` (auto-restart).

## Repo layout

```
install.ps1 / install.sh             one-command setup (idempotent) - Windows / Linux
doctor.ps1  / doctor.sh              read-only health check (-Smoke / --smoke for live calls)
uninstall.ps1                        removes autostart + profile fn, keeps credentials
profile/claudex-function.ps1         the claudex function source (installed into your profile)
profile/claudex-function.sh          bash/zsh counterpart - keep the two in sync
config/cliproxyapi.conf.template     proxy config with model aliases (__PROXY_KEY__ injected)
test/test-orchestration.ps1          8-check subagent orchestration regression test
statusline/install-statusline.ps1    optional claudex-aware statusline (usage bars, GPT marker)
statusline/statusline.ps1            the statusline renderer + background usage refreshers
statusline/statusline.sh             bash statusline with the claudex upstream marker
```
