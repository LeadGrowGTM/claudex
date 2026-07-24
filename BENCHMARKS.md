# claudex behavior benchmarks

Historical capability and Agent-availability baseline for GPT inside the Claude Code harness. It does not establish organic delegation or permission-mode parity.

## Method

Six deterministic tasks, each a real headless Claude Code session (`claude -p`), scored from artifacts on disk and session transcript JSONL. No LLM judging anywhere - every check is a file existence, exact string, or transcript `tool_use` pattern. B6 explicitly orders Agent use, so it tests availability and routing rather than model judgment.

Runner: `bench\behavior-bench.ps1`. Work dirs are created outside any workspace so no ancestor CLAUDE.md leaks into runs.

Three configs:

| Config | Env | Model actually answering |
|---|---|---|
| `baseline` | claudex proxy env | gpt-5.6-sol (wildcard maximum effort) via alias `claude-opus-4-8` |
| `steered` | claudex proxy env + `--append-system-prompt bench\steering.md` | same |
| `control` | clean env, subscription auth | real claude-opus-4-8 |

Versions: Claude Code 2.1.212, CLIProxyAPI 7.2.83, upstream `gpt-5.6-sol` / fast tier `gpt-5.3-codex-spark`. Run date: 2026-07-17.

## Tasks

| Id | Behavior probed | Pass condition |
|---|---|---|
| B1 | Parallel tool batching | >=2 Read calls batched in one API message AND correct line-count total |
| B2 | Dedicated tools over shell | Write + Read tools used, zero Bash/PowerShell, file content correct |
| B3 | Exact output contract | artifact written AND final reply is exactly `DONE` (case-sensitive) |
| B4 | CLAUDE.md rule adherence | reply ends with required token, avoids banned word (rules only in workdir CLAUDE.md) |
| B5 | Slash command execution | project `.claude/commands` command expands, `$ARGUMENTS` correct, exact output |
| B6 | Forced Agent availability | Prompt requires Agent; child wrote artifact; main agent did not duplicate child write |

## Results

![claudex behavior benchmark results](bench/results/2026-07-17/benchmark.png)

Reps: baseline and steered n=2 per task, control n=1. B1 rerun after two bench-harness bugfixes (see Notes); other tasks from the full run.

| Task | baseline (GPT) | steered (GPT) | control (Claude) |
|---|---|---|---|
| B1 parallel batching | 2/2 | 2/2 | 1/1 |
| B2 tool choice | 2/2 | 2/2 | 1/1 |
| B3 exact output | 2/2 | 2/2 | 1/1 |
| B4 CLAUDE.md adherence | 2/2 | 2/2 | 1/1 |
| B5 slash commands | 2/2 | 2/2 | 1/1 |
| B6 forced Agent availability | 2/2 | 2/2 | 1/1 |
| **Total** | **12/12** | **12/12** | **6/6** |

### Latency (seconds per run)

| Task | baseline | steered | control |
|---|---|---|---|
| B1 | 15.7, 16.2 | 17.0, 17.3 | 11.9 |
| B2 | 35.2, 145.4 | 18.7, 111.7 | 14.2 |
| B3 | 24.9, 15.0 | 78.4, 14.1 | 13.6 |
| B4 | 10.3, 10.5 | 10.1, 11.0 | 10.7 |
| B5 | 8.0, 8.6 | 9.6, 8.2 | 9.3 |
| B6 | 36.2, 34.2 | 65.0, 108.2 | 18.9 |

## Performance parity suite

`bench\performance-parity.ps1` separates four questions that this historical suite combined or omitted:

1. `routine`: can a local read/edit/test task finish under Claudex policy with zero classifier failures or permission denials?
2. `classifier`: how long does one harmless dedicated-PowerShell action take in explicit auto mode?
3. `organic`: does the model choose Agent for three independent modules when the prompt names only the outcome?
4. `routing`: does unchanged `tool-runner` frontmatter route a child to `claude-haiku-4-5` when the Agent call omits `model`?

It records unique assistant and Agent IDs, parallel Agent calls grouped by assistant message, actual child models, duplicate main/child writes, cache tokens, permission failures, tool-result gaps, and new proxy error metadata. Request bodies are skipped.

Dry mode makes no model calls:

```powershell
powershell -ExecutionPolicy Bypass -File bench\performance-parity.ps1
```

`bench\set-effort-profile.ps1` switches the installed proxy between P0 wildcard maximum effort and P1/P2 passthrough. It refuses unknown payload layouts and backs up only the public effort block plus config hash, not the key-bearing config.

### Live results (2026-07-23, Claude Code 2.1.218)

Matched Claudex vs native runs, `acceptEdits`, main `--effort max`. Each cell is PASS/FAIL with wall-clock and the delegation signal that matters for that scenario. P2 was not run: P1 left no material avoidable latency.

