# gemini-swarm

A skill for orchestrating parallel agents from **Pi** through [herdr](https://github.com/herdr). Pi Antigravity workers handle bounded slices; Codex workers are also supported. Each task gets its own Git worktree and branch. The swarm verifies and critiques the result before handing the diff back for review. Claude Code is not required.

## Requirements

- Run the orchestrator inside a herdr pane (`HERDR_ENV=1`).
- Install `herdr`, `bash`, `git`, `jq`, Pi, and the `pi-antigravity` provider.
- Sign in to Antigravity from Pi. Pi manages linked accounts; the launcher checks available Antigravity quota before opening worker panes. See [accounts](docs/reference/accounts-and-quota.md) and [quota preflight](docs/reference/quota-preflight.md).

## Install

```bash
git clone https://github.com/gzawadzki/gemini-swarm.git ~/.agents/skills/gemini-swarm
chmod +x ~/.agents/skills/gemini-swarm/scripts/*.sh
pi install npm:pi-antigravity
```

Pi discovers skills in `~/.agents/skills/`. Start Pi inside a herdr-managed pane, use `/login antigravity`, then `/reload` if Pi was already running when you installed the skill.

Invoke `/skill:herdr-gemini-swarm` and give Pi bounded coding tasks. The command uses the name declared in `SKILL.md`, not the clone directory name.

## Distribution contents

This repository contains the installable skill: `SKILL.md`, runtime scripts,
required provider patches, and operator documentation. Task configs, run archives,
evaluation datasets, tests, and development notes are not distributed.
Keep generated configs and evidence in your project's run directory, outside the
installed skill.

Quota preflight requires the compatible provider patch described in
[quota installation](docs/reference/quota-preflight.md#installation-and-verification).
Installing the unpatched provider alone is not sufficient.

## Run manually

Create `tasks.json` in your project's run directory:

```json
{
  "tasks": [
    {
      "name": "fix-auth-bug",
      "kind": "pi",
      "model": "gemini-3.8-flash-high",
      "repo": "/absolute/path/to/repo",
      "branch": "agent/fix-auth-bug",
      "prompt": "Fix the expired token fixture in tests/test_auth.py.",
      "files": ["tests/test_auth.py"],
      "pitfalls": ["Keep the token verification leeway unchanged."],
      "verify": "pytest -q tests/test_auth.py"
    }
  ]
}
```

Run from your project's run directory so state stays outside the skill checkout:

```bash
SKILL_DIR="$HOME/.agents/skills/gemini-swarm"
bash "$SKILL_DIR/scripts/launch.sh" --allow-unsandboxed tasks.json
bash "$SKILL_DIR/scripts/status.sh"
bash "$SKILL_DIR/scripts/verify.sh" fix-auth-bug
bash "$SKILL_DIR/scripts/critique.sh" fix-auth-bug
bash "$SKILL_DIR/scripts/review.sh" fix-auth-bug
bash "$SKILL_DIR/scripts/cleanup.sh" --worktrees
```

`verify` runs in the agent worktree and checks where the tested code resolved. A pass from another checkout is rejected; an unknown result is marked `skipped`. The critique asks Jev first. A verified, sound, in-scope diff whose signals are all at or below the threshold is accepted without a generative reviewer. Anything else goes to that reviewer. Set `HERDR_SWARM_JEV_MODE=shadow` to score without accepting, or `disabled` to skip Jev. Read the handoff before merging. Cleanup archives the run under `~/.herdr/runs/`.

Unattended workers require an explicit unsandboxed opt-in when no sandbox backend is available. Read the launch warning and [worker permissions](docs/reference/worker-permissions.md) before using it. A Git worktree separates files but does not confine the worker process.

## References

| Topic | Guide |
| --- | --- |
| Task schema and scope | [Task definition](docs/reference/task-definition.md) |
| Models and Pi routing | [Models and routing](docs/reference/models-and-routing.md) |
| Gate and review | [The gate](docs/reference/the-gate.md) |
| Jev calibration | [Jev evaluation](docs/reference/jev-evaluation.md) |
| Run outcomes and retries | [Run outcomes](docs/reference/run-outcomes.md) |
| Quota preflight limitations | [Quota preflight](docs/reference/quota-preflight.md) |
| Accounts | [Accounts and quota](docs/reference/accounts-and-quota.md) |
| Archive and cleanup | [Cleanup and archive](docs/reference/cleanup-and-archive.md) |
| Diagnostics | [Troubleshooting](docs/reference/troubleshooting.md) |

Use `scripts/logs.sh <task>` for a worker log and `--trace` on a script for its trace. The [skill instructions](SKILL.md) describe the full operator flow.
