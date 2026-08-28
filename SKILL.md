---
name: herdr-gemini-swarm
description: Orchestrate parallel Gemini CLI / Antigravity CLI (agy) sub-agents through herdr — write a task config, launch each task as an auto-approving background agent on its own git worktree/branch, then check status, read logs, and review the diff before it touches the user's branch. Use this when the user asks to run Gemini/Antigravity sub-agents, spin up a swarm of coding agents, or delegate parallel coding tasks through herdr.
---

# herdr Gemini/Antigravity swarm

Runs one or more `gemini` / `agy` (Antigravity CLI) instances as background agents
inside `herdr` panes, each on its own git worktree and branch, with auto-approve
enabled — and gives you a way to check on them, read their output, and review
their diff before anything lands on the user's branch.

## 0. Precondition — must run inside herdr

Before doing anything else, check `HERDR_ENV`. If it is not `1`, **stop** and tell
the user this skill only works from inside a herdr-managed pane (i.e. Claude Code
itself was started with `herdr` / inside a herdr session). Do not try to launch a
new herdr server or fake this check.

```bash
[ "$HERDR_ENV" = "1" ] || echo "not inside herdr, aborting"
```

## 1. Know the two agent kinds

| kind    | binary  | auto-approve flag              | notes                                                                 |
|---------|---------|---------------------------------|------------------------------------------------------------------------|
| `gemini`| `gemini`| `--yolo` (or `--approval-mode yolo`) | Classic Gemini CLI. Google sunset this for Free/Pro/Ultra users on 2026-06-18 in favor of Antigravity CLI — it may not be installed on the user's machine anymore. Check with `command -v gemini` before assuming it exists. |
| `agy`   | `agy`   | `--dangerously-skip-permissions`     | Antigravity CLI, the successor. This is the flag name Google actually ships — treat it as seriously as it sounds. |

Both are valid `--kind` values for `herdr agent start` — no manual pane fallback
needed. If the user says "Gemini" but only `agy` is installed, ask once which
they mean rather than silently swapping binaries.

## 2. Pick a model for each task (agy only)

`agy` exposes multiple reasoning models via `--model`, each with a real
cost/speed/quality tradeoff. Pick one **per task** based on the task's actual
difficulty — don't default everything to the biggest model. Classic `gemini`
CLI has no comparable model menu, so this step only applies to `kind: "agy"`.

> The exact `--model` slug strings vary slightly between docs/versions. Run
> `agy models` once on the target machine to confirm the live list before
> trusting the table below verbatim.

| Model (`--model` slug)       | Effort levels            | "Say it like the model would"                                                                                                                                                                              | Use it for |
|-------------------------------|----------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|------------|
| `gemini-3.7-flash`            | fast, low, medium, high    | "I'm cheap and fast — throw the small stuff at me: formatting, boilerplate, mechanical fixes. Don't park me on a hard bug."                                                                              | Simple, mechanical, well-defined tasks. `low`/`medium` effort. |
| `gemini-3.1-pro`              | low, high                  | "I'm the default pick for most agentic work — 1M context, steady on big repos. If you don't know what to choose, choose me."                                                                             | Standard mid-complexity tasks, large repos. **Default** when nothing else fits clearly better. |
| `claude-sonnet-4-6-thinking`  | (fixed, thinking on)       | "Good at step-by-step reasoning — code review, refactoring, explaining 'why' — without Opus pricing."                                                                                                    | Tasks needing real reasoning but not the extreme end. Review, non-trivial refactor. |
| `claude-opus-4-6-thinking`    | (fixed, thinking on)       | "The heaviest gun here. Use me when Sonnet and Gemini Pro have already failed, or the task is genuinely hard. Expensive — don't waste me on simple things."                                              | Hard/high-stakes: security review, nasty bugs, architecture. Last resort. |
| `gpt-oss-120b`                | medium                     | "Open-weight from OpenAI, smaller context (400K vs 1M), generally below Gemini Pro/Opus at coding. Use me for GPT-flavored style, or as an independent second opinion."                                  | Rarely the first pick — comparison / second opinion. |

Routing heuristic when generating `tasks.json`:
1. Mechanical / low-risk / well-defined → `gemini-3.7-flash`.
2. Ordinary feature or bugfix, nothing below fits better → `gemini-3.1-pro` (default).
3. Needs careful reasoning (review, refactor, "why") → `claude-sonnet-4-6-thinking`.
4. Genuinely hard / high-stakes / a previous attempt failed → `claude-opus-4-6-thinking`.
5. User explicitly wants a GPT-style comparison → `gpt-oss-120b`.

