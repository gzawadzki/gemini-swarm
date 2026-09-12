# gemini-swarm

A Claude Code skill for running parallel Gemini CLI / Antigravity CLI (`agy`)
sub-agents through [herdr](https://github.com/herdr). Each task gets its own git
worktree and branch, runs with auto-approve enabled, and passes a two-stage
egress gate — the project's tests, then a cheap-model critique of the diff —
before you read it and decide what lands on your branch. When the Antigravity
quota of your main account is empty, tasks run on a second Antigravity account;
when that one is empty too, they run on `codex`.

## Requirements

- `herdr`, and Claude Code must be started **inside** a herdr pane
  (`HERDR_ENV=1`). The scripts refuse to run otherwise.
- `bash`, `git`, `jq`
- At least one agent binary: `agy` (Antigravity CLI), `gemini` (classic Gemini
  CLI), or `codex` (OpenAI Codex CLI)
- Optional, for the second Antigravity account: PowerShell 7 (`pwsh`) and a
  second Antigravity login, see "Quota: two Antigravity accounts, then codex" below

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
      "kind": "agy",
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

Run `agy models` to see the live model list. Most slugs bake the reasoning effort
into the name, so `gemini-3.1-pro-high` and `gemini-3.1-pro-low` are separate
models. By default the swarm routes tasks to Gemini models (the large, cheap
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
failures never reach the review:

```bash
scripts/verify.sh <task-name>
```

**5. Critique** — the judgement half. A cheap model on the Gemini pool reads the
diff against the task's own prompt and answers what the tests cannot: is this the
change that was asked for. See [Machine critique](#machine-critique):

```bash
scripts/critique.sh <task-name>
```

**6. Review the diff** before merging anything, for tasks the gate cleared:

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

**8. Close the agents** when you are done with them. A finished agy agent does
not exit on its own; it sits in its pane still holding the shared Antigravity
credential, which blocks the next account switch:

```bash
scripts/cleanup.sh                 # close agents that reported a result
scripts/cleanup.sh --worktrees     # and remove a worktree once its branch is merged
```

State lives in `.herdr-swarm/state.json`. Override the location with
`HERDR_SWARM_STATE_DIR`.

## Trace mode

Every script takes `--trace`, before or after its positional arguments:

```bash
scripts/launch.sh --trace tasks.json
```

For a whole session use `HERDR_SWARM_TRACE=1` instead; `--no-trace` on a single
call overrides it. It is off by default, and while off it creates no file and
spawns no subprocess.

Each external call the swarm makes — `herdr`, `agy`, `codex`, `git`, the verify
command — gets one line in `.herdr-swarm/trace.log` with a timestamp, the script
that wrote it, the task, the event, and the command with its exit code:

```
2026-09-09T00:02:31Z critiq  demo    quota.read     agy -p /usage -> rc=0 (80% 42% )
2026-09-09T00:02:31Z critiq  demo    reviewer.pick  agy for model gemini-3.8-flash-high
2026-09-09T00:02:32Z critiq  demo    verdict.parse  revise (1 issues, confidence high)
```

The log always goes to the state dir, never into a worktree — a file written
inside a worktree would turn its CLEAN column `DIRTY` and break the review gate.
It appends; delete it yourself when it gets long. Prompts are recorded as a byte
count only, so the log stays safe to paste.

This is for the failures that look like success: a prompt herdr accepted but the
agent never saw (`prompt.stalled`, `prompt.lost`), a quota read that failed open
(`quota.read`), a base ref that resolved to the branch tip and made the diff look
empty (`base.resolve`, `diff.collect`). `SKILL.md` section 13 lists the full
event vocabulary per script.

## Machine critique

`verify.sh` answers "does it still build". It cannot answer "did the agent do
what it was asked", and that is the question that costs a full diff read. So
`critique.sh` puts a cheap model on it first, one-shot on the Antigravity Gemini
pool, and writes a structured verdict to `.herdr-swarm/<name>.critique.json`.

The reviewer gets the task's original prompt, the diff against its base, and a
fixed rubric: completeness, scope (deleted tests, disabled checks, unrelated
edits), correctness, safety, tests. Style and refactor opinions are out of scope
by instruction, since they produce noise rather than blockers.

| verdict | meaning |
|---------|---------|
| `pass` | no blocker or major issue found — read the diff anyway |
| `revise` | real problems; send the issue list back to the agent |
| `reject` | wrong approach or dangerous; re-prompting will not fix it |
| `skipped` | no diff, or no reviewer binary on PATH |
| `unparseable` / `error` | the reviewer misbehaved; not a verdict either way |

Only `revise` and `reject` exit non-zero, so a broken reviewer never wedges the
pipeline — it falls through to your own read. The verdict shows up in the
CRITIQUE column of `status.sh` and at the top of `review.sh`.

**This advises, it never approves.** A `pass` is one cheap model's opinion of
another model's work, which is weaker evidence than the test run, not stronger.
It narrows what you have to read; it does not replace reading it.

The reviewer is never the model that wrote the diff when that can be avoided: a
task written by the critique model is reviewed by
`HERDR_SWARM_CRITIQUE_ALT_MODEL` instead. The verdict file records
`worker_model` and `independent`; the one unavoidable self-review, a codex
fallback task critiqued by codex, prints a warning and writes
`"independent": false`.

| Variable | Effect |
|----------|--------|
| `HERDR_SWARM_CRITIQUE_MODEL` | Reviewer model, default `gemini-3.8-flash-high`. |
| `HERDR_SWARM_CRITIQUE_ALT_MODEL` | Reviewer for tasks the critique model wrote itself, default `gemini-3.1-pro-high`. |
| `HERDR_SWARM_CRITIQUE_KIND` | Force `agy`, `codex` or `gemini` instead of auto-picking. |
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
| `HERDR_SWARM_TRIM_KIND` | Force `agy`, `codex` or `gemini`. |
| `HERDR_SWARM_TRIM_TIMEOUT` | Seconds before it is killed, default the critique timeout. |

## Quota: two Antigravity accounts, then codex

Antigravity meters two quota pools separately, **Gemini Models** for `gemini-*`
slugs and **Claude and GPT models** for `claude-*` and `gpt-*` slugs, each with a
weekly and a five-hour window. An agent started against an empty pool cannot make
a single call, and in herdr it looks identical to an agent still thinking.

So `launch.sh` reads `agy -p "/usage"` before it starts anything. If the pool a
task's model draws from reads 0% in either window, the swarm switches the live
Antigravity account and runs the task on the other subscription. If that one is
empty too, or there is no second account, the task runs on `codex` with
`gpt-5.6-luna` at `max` reasoning effort instead. Other tasks are unaffected,
so a Claude task keeps running on the live account after the Gemini pool empties.
If the quota cannot be read, the task stays on the live account and the script
warns rather than guessing.

`status.sh` marks a task on the second account with `@B` and a codex fallback
task with `*` after the agent name; `review.sh` prints which account or model
actually did the work.

| Variable | Effect |
|----------|--------|
| `HERDR_SWARM_NO_FALLBACK=1` | Never fall back to codex; when no account has quota the task is not launched and the script reports when each account refills. |
| `HERDR_SWARM_CODEX_MODEL` | Model the fallback runs, default `gpt-5.6-luna`. |
| `HERDR_SWARM_CODEX_EFFORT` | Reasoning effort, default `max`. |
| `HERDR_SWARM_CODEX_PLUGINS=1` | Keep codex plugins on. By default every swarm codex runs with `--disable plugins`, so plugins like caveman cannot rewrite how a worker or reviewer writes. `~/.codex/AGENTS.md` still loads. |

Only the live account's quota can be read, because `/usage` answers for whoever
`agy` is signed in as. The other account is therefore consulted only after the
live one has actually run dry.

On Windows, run `/usage` by hand as `MSYS_NO_PATHCONV=1 agy -p "/usage"`. Without
that variable, Git Bash rewrites the leading slash into a file path and agy
answers with prose instead of numbers.

### Setting up the second account

`agy` has no `--profile` or `--account` flag. Its OAuth token lives in Windows
Credential Manager under one fixed target, `gemini:antigravity`, per Windows
user. `scripts/agy-account.ps1` therefore keeps a *vault*: one extra credential
entry per account, and it copies the wanted one into the live target before an
agent starts. Both accounts then run as you, in an ordinary herdr pane with a
real TUI; nothing about the launch differs between them.

One-time setup, from your own profile, in a terminal:

```powershell
agy                       # /logout, then /login as the second subscription
pwsh -NoProfile -File scripts/agy-account.ps1 -Mode save -Account b
agy                       # /logout, then /login as your main subscription
pwsh -NoProfile -File scripts/agy-account.ps1 -Mode save -Account a
pwsh -NoProfile -File scripts/agy-account.ps1 -Mode list
```

`list` prints, per entry, a truncated SHA-256 of the blob plus its size and
write time. That is enough to see that the two accounts are actually different;
the script never prints a credential. If the vault is empty, or `pwsh` is not
installed, there is simply no second account and the swarm goes straight to the
codex fallback when the live one empties.

### Why accounts cannot be mixed

`agy` refreshes its OAuth token during a session and writes the new one back to
the live target. Measured on this machine: with twelve sessions running, the
entry was rewritten twice inside thirty seconds. Two things follow.

A running agent would clobber a credential swapped in underneath it, and would
itself continue on the swapped-in account. So a switch is refused while any `agy`
process is alive: `launch.sh` starts nothing and tells you to wait for the
running agents to finish. (`agy-account.ps1 -Mode use -Force` overrides this;
the swarm never passes it.)

A vault entry goes stale as soon as its account has done work, so `use` first
copies the live credential back over the outgoing account's own vault entry.
Which account is live is tracked in `%LOCALAPPDATA%\herdr-swarm\live-account`,
because after a refresh the blob no longer matches anything in the vault and the
hash cannot answer the question.

| Variable | Effect |
|----------|--------|
| `HERDR_SWARM_NO_SWITCHING=1` | Never switch accounts; go to codex (or stop, with `HERDR_SWARM_NO_FALLBACK=1`) when the live one is empty. |

## Safety

Agents run with `--yolo`, `--dangerously-skip-permissions` or
`--dangerously-bypass-approvals-and-sandbox`, so every confirmation is disabled.
Worktree isolation keeps them off your checked-out files, but only point them at
repos you are fine with an agent editing unattended, and never merge a branch you
have not read the diff for — a verify pass and a critique pass are filters, not
approvals. See the "Safety notes" section of `SKILL.md` for the full list.
