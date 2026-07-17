# claudex behavior benchmarks

Does GPT inside the Claude Code harness behave like a native Claude model? Measured, not vibes.

## Method

Six deterministic tasks, each a real headless Claude Code session (`claude -p`), scored from artifacts on disk and the session transcript JSONL. No LLM judging anywhere - every check is a file existence, exact string, or transcript tool_use pattern.

Runner: `bench\behavior-bench.ps1`. Work dirs are created outside any workspace so no ancestor CLAUDE.md leaks into runs.

Three configs:

| Config | Env | Model actually answering |
|---|---|---|
| `baseline` | claudex proxy env | gpt-5.6-sol (reasoning high) via alias `claude-opus-4-8` |
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
| B6 | Subagent delegation | Agent tool spawned, subagent wrote the artifact, main agent did NOT write it itself |

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
| B6 subagent delegation | 2/2 | 2/2 | 1/1 |
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

## Findings

1. **GPT-under-claudex already behaves native on every measured dimension.** Parallel batching, dedicated-tool preference, exact output contracts, CLAUDE.md adherence, slash commands, subagent delegation - all clean at baseline. The known-ID alias (untrimmed harness) is doing the heavy lifting; the harness prompt itself steers the model.
2. **Steering prompt adds nothing here - not wired into claudex.** Identical pass rate, and it inflates tail latency on multi-step tasks (B6: 65-108s steered vs 34-36s baseline; extra self-verification turns). `bench\steering.md` stays in the repo for future regressions but is deliberately NOT part of the claudex function.
3. **Native Claude is consistently faster.** Control wins latency on every multi-step task (B6: 18.9s vs 34s+). Expected: forced high reasoning effort on the GPT upstream plus a proxy hop. The gap is speed, not capability.
4. **GPT shows longer tail latency variance** (B2 baseline: 35s vs 145s for identical input). Budget for it in automation.

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

- Small n (2 reps claudex configs, 1 control) - this catches systematic behavior gaps, not rare-event rates.
- Six dimensions, all short-horizon. Long-session behavior (context discipline over hours, compaction recovery) is not covered.
- Single day, single model-pair snapshot. Rerun after Claude Code updates, proxy upgrades, or upstream model changes - same trigger list as `test\test-orchestration.ps1`.
