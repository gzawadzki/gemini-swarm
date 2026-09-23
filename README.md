# gemini-swarm

A Claude Code skill for running parallel Pi agents with `pi-antigravity` through
[herdr](https://github.com/herdr). Each task gets its own git
worktree and branch, runs with auto-approve enabled, and passes a two-stage
egress gate — the project's tests, then a typed Jev risk check or a generative
critique — before you decide what lands on your branch. Pi manages linked
Antigravity accounts and retries another account on a hard quota failure.

## Requirements

- `herdr`, and Claude Code must be started **inside** a herdr pane
  (`HERDR_ENV=1`). The scripts refuse to run otherwise.
- `bash`, `git`, `jq`
- Optional for automatic acceptance: `curl` and either `TYPESAFE_API_KEY` or
  `OPENROUTER_API_KEY`
- At least one agent binary: `pi` with `pi-antigravity`, `gemini` (classic Gemini
  CLI), or `codex` (OpenAI Codex CLI)

## Install

Clone the repo into your Claude Code skills directory:

```bash
git clone https://github.com/gzawadzki/gemini-swarm.git ~/.claude/skills/gemini-swarm
chmod +x ~/.claude/skills/gemini-swarm/scripts/*.sh
```

Restart Claude Code. The skill is picked up from `SKILL.md`. Ask for it by name
(`gemini-swarm`) or say "spin up a swarm of Gemini sub-agents".

## Use

Normally you do not run anything by hand. You describe the tasks and Claude
writes the config and drives the scripts. To do it manually:

**1. Write a `tasks.json`.** Copy `tasks.example.json` and edit:

```json
{
  "tasks": [
    {
      "name": "fix-auth-bug",
      "kind": "pi",
      "model": "gemini-3.8-flash-high",
      "repo": "/absolute/path/to/repo",
      "branch": "agent/fix-auth-bug",
      "prompt": "Fix the failing test in tests/test_auth.py, then run pytest and report the result.",
      "files": ["src/auth/tokens.py", "tests/test_auth.py"],
      "pitfalls": [
        "The test fails on an expired fixture token, not on the verification logic; regenerating the fixture is the fix, widening the leeway window is not."
      ],
      "args": [],
      "verify": "pytest -q tests/test_auth.py",
      "work_budget_ms": 900000
    }
  ]
}
```

Run `/antigravity.models` in Pi to see the live model list. The task config may
use `gemini-3.1-pro-high`, which launches as `gemini-3.1-pro` with high thinking.
By default the swarm routes tasks to Gemini models (the large, cheap
Antigravity pool) and reserves `claude-*`/`gpt-*` slugs for when you name them
explicitly — the idea is that Claude does the orchestration and review while the
swarm does volume.

The optional `verify` field is a shell command run inside the worktree as an
egress gate before the diff is reviewed (see step 4). Omit it and the tooling
auto-detects one from the project (`npm`/`yarn`/`pnpm test`, `pytest`,
`cargo test`, `go test`, a `test:` Make target).

`files` and `pitfalls` are required, and `launch.sh` skips a task that leaves
out either one. `files` is what the task is expected to touch; `pitfalls` is what you
found by reading that code before writing the task — the caller you would not
expect, the fixture that freezes the clock. They reach the agent as constraints
it must satisfy without restating them in the source. An empty `pitfalls` array
is accepted with a warning, so "I read it and found none" stays expressible.

Write the `prompt` specifically enough to be checkable. Step 5 grades the diff
against it, so a reviewer can measure "add a retry with backoff to the S3 upload
in storage.py and cover it with a test" but not "improve error handling".

Before writing the config, apply the [worker gate](docs/reference/models-and-routing.md#worker-gate):
send a bounded implementation with one decisive check to Pi Antigravity; use
`kind: "codex"`, `model: "gpt-6-luna"`, `effort: "xhigh"` when a scoped task
needs one agent to resolve competing causes or preserve a contract across
modules. Both routes get a worktree and the same review gate.

[docs/reference/task-definition.md](docs/reference/task-definition.md) covers the
whole schema, the test for whether a unit of work is small enough to hand over at
all, and the rules for writing a prompt.

**2. Launch.** This creates a worktree and branch per task and starts the agents
in parallel:

```bash
scripts/launch.sh tasks.json
```

**3. Check status.** A task is review-ready only when herdr says `idle` or
`done`, its result file says `success`, **and** its worktree is clean:

```bash
scripts/status.sh
```

**4. Verify** — the deterministic half of the egress gate. It runs the task's
`verify` command (or an auto-detected one) inside the worktree, so mechanical
failures never reach the review. A green command is not the whole answer: it then
establishes that the code under test resolved inside the worktree, because an
editable install can pin imports to the main checkout and pass on a diff it never
touched. Resolved elsewhere is a `fail`; undeterminable is `skipped`, never a
`pass`. `HERDR_SWARM_NO_SOUNDNESS=1` turns the check off, visibly:

```bash
scripts/verify.sh <task-name>
```

**5. Critique** — the judgement half. Jev first evaluates typed risk signals for
a verified, clean, in-scope diff. It automatically accepts only when every risk
is at or below the configured threshold; otherwise a generative reviewer reads
the diff. See [Machine critique](#machine-critique):

```bash
scripts/critique.sh <task-name>
```

**6. Review the handoff** before merging anything. `review.sh` says whether Jev
automatically accepted the change or a human diff read is still required:

```bash
scripts/review.sh <task-name>
```

Optionally, once you have read it and it looks bigger than the task needed, ask a
cheap model where it is overbuilt. This only suggests cuts; it never blocks and
never judges correctness. See [Trim review](#trim-review):

```bash
scripts/trim.sh <task-name>
```

**7. Read an agent's output** when something looks wrong:

```bash
scripts/logs.sh <task-name> [lines]
```

**8. Close the agents** when you are done with them. A finished Pi agent stays
in its pane until cleanup closes it:

```bash
scripts/cleanup.sh                 # close agents that reported a result
scripts/cleanup.sh --worktrees     # and remove a worktree once its branch is merged
```

Before it closes anything, cleanup archives the run to
`~/.herdr/runs/<launch-timestamp>/` and prints the path: the task config as
launched, the state file, the trace, a status snapshot, and per task the diff and
both gate verdicts. That happens first because everything after it is
destructive, and a pane that will not close must not cost the record. A run
cleaned up twice keeps the first archive. `HERDR_SWARM_RUN_DIR` moves the root.

State lives in `.herdr-swarm/state.json`. Override the location with
`HERDR_SWARM_STATE_DIR`.

## Documentation

`SKILL.md` is what Claude loads: the operating model and the numbered flow, with
a pointer from each step to the reference it needs. The references are:

| document | what is in it |
|----------|---------------|
| [defining a task](docs/reference/task-definition.md) | the slice test, every schema field, and the rules for writing a prompt |
| [models and routing](docs/reference/models-and-routing.md) | the three agent kinds, the model menu, and which slug a task should get |
| [accounts and quota](docs/reference/accounts-and-quota.md) | Pi's account and quota commands |
| [the egress gate](docs/reference/the-gate.md) | verify, soundness, critique, scope and size, and the optional trim review |
| [cleanup and the run archive](docs/reference/cleanup-and-archive.md) | what gets closed, what gets removed, and what the archive keeps |
| [troubleshooting](docs/reference/troubleshooting.md) | trace mode, and every trap this project has actually hit |

[CONTEXT.md](CONTEXT.md) defines the vocabulary; `docs/adr/` records the
decisions and why they were made.

## Trace mode

Every script takes `--trace`, before or after its positional arguments:

```bash
scripts/launch.sh --trace tasks.json
```

For a whole session use `HERDR_SWARM_TRACE=1` instead; `--no-trace` on a single
call overrides it. It is off by default, and while off it creates no file and
spawns no subprocess.

Each external call the swarm makes — `herdr`, `pi`, `codex`, `git`, the verify
command — gets one line in `.herdr-swarm/trace.log` with a timestamp, the script
that wrote it, the task, the event, and the command with its exit code:

```
2026-09-09T00:02:31Z critiq  demo    reviewer.pick  pi for model gemini-3.8-flash-high
2026-09-09T00:02:32Z critiq  demo    verdict.parse  revise (1 issues, confidence high)
```

The log always goes to the state dir, never into a worktree — a file written
inside a worktree would turn its CLEAN column `DIRTY` and break the review gate.
It appends; delete it yourself when it gets long. Prompts are recorded as a byte
count only, so the log stays safe to paste.

This is for the failures that look like success: a prompt herdr accepted but the
agent never saw (`prompt.stalled`, `prompt.lost`), a base ref that resolved to the branch tip and made the diff look
empty (`base.resolve`, `diff.collect`). The
[troubleshooting reference](docs/reference/troubleshooting.md) lists the full
event vocabulary per script.

## Machine critique

`verify.sh` answers "does it still build". It cannot answer "did the agent do
what it was asked", and that is the question that costs a full diff read.
`critique.sh` first asks Jev a fixed set of typed yes/no risk questions and writes
a structured verdict to `.herdr-swarm/<name>.critique.json`.

Jev can automatically accept only a verified, clean, untruncated diff with no
strays, oversize report, or protected paths. Every risk probability — missing
requirements, correctness, unrelated behavior, security, weakened checks,
missing regression tests, and declared pitfalls — must be at or below `0.10` by
default. Anything uncertain, unavailable, or above threshold falls through to
the existing generative reviewer. It never auto-merges.

The reviewer gets the task's original prompt, the diff against its base, and a
fixed rubric: completeness, scope (deleted tests, disabled checks, unrelated
edits), correctness, safety, tests. Style and refactor opinions are out of scope
by instruction, since they produce noise rather than blockers.

| verdict | meaning |
|---------|---------|
| `pass` with `auto_accepted: true` | Jev cleared every risk signal — ready for the merge handoff |
| ordinary `pass` | no blocker or major issue found — read the diff |
| `revise` | real problems; send the issue list back to the agent |
| `reject` | wrong approach or dangerous; re-prompting will not fix it |
| `skipped` | no diff, or no reviewer binary on PATH |
| `unparseable` / `error` | the reviewer misbehaved; not a verdict either way |

Only `revise` and `reject` exit non-zero, so a broken reviewer never wedges the
pipeline — it falls through to your own read. The verdict shows up in the
CRITIQUE column of `status.sh` and at the top of `review.sh`.

Only Jev's bounded `auto_accepted: true` path approves without a full diff read.
An ordinary generative `pass` remains advice and still requires the read.

The reviewer is never the model that wrote the diff when that can be avoided: a
task written by the critique model is reviewed by
`HERDR_SWARM_CRITIQUE_ALT_MODEL` instead. The verdict file records
`worker_model` and `independent`; the one unavoidable self-review, a codex
codex task critiqued by the same codex model, prints a warning and writes
`"independent": false`.

| Variable | Effect |
|----------|--------|
| `TYPESAFE_API_KEY` / `OPENROUTER_API_KEY` | Enables Jev; TypeSafe wins when both are set. |
| `HERDR_SWARM_JEV_AUTO_ACCEPT` | Set to `0` to disable automatic acceptance; default `1`. |
| `HERDR_SWARM_JEV_ACCEPT_MAX` | Maximum allowed probability for every risk signal; default `0.10`. |
| `HERDR_SWARM_JEV_MODEL` | Override the route's default Jev model. |
| `HERDR_SWARM_JEV_TIMEOUT` | Request timeout in seconds; default `60`. |
| `HERDR_SWARM_CRITIQUE_MODEL` | Reviewer model, default `gemini-3.8-flash-high`. |
| `HERDR_SWARM_CRITIQUE_ALT_MODEL` | Reviewer for tasks the critique model wrote itself, default `gemini-3.1-pro-high`. |
| `HERDR_SWARM_CRITIQUE_KIND` | Force `pi`, `codex` or `gemini` instead of auto-picking. |
| `HERDR_SWARM_CRITIQUE_EFFORT` | Reasoning effort for the codex path, default `medium`. |
| `HERDR_SWARM_CRITIQUE_TIMEOUT` | Seconds before the reviewer is killed, default `600`. |
| `HERDR_SWARM_CRITIQUE_DIFF_LINES` | Diff lines pasted into the brief, default `1500`. Past this the brief is truncated and the reviewer is told to read the repo itself. |

## Trim review

`trim.sh` is an optional pass after your own read, for diffs that look bigger
than the task. A cheap model reads the diff for overengineering only —
single-use abstractions, unused options, needless generalisation, re-implemented
helpers, dead code — and writes suggested cuts to `.herdr-swarm/<name>.trim.json`,
which `review.sh` then lists.

It always exits 0, never judges correctness or safety, never edits the worktree,
and is told to leave input validation, I/O error handling and tests alone. It is
not part of the gate on purpose: YAGNI applied to every task makes agents cut
corners that matter. Correctness first, trimming second, commit last.

| Variable | Effect |
|----------|--------|
| `HERDR_SWARM_TRIM_MODEL` | Model for the trim pass, default the critique model. |
| `HERDR_SWARM_TRIM_KIND` | Force `pi`, `codex` or `gemini`. |
| `HERDR_SWARM_TRIM_TIMEOUT` | Seconds before it is killed, default the critique timeout. |

## Antigravity through Pi

Install Pi and its Antigravity provider, then sign in from Pi:

```bash
pi install npm:pi-antigravity
pi
# In the Pi TUI: /login antigravity
```

Use `/antigravity.models` to inspect available models and `/antigravity.usage`
to see quota and reset times. Add another subscription with `/login antigravity`
again, then inspect or change the active account with `/antigravity.accounts`.
The provider retries the next linked account after a hard quota failure. The
swarm does not read or swap credentials; if every linked account is exhausted,
Pi reports the failure in its pane. Check `scripts/logs.sh <task-name>` and
`scripts/status.sh` for that task. Use `/antigravity.doctor` in Pi for sanitized
diagnostics.

Tasks use `kind: "pi"`. `launch.sh` selects `--provider antigravity` and converts
legacy runtime slugs such as `gemini-3.8-flash-high` into Pi's public model
`gemini-3.8-flash` plus `--thinking high`. New task configs may use the public
model and set `effort` to the thinking level. `kind: "agy"` is rejected with a
migration message.

## Safety

Pi's tools run unattended. Gemini uses `--yolo`, and Codex uses
`--dangerously-bypass-approvals-and-sandbox`.
Worktree isolation keeps them off your checked-out files, but only point them at
repos you are fine with an agent editing unattended, and never merge a branch you
have not read the diff for — a verify pass and a critique pass are filters, not
approvals. See the "Safety notes" section of `SKILL.md` for the full list.