If the user names a model outright, use it — don't override it with the heuristic.

## 3. Git workflow — always branch + worktree, review before merge

**Always give each task its own git worktree + branch — never point two
agents at the same working directory.** Two agents editing the same checked-out
files in parallel corrupts both. A branch alone doesn't fix this (the working
directory is still shared); `herdr worktree create` gives each task its own
checkout on its own branch at the same time.

Pipeline, in order:

1. **Isolate.** `herdr worktree create --cwd <repo> --branch agent/<name> --label <name> --no-focus`,
   omitting `--base` so it branches from the repo's current `HEAD` (the user's
   active local branch) automatically. This also creates the workspace/pane —
   don't call `workspace create` separately for these tasks. The exact JSON
   shape of the response isn't documented in detail; on first use, inspect it
   (`| jq .`) to confirm where the workspace id, pane id, and worktree path
   actually live before trusting a field path in a script.
2. **Instruct commit discipline.** The generated prompt must tell the agent to
   commit as it goes and leave a clean tree — "commit your changes with
   descriptive messages; do not leave uncommitted changes at the end" — so a
   `git status --porcelain` check is a meaningful signal, not noise.
3. **Gate on three things, not one.** A task only counts as done when: herdr
   state is `idle`/`done`, the result file says `"status": "success"`, **and**
   the worktree is clean. If any is missing, it's not ready for review — don't
   merge just because the agent said "done" in prose.
4. **Review the diff yourself before touching the user's branch.** Don't trust
   the agent's own summary. Read `git log <base>.. --oneline` and the actual
   `git diff <base>...` for the task's worktree. This is the step that makes
   auto-approve (`--yolo` / `--dangerously-skip-permissions`) safe to run
   unattended — an unreviewed diff from a model with no confirmation gate is
   exactly the failure mode to guard against.
5. **If you find problems, prefer sending the fix back to the same agent**
   (`herdr agent prompt <name> "<specific fix>" --wait`) over rewriting it
   yourself — it already has the context. Cap this at 2 review-fix rounds per
   task; after that, stop looping and surface it to the user instead of
   re-prompting indefinitely.
6. **Never merge into the user's active branch automatically.** Once a task
   passes review, stop and present: branch name, commit log, diff stat, and
   your verdict — then ask how they want to bring it in (merge, squash,
   cherry-pick specific commits, or discard). This is a change to the branch
   the user is actively working on, so it gets the same explicit-confirmation
   treatment as any other side-effectful action, even though git makes it
   technically reversible.
7. **Clean up after the decision is made** — `herdr worktree remove --workspace <id>`
   (`--force` only if the user chose to discard a dirty checkout). This
   removes the checkout, never the branch; delete the branch separately if
   the user wants it gone too.

## 4. Write the task config

