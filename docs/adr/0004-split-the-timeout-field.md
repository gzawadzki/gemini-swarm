# ADR 0004: `timeout_ms` splits into `ready_timeout_ms` and `work_budget_ms`

**Date:** 2026-09-12
**Status:** accepted

## Context

One field, two jobs. SKILL.md described `timeout_ms` as "how long `launch.sh` waits
for the agent process to become ready" with a default of 30000 — which matches
herdr, where `agent start --timeout <MS>` means "wait for interactive readiness
(default: 30000; max: 300000)".

Every example in `tasks.example.json` used it as the task's time budget instead:
900000, 1200000, 1800000. All four were above herdr's ceiling, so the sample config
could not launch; herdr answers `invalid_agent_timeout`. Observed on a real run at
23:19:38, where the first launch died on exactly this and left a branch behind that
blocked the retry.

A clamp had been added once, in `99fcb6b`, and was dropped again in `b21ac68` while
`launch.sh` was rewritten for the codex fallback. No test caught it: the launch test
asserted only that stdout contained "sending prompt", which it prints whether or not
the prompt arrives.

There was also no budget concept at all, so an agent stuck in a loop and an agent
thinking hard looked identical from the outside, indefinitely.

## Decision

Two fields:

- `ready_timeout_ms` — TUI readiness, default 60000, clamped to herdr's 300000 with
  a warning. The old name still parses and warns, naming the field the writer
  probably meant.
- `work_budget_ms` — expected task duration, default 900000. **Enforced by nothing.**
  `status.sh` prints `OVERDUE` once a task passes it without a result file.

No hard kill on the budget: it would cut a task three minutes from done. A task
needing a budget far past 15 minutes is a task to split (ADR 0002), not a number to
raise.

Both are covered by tests that assert on the arguments the fake herdr actually
received, not on stdout wording — the specific reason the earlier fix could vanish
unnoticed.

Primary source: local working notes, `.scratch/swarm-rebuild-findings.md` §2. Untracked on purpose: they quote a private repository and this one is public.
