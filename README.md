# gemini-swarm

A Claude Code skill for running parallel Gemini CLI / Antigravity CLI (`agy`)
sub-agents through [herdr](https://github.com/herdr). Each task gets its own git
worktree and branch, runs with auto-approve enabled, and passes a two-stage
egress gate — the project's tests, then a cheap-model critique of the diff —
before you read it and decide what lands on your branch. When the Antigravity
quota is empty, tasks run on `codex` instead.

## Requirements

- `herdr`, and Claude Code must be started **inside** a herdr pane
  (`HERDR_ENV=1`). The scripts refuse to run otherwise.
- `bash`, `git`, `jq`
- At least one agent binary: `agy` (Antigravity CLI), `gemini` (classic Gemini
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
      "kind": "agy",
      "model": "gemini-3.1-pro-high",
      "repo": "/absolute/path/to/repo",
      "branch": "agent/fix-auth-bug",
      "prompt": "Fix the failing test in tests/test_auth.py, then run pytest and report the result.",
      "args": [],
      "verify": "pytest -q tests/test_auth.py",
      "timeout_ms": 900000
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

Write the `prompt` specifically enough to be checkable. Step 5 grades the diff
against it, so a reviewer can measure "add a retry with backoff to the S3 upload
in storage.py and cover it with a test" but not "improve error handling".

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

**7. Read an agent's output** when something looks wrong:

```bash
scripts/logs.sh <task-name> [lines]
```

State lives in `.herdr-swarm/state.json`. Override the location with
`HERDR_SWARM_STATE_DIR`.

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

| Variable | Effect |
|----------|--------|
| `HERDR_SWARM_CRITIQUE_MODEL` | Reviewer model, default `gemini-3.7-flash-high`. |
| `HERDR_SWARM_CRITIQUE_KIND` | Force `agy`, `codex` or `gemini` instead of auto-picking. |
| `HERDR_SWARM_CRITIQUE_EFFORT` | Reasoning effort for the codex path, default `medium`. |
| `HERDR_SWARM_CRITIQUE_TIMEOUT` | Seconds before the reviewer is killed, default `600`. |
| `HERDR_SWARM_CRITIQUE_DIFF_LINES` | Diff lines pasted into the brief, default `1500`. Past this the brief is truncated and the reviewer is told to read the repo itself. |

## The codex fallback

Antigravity meters two quota pools separately, **Gemini Models** for `gemini-*`
slugs and **Claude and GPT models** for `claude-*` and `gpt-*` slugs, each with a
weekly and a five-hour window. An agent started against an empty pool cannot make
a single call, and in herdr it looks identical to an agent still thinking.

So `launch.sh` reads `agy -p "/usage"` before it starts anything. If the pool a
task's model draws from reads 0% in either window, that task runs on `codex` with
`gpt-5.6-luna` at `xhigh` reasoning effort instead. Other tasks are unaffected,
so a Claude task keeps running on agy after the Gemini pool empties. If the quota
cannot be read, the task stays on agy and the script warns rather than guessing.

`status.sh` marks a fallback task with a `*` after the agent name, and
`review.sh` prints which model actually did the work.

| Variable | Effect |
|----------|--------|
| `HERDR_SWARM_NO_FALLBACK=1` | Skip the quota check and keep every task on agy. |
| `HERDR_SWARM_CODEX_MODEL` | Model the fallback runs, default `gpt-5.6-luna`. |
| `HERDR_SWARM_CODEX_EFFORT` | Reasoning effort, default `xhigh`. |

On Windows, run `/usage` by hand as `MSYS_NO_PATHCONV=1 agy -p "/usage"`. Without
that variable, Git Bash rewrites the leading slash into a file path and agy
answers with prose instead of numbers.

## Safety

Agents run with `--yolo`, `--dangerously-skip-permissions` or
`--dangerously-bypass-approvals-and-sandbox`, so every confirmation is disabled.
Worktree isolation keeps them off your checked-out files, but only point them at
repos you are fine with an agent editing unattended, and never merge a branch you
have not read the diff for — a verify pass and a critique pass are filters, not
approvals. See the "Safety notes" section of `SKILL.md` for the full list.
