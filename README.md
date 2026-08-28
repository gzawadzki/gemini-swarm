# gemini-swarm

A Claude Code skill for running parallel Gemini CLI / Antigravity CLI (`agy`)
sub-agents through [herdr](https://github.com/herdr) — each task gets its own
git worktree and branch, runs with auto-approve enabled, and is reviewed before
anything lands on your branch.

## Requirements

- `herdr` — and Claude Code must be started **inside** a herdr pane (`HERDR_ENV=1`).
  The scripts refuse to run otherwise.
- `bash`, `git`, `jq`
- At least one agent binary: `agy` (Antigravity CLI) or `gemini` (classic Gemini CLI)

## Install

Clone the repo into your Claude Code skills directory:

```bash
git clone https://github.com/gzawadzki/gemini-swarm.git ~/.claude/skills/gemini-swarm
chmod +x ~/.claude/skills/gemini-swarm/scripts/*.sh
```

Restart Claude Code. The skill is picked up from `SKILL.md`; ask for it by name
(`gemini-swarm`) or just say "spin up a swarm of Gemini sub-agents".

## Use

Normally you don't run anything by hand — you describe the tasks and Claude
writes the config and drives the scripts. To do it manually:

**1. Write a `tasks.json`** (copy `tasks.example.json` and edit):

```json
{
  "tasks": [
    {
      "name": "fix-auth-bug",
      "kind": "agy",
      "model": "gemini-3.1-pro",
      "effort": "high",
      "repo": "/absolute/path/to/repo",
      "branch": "agent/fix-auth-bug",
      "prompt": "Fix the failing test in tests/test_auth.py, then run pytest and report the result.",
      "args": [],
      "timeout_ms": 120000
    }
  ]
}
```

**2. Launch** — creates a worktree + branch per task and starts the agents in
parallel:

```bash
scripts/launch.sh tasks.json
```

Each task's full brief is written to `~/.herdr/briefs/<name>.md` (override with
`HERDR_SWARM_BRIEF_DIR`) and the agent only receives a one-line pointer to it —
long multi-line prompts don't survive `herdr agent prompt`. Result files land
next to the briefs as `<name>.result.json`.

**3. Check status** — a task is review-ready only when herdr says `idle`/`done`,
its result file says `success`, **and** its worktree is clean:

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

State lives in `.herdr-swarm/state.json` (override with `HERDR_SWARM_STATE_DIR`).

## Safety

Agents run with `--yolo` / `--dangerously-skip-permissions`, so every
confirmation is disabled. Worktree isolation keeps them off your checked-out
files, but only point them at repos you're fine with an agent editing
unattended — and never merge a branch you haven't read the diff for. See the
"Safety notes" section of `SKILL.md` for the full list.