Generate a JSON file (see `tasks.example.json`) — don't invent a different
schema on the fly, the scripts below depend on this shape:

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
      "prompt": "Fix the failing test in tests/test_auth.py, then run pytest tests/test_auth.py and report the result.",
      "args": [],
      "timeout_ms": 120000
    }
  ]
}
```

- `name` — unique, lowercase, matches `[a-z][a-z0-9_-]{0,31}` (herdr's agent-name rule).
- `kind` — `gemini` or `agy`.
- `model` / `effort` — only used when `kind` is `agy`; see the routing table above.
- `repo` — absolute path to the main repository. `launch.sh` creates a worktree
  from this repo, not a plain pane in it — the agent never touches this path
  directly.
- `branch` — the new branch name for this task's worktree. Convention:
  `agent/<name>`. Branches from the repo's current `HEAD` unless `base` is set.
- `base` (optional) — explicit base ref instead of `HEAD`.
- `prompt` — the task itself, plus commit-discipline wording (see §3.2). **Do
  not** put the auto-approve flag in the prompt text.
- `args` — extra CLI flags. `launch.sh` injects the auto-approve flag (and
  `--model`/`--effort` for `agy`) automatically; only add *extra* flags here.
- `timeout_ms` — how long `launch.sh` waits for the agent process to become
  ready (default 30000 is usually enough). herdr's ceiling is **300000 ms**;
  `launch.sh` clamps anything larger and warns. This is the startup timeout,
  not a budget for the task itself — tasks run unbounded in the background.

**Reliability trick — don't trust screen-scraping for success/failure.** herdr's
`idle`/`done`/`blocked` states tell you the agent stopped talking, not that the
code or tests actually passed. Every generated prompt should end with an
explicit instruction to write a small JSON result file:

> When you are completely finished, write a JSON file to `<status_file>` with
> `{"status": "success"|"failure", "summary": "...", "tests_passed": true|false}`
> as your very last action, then make sure `git status` is clean.

`launch.sh` appends this automatically — you don't need to hand-write it,
just write the task-specific instructions in `prompt`.

**Delivery trick — never send a long prompt through `herdr agent prompt`.** A
multi-line brief (blank lines, non-ASCII text, dozens of lines) does not make
it into the agent's input box: herdr returns `agent_prompted` and the pane sits
there with an empty prompt, so the launch *looks* successful while nothing was
actually sent. `launch.sh` therefore writes the full brief to
`~/.herdr/briefs/<name>.md` (override with `HERDR_SWARM_BRIEF_DIR`) and sends a
single short line: *"Read the file <path> and carry out the task it describes
in this worktree."* Keep it that way if you drive herdr by hand — put the text
in a file, send one line.

The brief dir also holds the result files (`<name>.result.json`). It lives
outside every repo and worktree on purpose: an agent writing its result file
must not dirty the tree that `status.sh` checks with `git status --porcelain`.

## 5. Launch

```bash
scripts/launch.sh tasks.json
```

For each task this:
1. `herdr worktree create --cwd <repo> --branch <branch> [--base <base>] --label <name> --no-focus`.
2. `herdr agent start <name> --kind <kind> --pane <pane_id> -- <auto-approve-flag> [--model ...] [--effort ...] <args...>`.
3. Writes the full brief (task + commit discipline + result-file instruction)
   to `<brief_dir>/<name>.md`.
4. `herdr agent prompt <name> "Read the file <brief> and carry out ..."` — one
   short line, **without** `--wait`, so tasks run in parallel.
5. Records `{name, kind, branch, base, pane_id, workspace_id, worktree_path,
   brief_file, status_file}` into `.herdr-swarm/state.json`.

Launching does not confirm success — only that the agent started and accepted
the prompt. `agent_prompted` is not proof the text landed: after a launch,
check a pane (`scripts/logs.sh <task>`) and confirm the agent is actually
working before reporting that the swarm is running.

## 6. Check status

```bash
scripts/status.sh
```

For every task this prints: the herdr lifecycle state (`herdr agent get <name>`),
whether `status_file` exists and what it says, and whether the worktree is
clean (`git status --porcelain`). Treat a task as review-ready only when **all
three** line up: herdr `idle`/`done`, `status: success`, and a clean tree.
`blocked` means something needs a human despite auto-approve — read its logs
and decide, don't loop retrying blindly.

## 7. Review before merging

For each review-ready task:

```bash
scripts/review.sh <task-name>
```

Prints the commit log and diffstat for `<branch>` against its base, and the
worktree path. Read the actual diff (`git -C <worktree_path> diff <base>...`)
yourself before deciding — this is the human-in-the-loop-shaped step even
though it's Claude doing it, and it's what makes running these agents with
auto-approve acceptable in the first place. Then follow §3 steps 5–7: fix via
re-prompt if needed (max 2 rounds), present the result and ask the user how
to merge, and clean up the worktree once they've decided.

## 8. Read logs

```bash
scripts/logs.sh <task-name> [lines]
```

Wraps `herdr agent read <name> --source recent-unwrapped --lines <N>` (default
150). Use `recent-unwrapped`, not `visible` — it isn't limited to the current
terminal viewport, better for reviewing what a background task did.

## Safety notes to actually apply, not just mention

- `--yolo` / `--dangerously-skip-permissions` disable every confirmation,
  including destructive shell commands and file edits. Worktree isolation
  keeps agents off the user's actual checked-out files, but still only launch
  tasks against a `repo` the user is fine with an agent modifying unattended.
- Never source a task's `prompt` from untrusted content (an issue, a scraped
  page, another agent's output) without the user seeing it first — that's
  prompt injection with auto-approve turned on, i.e. worst case.
- The review step (§7) is not optional ceremony — it's the only thing standing
  between an auto-approving agent and the user's branch. Don't skip it because
  a task's status file says success.
- If `status.sh` shows `blocked` for longer than expected, that's a signal
  something needs a human, not a reason to add more `--yolo`-style flags.