| Scenario | P0 claudex | P0 native | P1 claudex | P1 native |
|---|---|---|---|---|
| routine (1 bug, run test) | PASS 56.5s, 0 denials | PASS 20.7s | PASS 53-59s x3, 0 denials* | PASS 20.6s |
| organic (3 modules) | PASS 239s, delegated (3 parallel subagents) | PASS 40.5s, **inline (0 agents)** | PASS 245/670/407s x3, delegated 3/3 (3 parallel) | PASS 33-36s x3, **inline (0 agents)** |
| routing (tool-runner, no model arg) | PASS 16.8s, child = haiku-4-5 | PASS 21.2s, haiku-4-5 | PASS 16-21s x3, haiku-4-5 x3 | PASS 17.2s, haiku-4-5 |
| classifier (explicit auto) | PASS 15.0s, 0 auto-unavailable | n/a | PASS 10.8s, 0 auto-unavailable | n/a |

\* One P1 routine rep failed on a `node --test "<file>"` permission denial before the allowlist covered that form. After adding the narrow `node --test` rule, two fresh reps passed with zero denials. The organic denials seen mid-run were the model trying `&&`-chained and `foreach`-scriptblock node execution - both intentionally denied broad forms - after which it fell back to allowed single `node file.js` commands and passed. Those denials are the policy working, not a gap.

**Selected profile: P1.** The proxy no longer forces `gpt-5.6-*` to max effort; the launcher passes `--effort max` so the flagship main session still reasons at max, while the safety classifier (Terra) and Spark subagents run at passthrough. This removes the forced-max path that produced the measured ~60s Terra classify -> `context canceled` -> HTTP 500 on routine auto-mode checks. Migration for an existing install: `bench\set-effort-profile.ps1 -Profile P1`, then restart the proxy normally. Recorded config hash change on this host: `70d492eb...` -> `82923406...`.

P1 shows no latency penalty versus P0 on any scenario and a faster classifier (10.8s vs 15.0s), with correctness at 100 percent, `tool-runner` resolving to `claude-haiku-4-5` in 3/3 routing runs, and no new permission bypass. Per plan gate this is the adopted profile.

**Organic delegation, measured not asserted.** Under matched settings Claudex organically delegated the three-module task to three parallel non-`smart-searcher` subagents in 3/3 runs. Native Claude Code did the same task inline in 3/3 runs (zero Agent calls, ~33s). So Claudex does not trail native on organic delegation - it exceeds it. But because native sets a zero-delegation baseline on this fixture, the fixture cannot prove a symmetric "delegates exactly like native" claim; treat that narrower claim as unproven and redesign the fixture (a task native itself chooses to fan out on) before asserting it. The `nonSearcherAgentCallCount` metric excludes the mandatory `smart-searcher` so this evidence is organic implementation delegation, not forced availability.

## Findings

1. **Known-ID alias preserves tested harness capabilities.** Parallel batching, dedicated-tool preference, exact output contracts, CLAUDE.md adherence, slash commands, and forced Agent execution all passed. B6 does not show whether GPT would choose Agent without an order.
2. **Broad steering prompt adds no value in this suite.** Pass rate stayed identical, while multi-step tail latency grew (B6: 65-108s steered vs 34-36s baseline). `bench\steering.md` remains a test artifact and is not wired into Claudex.
3. **Native Claude was faster in this snapshot.** Native won every multi-step latency comparison (B6: 18.9s vs 34s+). This suite did not isolate proxy transit, wildcard maximum reasoning, or permission-classifier cost, so it cannot assign one cause.
4. **GPT had high tail variance** (B2 baseline: 35s vs 145s for identical input). Performance work must use repeated runs and report proxy errors separately.

## Notes: two bench bugs fixed along the way

The first full run showed B1 failing in ALL configs including native Claude - that flagged harness bugs, not model behavior:

- Transcript JSONL splits one API message across multiple lines (one per content block). Grouping tool_use by line instead of `message.id` made parallel calls invisible. Fixed: group by message id.
- Fixture files were written with a trailing newline, making "line count" ambiguous (GPT said 18, Claude said 15, both defensible). Fixed: `-NoNewline` fixtures.

Raw per-run data: `bench\results\2026-07-17\run1-full.json` (pre-fix B1 rows included for transparency) and `run2-b1-fixed.json`.

## Reproduce

```powershell
powershell -ExecutionPolicy Bypass -File bench\behavior-bench.ps1            # full suite
powershell -ExecutionPolicy Bypass -File bench\behavior-bench.ps1 -Only B1  # subset
```

Requires: claudex installed and proxy running, plus a claude.ai subscription login for the control config (`-SkipControl` to skip it).

## Caveats

- Small n (2 reps Claudex configs, 1 control) catches systematic gaps, not rare-event rates.
- B6 forces Agent use. It proves availability only, not organic delegation frequency.
- Permission modes, classifier latency, role-effort passthrough, and custom-agent frontmatter routing were not isolated.
- Six dimensions are short-horizon. Long-session context discipline and compaction recovery are not covered.
- Single-day, single-model-pair snapshot. Rerun after Claude Code, proxy, upstream-model, policy, or effort changes.
