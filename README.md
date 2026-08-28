# gemini-swarm

A Claude Code skill for running parallel Gemini CLI / Antigravity CLI (`agy`)
sub-agents through [herdr](https://github.com/herdr). Each task gets its own git
worktree and branch, runs with auto-approve enabled, and is reviewed before
anything lands on your branch. When the Antigravity quota is empty, tasks run on
`codex` instead.

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
      "timeout_ms": 900000
    }
  ]
}
```

Run `agy models` to see the live model list. Most slugs bake the reasoning effort
into the name, so `gemini-3.1-pro-high` and `gemini-3.1-pro-low` are separate
models.

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

**4. Review the diff** before merging anything:

```bash
scripts/review.sh <task-name>
```

**5. Read an agent's output** when something looks wrong:

```bash
scripts/logs.sh <task-name> [lines]
```

State lives in `.herdr-swarm/state.json`. Override the location with
`HERDR_SWARM_STATE_DIR`.

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
have not read the diff for. See the "Safety notes" section of `SKILL.md` for the
full list.
