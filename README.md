# claudex

Run OpenAI GPT models inside Claude Code on your ChatGPT/Codex subscription - with the FULL Claude Code harness: complete system prompt, tool schemas, skill descriptions, subagent orchestration, hooks, rules, and memory.

```
claudex                    # interactive GPT-5.6 Sol session in Claude Code
claudex -Yolo              # same, with --dangerously-skip-permissions
claudex -p "do the thing"  # headless one-shot
```

## Why this exists (the model-ID trim problem)

Pointing Claude Code at a non-Anthropic model via `ANTHROPIC_BASE_URL` mostly works - but Claude Code silently degrades the harness for any model ID it does not recognize (exact internal-registry match; a `claude-` prefix is NOT enough):

| Payload section | unknown ID (`gpt-5.6-sol`) | recognized ID (`claude-opus-4-8`) |
|---|---|---|
| System prompt | minimal stub, no communication/memory guidance | full |
| Core tool schemas | compact | full per-model variant |
| Skill listing | bare names, ALL descriptions stripped | full descriptions |
| MCP servers | silently dropped | loaded |

Stripped skill descriptions are the killer: the model cannot know when to invoke any skill. Verified empirically by capturing request payloads at the proxy (same auth, same endpoint, only the model ID varied).

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

## Health check

```powershell
powershell -ExecutionPolicy Bypass -File doctor.ps1          # read-only chain check
powershell -ExecutionPolicy Bypass -File doctor.ps1 -Smoke   # + live calls through both tiers
```

Checks every link: PowerShell version, claude CLI, binary, key, config (both aliases present, debug logging off), proxy process, port 8317 ownership, live `/v1/models` listing both aliases, Codex credential, profile function. Exits nonzero on any failure - first thing to run when claudex misbehaves.

## Test the harness

```powershell
powershell -ExecutionPolicy Bypass -File test\test-orchestration.ps1
```

Spawns a headless claudex run that must orchestrate 3 parallel fresh subagents (no fork-type), two on the flagship tier and one on the fast tier, each proving execution by writing artifacts checked against known ground truth - plus transcript checks (Agent tool calls, zero forks, subagent transcript files, haiku-alias usage). 8 checks, exits nonzero on failure. Run it after any Claude Code update, proxy upgrade, or config change.

## Behavior benchmarks

Does GPT-under-claudex behave like native Claude in the harness? Measured across six deterministic dimensions (parallel tool batching, dedicated-tool choice, exact output contracts, CLAUDE.md adherence, slash commands, subagent delegation): **12/12 at baseline, matching native Claude's 6/6**. A steering system prompt added zero pass-rate gain and was left out of the claudex function. Native Claude remains faster on multi-step tasks. Full method, results, and latency tables: `BENCHMARKS.md`. Rerun with `bench\behavior-bench.ps1`.

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
- **`claude-opus-4-8` over `claude-sonnet-5` as the alias:** sonnet-5 maps to a ~1M-token window in Claude Code's registry, so auto-compaction would never fire before the upstream's real window overflows. opus-4-8's 200k registry window is safe.
- **Context ceiling is 200k** (Claude Code's window for the aliased ID). No override mechanism exists in the CLI today.
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
install.ps1                          one-command setup (idempotent)
doctor.ps1                           read-only health check (-Smoke for live calls)
uninstall.ps1                        removes autostart + profile fn, keeps credentials
profile/claudex-function.ps1         the claudex function source (installed into your profile)
config/cliproxyapi.conf.template     proxy config with model aliases (__PROXY_KEY__ injected)
test/test-orchestration.ps1          8-check subagent orchestration regression test
statusline/install-statusline.ps1    optional claudex-aware statusline (usage bars, GPT marker)
statusline/statusline.ps1            the statusline renderer + background usage refreshers
```
