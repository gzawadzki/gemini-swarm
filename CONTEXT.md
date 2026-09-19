# gemini-swarm — domain model

The vocabulary this skill's docs, scripts and task configs all use. One word, one
job: where a word was doing two jobs, the split is recorded here and in an ADR.

## The work

**Task** — one unit of work handed to one agent, on its own worktree and branch.
A task is the thing `tasks.json` describes and `launch.sh` starts. It is not a
ticket, not an issue, and not a feature: those are upstream of it and may each
produce several tasks.

**Slice** — a task shaped so one agent can finish it: roughly 15 minutes of agent
time, a named list of files, one `verify` command, and the traps already found.
"Slice" is the standard a task has to meet; a unit of work that cannot be
described this way is not a slice, and stays with the orchestrator.

**Pitfall** — a trap in the existing code that the orchestrator found *before*
writing the task, and stated in the brief so the agent does not have to discover
it. Pitfalls are the difference between a task that lands first time and one that
bounces off the gate. They are constraints to satisfy, never text to restate in
code comments.

**Brief** — the file the agent actually reads (`~/.herdr/briefs/<name>.md`): the
task prompt plus the ground rules and the result-file contract. The agent gets a
one-line pointer to it, because `herdr agent prompt` only reliably delivers one
short line.

**Recon** — reading the code that a task will touch, before writing the task.
Done by the orchestrator in its own session, not delegated. The cause of badly
defined tasks was skipping this step.

## The clocks

**`ready_timeout_ms`** — how long herdr waits for an agent's TUI to accept input.
Capped by herdr at 300000; above that the launch fails with
`invalid_agent_timeout`.

**`work_budget_ms`** — how long a task is expected to take. Nothing enforces it;
`status.sh` prints `OVERDUE` past it. See [ADR 0004](docs/adr/0004-split-the-timeout-field.md).

## The gate

**Egress gate** — the two stages a diff passes before the merge handoff:
`verify.sh` (deterministic: do the tests run, on this worktree's code) then
`critique.sh` (Jev typed risk signals, with a generative reviewer as fallback).
Jev alone may **approve** a verified, clean, bounded diff without a full read.
That approval never means auto-merge; the user still decides what lands.

**Stray** — a file a task's diff touched that no entry in its declared `files`
covers. Reported by `status.sh` and `review.sh`; any stray blocks Jev automatic
acceptance but does not fail the generative review, because a new test file or a
package import can be legitimate. Not to be confused with [drift](#the-plumbing), which is about
the skill diverging from this repo.

**Soundness** — whether the code a verify command exercised resolved inside the
task's own worktree. `sound` was established, `unsound` resolved somewhere else,
`unknown` could not be established at all, `disabled` means the check was turned
off with `HERDR_SWARM_NO_SOUNDNESS=1`, and `not checked` means nothing asked.
Only `sound` may render as a `pass`: the check exists because an editable install
can pin imports to another checkout, and a gate that reports green for code it
never ran is worse than no gate. See [ADR 0002](docs/adr/0002-required-files-and-pitfalls.md)
for the sibling rule about recon, and
[the gate reference](docs/reference/the-gate.md) for the mechanism.

**Run** — one `launch.sh` invocation and everything it produced: the task config,
the traces, the briefs, the results and the diffs. Archived under
`~/.herdr/runs/<timestamp>/`, because `cleanup.sh` used to delete the evidence a
post-mortem needs.

## The plumbing

**Account** — one of two Antigravity subscriptions, selected by swapping the
credential `agy` reads at start-up. Marked `@B` in `status.sh` when a task ran on
the second one; `*` means it fell back to codex because both were empty.

**Pool** — a metered Antigravity quota bucket. "Gemini Models" is the large one
the swarm is supposed to spend; "Claude and GPT models" is the scarce one.

**Drift** — the installed skill diverging from this repo. Structurally impossible
now: the installed path is a junction to this working tree. See
[ADR 0001](docs/adr/0001-junction-not-installer.md).
