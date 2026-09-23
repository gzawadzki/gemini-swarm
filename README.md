# gemini-swarm

A skill for running parallel Pi agents through [herdr](https://github.com/herdr). Each task gets its own Git worktree and branch. The swarm checks the result before handing the diff back for review.

## Requirements

- Run the orchestrator inside a herdr pane (`HERDR_ENV=1`).
- Install `herdr`, `bash`, `git`, `jq`, Pi, and the `pi-antigravity` provider.
- Sign in to Antigravity from Pi. Pi manages linked accounts; the swarm does not inspect credentials or quota.

## Install

```bash
git clone https://github.com/gzawadzki/gemini-swarm.git ~/.claude/skills/gemini-swarm
chmod +x ~/.claude/skills/gemini-swarm/scripts/*.sh
pi install npm:pi-antigravity
```

Start Pi and use `/login antigravity`, then restart Claude Code. Ask for the `gemini-swarm` skill and give it bounded coding tasks.

## Run manually

Create `tasks.json`:

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

Then run:

```bash
scripts/launch.sh tasks.json
scripts/status.sh
scripts/verify.sh fix-auth-bug
scripts/critique.sh fix-auth-bug
scripts/review.sh fix-auth-bug
scripts/cleanup.sh --worktrees
```

`verify` runs in the agent worktree and checks where the tested code resolved. A pass from another checkout is rejected; an unknown result is marked `skipped`. The critique records Jev risk signals, then uses a generative reviewer when needed. Jev automatic acceptance requires a passing, sound verification and explicit enablement. In shadow mode it records a score without accepting the diff. Read the handoff before merging. Cleanup archives the run under `~/.herdr/runs/`.

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
