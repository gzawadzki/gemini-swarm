# gemini-swarm

A Claude Code skill for running parallel Gemini CLI / Antigravity CLI (`agy`)
sub-agents through [herdr](https://github.com/herdr). Each task gets its own git
worktree and branch, runs with auto-approve enabled, and is reviewed before
anything lands on your branch. When the Antigravity quota of your main account is
empty, tasks run on a second Antigravity account instead.

## Requirements

- `herdr`, and Claude Code must be started **inside** a herdr pane
  (`HERDR_ENV=1`). The scripts refuse to run otherwise.
- `bash`, `git`, `jq`
- At least one agent binary: `agy` (Antigravity CLI), `gemini` (classic Gemini
  CLI), or `codex` (OpenAI Codex CLI)
- Optional, for the second Antigravity account: PowerShell 7 (`pwsh`) and a
  second Windows user, see "Two Antigravity accounts" below

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

**6. Close the agents** when you are done with them. A finished agy agent does
not exit on its own; it sits in its pane still holding the shared Antigravity
credential, which blocks the next account switch:

```bash
scripts/cleanup.sh                 # close agents that reported a result
scripts/cleanup.sh --worktrees     # and remove a worktree once its branch is merged
```

State lives in `.herdr-swarm/state.json`. Override the location with
`HERDR_SWARM_STATE_DIR`.

## Two Antigravity accounts

Antigravity meters two quota pools separately, **Gemini Models** for `gemini-*`
slugs and **Claude and GPT models** for `claude-*` and `gpt-*` slugs, each with a
weekly and a five-hour window. An agent started against an empty pool cannot make
a single call, and in herdr it looks identical to an agent still thinking.

So `launch.sh` reads `agy -p "/usage"` before it starts anything. If the pool a
task's model draws from reads 0% in either window, the swarm switches the live
Antigravity account and runs the task on the other subscription. If that one is
empty too, the task is **not launched at all** and the script reports when each
account refills. Other tasks are unaffected, so a Claude task keeps running on
the live account after the Gemini pool empties. If the quota cannot be read, the
task stays on the live account and the script warns rather than guessing. There
is no codex fallback: codex only ever runs when you ask for it by name.

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
installed, there is simply no second account and the swarm stops when the live
one empties.

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
| `HERDR_SWARM_NO_SWITCHING=1` | Never switch accounts; stop when the live one is empty. |

## Safety

Agents run with `--yolo`, `--dangerously-skip-permissions` or
`--dangerously-bypass-approvals-and-sandbox`, so every confirmation is disabled.
Worktree isolation keeps them off your checked-out files, but only point them at
repos you are fine with an agent editing unattended, and never merge a branch you
have not read the diff for. See the "Safety notes" section of `SKILL.md` for the
full list.
