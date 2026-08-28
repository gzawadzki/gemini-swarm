---
name: herdr-gemini-swarm
description: Orchestrate parallel Gemini CLI / Antigravity CLI (agy) sub-agents through herdr. Writes a task config, launches each task as an auto-approving background agent on its own git worktree and branch, falls back to codex when the Antigravity quota is empty, then checks status, reads logs, and reviews the diff before it touches the user's branch. Use this when the user asks to run Gemini/Antigravity sub-agents, spin up a swarm of coding agents, or delegate parallel coding tasks through herdr.
---

# herdr Gemini/Antigravity swarm

Runs one or more `gemini` / `agy` (Antigravity CLI) instances as background agents
inside `herdr` panes, each on its own git worktree and branch, with auto-approve
enabled. Gives you a way to check on them, read their output, and review their
diff before anything lands on the user's branch. When the Antigravity quota is
gone, tasks run on `codex` instead.

## 0. Precondition: must run inside herdr

Before doing anything else, check `HERDR_ENV`. If it is not `1`, **stop** and tell
the user this skill only works from inside a herdr-managed pane, meaning Claude
Code itself was started with `herdr` or inside a herdr session. Do not try to
launch a new herdr server or fake this check.

```bash
[ "$HERDR_ENV" = "1" ] || echo "not inside herdr, aborting"
```

## 1. Know the three agent kinds

| kind     | binary   | auto-approve flag                            | notes |
|----------|----------|----------------------------------------------|-------|
| `gemini` | `gemini` | `--yolo` (or `--approval-mode yolo`)         | Classic Gemini CLI. Google sunset this for Free/Pro/Ultra users on 2026-06-18 in favor of Antigravity CLI, so it may not be installed on the user's machine anymore. Check with `command -v gemini` before assuming it exists. |
| `agy`    | `agy`    | `--dangerously-skip-permissions`             | Antigravity CLI, the successor. This is the flag name Google ships. Treat it as seriously as it sounds. |
| `codex`  | `codex`  | `--dangerously-bypass-approvals-and-sandbox` | OpenAI Codex CLI. Used as the fallback when the Antigravity quota hits 0%, see section 3. You can also ask for it directly. |

All three are valid `--kind` values for `herdr agent start`, so no manual pane
fallback is needed. If the user says "Gemini" but only `agy` is installed, ask
once which they mean rather than silently swapping binaries.

## 2. Pick a model for each task

`agy` exposes several models through `--model`, each with a real cost, speed and
quality tradeoff. Pick one **per task** based on the task's actual difficulty.
Do not default everything to the biggest model. Classic `gemini` CLI has no model
menu, so this applies to `kind: "agy"` and `kind: "codex"` only.

Most agy slugs bake the reasoning effort into the name, so `gemini-3.7-flash-low`
and `gemini-3.7-flash-high` are separate slugs. A `--effort` flag
(`low|medium|high`) exists as well. Run `agy models` on the target machine to
confirm the live list, since it changes between versions. Confirmed with
Antigravity CLI 1.1.22:

| Model slug | Use it for |
|------------|------------|
| `gemini-3.7-flash-low`, `-medium`, `-high` | Cheap and fast. Formatting, boilerplate, mechanical fixes. Do not park it on a hard bug. |
| `gemini-3.1-pro-low`, `gemini-3.1-pro-high` | The default pick for agentic work. 1M context, steady on big repos. Choose this when nothing else fits better. |
| `claude-sonnet-4-6` | Step-by-step reasoning without Opus pricing. Code review, non-trivial refactor, explaining why something breaks. |
| `claude-opus-4-6-thinking` | The heaviest model here. Security review, nasty bugs, architecture. Expensive, so save it for tasks where Sonnet and Gemini Pro already failed. |
| `gpt-oss-120b-medium` | Open-weight, 400K context, generally below Gemini Pro and Opus at coding. Use it for a second opinion, rarely as the first pick. |

Older slugs (`gemini-3.6-flash-*`, `gemini-3.5-flash-*`) are still listed and
still work. Prefer the newest generation unless the user asks otherwise.

Routing heuristic when generating `tasks.json`:

1. Mechanical, low-risk, well-defined goes to `gemini-3.7-flash-medium`.
2. Ordinary feature or bugfix goes to `gemini-3.1-pro-high`, the default.
3. Review, refactor, or anything needing careful reasoning goes to `claude-sonnet-4-6`.
4. Genuinely hard, high-stakes, or a retry after a failed attempt goes to `claude-opus-4-6-thinking`.
5. A requested GPT-style comparison goes to `gpt-oss-120b-medium`.

If the user names a model outright, use it and skip the heuristic.

## 3. The codex fallback when the Antigravity quota runs out

Antigravity meters two quota pools separately, and each has a weekly and a
five-hour window:

- **Gemini Models** covers every `gemini-*` slug.
- **Claude and GPT models** covers `claude-*` and `gpt-*` slugs.

An agent launched against an empty pool cannot make a single call, and in herdr
that looks the same as an agent still thinking. So `launch.sh` reads the quota
before it starts anything and routes affected tasks to `codex` running
`gpt-5.6-luna` at `xhigh` reasoning effort.

The rules it applies:

- Only the pool a task's model draws from matters. If Gemini sits at 0% and
  Claude/GPT at 82%, the `gemini-3.1-pro-high` tasks move to codex and the
  `claude-opus-4-6-thinking` tasks stay on agy.
- Either window counts. 0% on the five-hour limit blocks the task right now even
  when the weekly limit still has room, so it triggers the fallback.
- A task with no `model` set runs on whatever agy defaults to, which the CLI does
  not report, so an empty pool on either side triggers the fallback.
- If the quota cannot be read at all, the task stays on agy and `launch.sh`
  prints a warning. It does not guess.

Reading the quota is the fiddly part. There is no `agy usage` subcommand, and
`/usage` only expands in print mode:

```bash
MSYS_NO_PATHCONV=1 agy -p "/usage"
```

```
Gemini Models	Weekly Limit Remaining	80%	2026-09-04T00:18:35Z
Gemini Models	Five Hour Limit Remaining	22%	2026-08-28T12:31:35Z
Claude and GPT models	Weekly Limit Remaining	94%	2026-09-04T07:31:35Z
Claude and GPT models	Five Hour Limit Remaining	82%	2026-08-28T12:31:35Z
```

**`MSYS_NO_PATHCONV=1` is required on Windows.** Without it, Git Bash rewrites
the leading slash and agy receives `C:/Program Files/Git/usage`, which it treats
as an ordinary prompt about a file path. The call then burns a model turn and
returns prose instead of numbers, so every quota check silently reads as "cannot
tell". The same trap applies to any other slash command you script.

Codex takes its reasoning depth through config rather than a flag, so the
fallback launches as:

```
codex --dangerously-bypass-approvals-and-sandbox --model gpt-5.6-luna -c model_reasoning_effort="xhigh"
```

`gpt-5.6-luna` accepts `low`, `medium`, `high`, `xhigh` and `max`. Override the
defaults with environment variables:

- `HERDR_SWARM_NO_FALLBACK=1` skips the quota check and keeps every task on agy.
- `HERDR_SWARM_CODEX_MODEL` and `HERDR_SWARM_CODEX_EFFORT` change what the
  fallback runs.

A task that fell back is recorded in `state.json` as `fallback_from`, shows up in
`status.sh` with a `*` after the agent name, and is called out by `review.sh`.
Say so when you report results. The diff came from a different model than the one
the user asked for, which matters when they picked `claude-opus-4-6-thinking` for
a reason.

## 4. Git workflow: always branch and worktree, review before merge

**Give each task its own git worktree and branch. Never point two agents at the
same working directory.** Two agents editing the same checked-out files in
parallel corrupts both. A branch alone does not fix this, because the working
directory is still shared. `herdr worktree create` gives each task its own
checkout on its own branch at the same time.

Pipeline, in order:

1. **Isolate.** Run `herdr worktree create --cwd <repo> --branch agent/<name> --label <name> --no-focus`,
   omitting `--base` so it branches from the repo's current `HEAD`, which is the
   user's active local branch. This also creates the workspace and pane, so do
   not call `workspace create` separately for these tasks. Every herdr JSON field
   path the scripts depend on lives in `scripts/lib.sh`. The response shape is
   undocumented upstream, so when a herdr upgrade breaks something, fix it there
   rather than in four places. Confirmed with herdr and Antigravity CLI 1.1.22:
   - agent state is `.result.agent.agent_status`, **not** `.status`
   - input readiness is `.result.agent.interactive_ready`
   - checkout path is `.result.workspace.worktree.checkout_path`, **not**
     `.workspace.cwd`, which is absent. Windows paths come back with backslashes
     and need normalising before `git -C`.
2. **Instruct commit discipline.** The generated prompt must tell the agent to
   commit as it goes and leave a clean tree, so that a `git status --porcelain`
   check means something.
3. **Gate on three things, not one.** A task is done when herdr state is `idle`
   or `done`, the result file says `"status": "success"`, **and** the worktree is
   clean. If any is missing, it is not ready for review. Do not merge because the
   agent said "done" in prose.
4. **Read the diff yourself before touching the user's branch.** Do not trust the
   agent's own summary. Read `git log <base>.. --oneline` and the actual
   `git diff <base>...` for the task's worktree. This step is what makes
   auto-approve safe to run unattended. An unreviewed diff from a model with no
   confirmation gate is the failure mode to guard against.
5. **Send fixes back to the same agent** with
   `herdr agent prompt <name> "<specific fix>" --wait` rather than rewriting the
   code yourself, since it already has the context. Cap this at 2 review-fix
   rounds per task, then surface the problem to the user instead of re-prompting
   forever.
6. **Never merge into the user's active branch automatically.** Once a task
   passes review, stop and present the branch name, commit log, diff stat, which
   model produced it, and your verdict. Then ask how they want to bring it in:
   merge, squash, cherry-pick specific commits, or discard. This changes the
   branch the user is actively working on, so it gets the same explicit
   confirmation as any other side-effectful action, even though git makes it
   reversible.
7. **Clean up after the decision** with `herdr worktree remove --workspace <id>`,
   adding `--force` only if the user chose to discard a dirty checkout. This
   removes the checkout, never the branch. Delete the branch separately if the
   user wants it gone too.

## 5. Write the task config

Generate a JSON file shaped like `tasks.example.json`. Do not invent a different
schema, because the scripts depend on this one:

```json
{
  "tasks": [
    {
      "name": "fix-auth-bug",
      "kind": "agy",
      "model": "gemini-3.1-pro-high",
      "repo": "/absolute/path/to/repo",
      "branch": "agent/fix-auth-bug",
      "prompt": "Fix the failing test in tests/test_auth.py, then run pytest tests/test_auth.py and report the result.",
      "args": [],
      "timeout_ms": 900000
    }
  ]
}
```

- `name` is unique, lowercase, and matches `[a-z][a-z0-9_-]{0,31}`, herdr's
  agent-name rule.
- `kind` is `gemini`, `agy` or `codex`.
- `model` and `effort` apply to `agy` and `codex`, not to `gemini`. Most agy slugs
  already encode the effort, so `effort` is usually unnecessary there. For codex
  it becomes `-c model_reasoning_effort="<effort>"`.
- `repo` is the absolute path to the main repository. `launch.sh` creates a
  worktree from it, so the agent never touches this path directly.
- `branch` is the new branch for this task's worktree. Convention is
  `agent/<name>`. It branches from the repo's current `HEAD` unless `base` is set.
- `base` is an optional explicit base ref instead of `HEAD`.
- `prompt` is the task itself. `launch.sh` appends the commit-discipline and
  result-file wording, so do not write those. Do not put the auto-approve flag in
  the prompt text either.
- `args` are extra CLI flags. `launch.sh` injects the auto-approve flag and the
  model flags on its own, so only add flags beyond those.
- `timeout_ms` is how long `launch.sh` waits for the agent process to become
  ready. The default of 30000 is usually enough.

**Do not screen-scrape for success or failure.** herdr's `idle`, `done` and
`blocked` states tell you the agent stopped talking, not that the code or the
tests passed. So every prompt ends with an instruction to write a small JSON
result file:

> When you are completely finished, write a JSON file to `<status_file>` with
> `{"status": "success"|"failure", "summary": "...", "tests_passed": true|false}`
> as your very last action, then make sure `git status` is clean.

`launch.sh` appends this for you. Write only the task-specific instructions in
`prompt`.

## 6. Launch

```bash
scripts/launch.sh tasks.json
```

For each task this:

1. Reads the Antigravity quota once and decides whether the task runs on agy or
   falls back to codex, per section 3.
2. Runs `herdr worktree create --cwd <repo> --branch <branch> [--base <base>] --label <name> --no-focus`.
3. Runs `herdr agent start <name> --kind <kind> --pane <pane_id> -- <auto-approve-flag> [model flags] <args...>`.
4. Waits for `interactive_ready`, then runs `herdr agent prompt <name> "<prompt
   plus status-file and commit-discipline instructions>"` **without** `--wait`, so
   tasks run in parallel, and confirms the agent reacted.

   Both halves of step 4 matter. `agent start` returns when the process exists,
   which is earlier than the TUI accepting input, and a prompt sent in that window
   is lost silently. herdr answers `agent_prompted`, the agent never sees it, and
   the pane sits idle with an empty input box, which is indistinguishable from a
   task waiting for review. So `launch.sh` compares `state_change_seq` before and
   after submitting, and resends once if nothing moved. **Never send a prompt with
   its output redirected to `/dev/null`.**
5. Records `{name, kind, model, effort, fallback_from, branch, base, pane_id,
   workspace_id, worktree_path, status_file}` into `.herdr-swarm/state.json`.

Launching confirms that the agent started and accepted the prompt. It confirms
nothing about the work.

## 7. Check status

```bash
scripts/status.sh
```

For every task this prints the herdr lifecycle state from `herdr agent get <name>`,
which agent kind actually ran, whether `status_file` exists and what it says, and
whether the worktree is clean per `git status --porcelain`. A task is
review-ready only when **all three** line up: herdr `idle` or `done`,
`status: success`, and a clean tree. An agent name ending in `*` fell back to
codex.

`blocked` means something needs a human despite auto-approve. Read its logs and
decide, rather than looping retries.

`unreachable` for a task you just launched means the script is asking herdr the
wrong question, not that the agent died. Check `herdr agent list` before
relaunching anything. Same for `n/a` under CLEAN, which is an unresolved worktree
path rather than a clean tree.

## 8. Review before merging

For each review-ready task:

```bash
scripts/review.sh <task-name>
```

This prints which model produced the work, whether it fell back to codex, the
commit log and diffstat for `<branch>` against its base, and the worktree path.
Read the actual diff with `git -C <worktree_path> diff <base>...` before deciding.
This is the human-in-the-loop step even though Claude is running it, and it is
what makes auto-approve acceptable in the first place. Then follow section 4
steps 5 to 7: fix by re-prompting if needed, at most twice, present the result and
ask the user how to merge, and clean up the worktree once they decide.

## 9. Read logs

```bash
scripts/logs.sh <task-name> [lines]
```

This wraps `herdr agent read <name> --source recent-unwrapped --lines <N>`,
defaulting to 150. Use `recent-unwrapped` rather than `visible`, because it is not
limited to the current terminal viewport.

## Safety notes to apply, not just mention

- `--yolo`, `--dangerously-skip-permissions` and
  `--dangerously-bypass-approvals-and-sandbox` disable every confirmation,
  including destructive shell commands and file edits. The codex flag also
  disables its sandbox, which the swarm needs because agents write their result
  file outside their own worktree. Worktree isolation keeps agents off the user's
  checked-out files, but only launch tasks against a `repo` the user is fine with
  an agent modifying unattended.
- Never source a task's `prompt` from untrusted content, such as an issue, a
  scraped page or another agent's output, without the user seeing it first. That
  is prompt injection with auto-approve turned on.
- The review step in section 8 is not ceremony. It is the only thing between an
  auto-approving agent and the user's branch. Do not skip it because a status file
  says success.
- Report when a task fell back to codex. The user picked a model for a reason, and
  a security review done by `gpt-5.6-luna` instead of `claude-opus-4-6-thinking`
  is a different piece of work.
- If `status.sh` shows `blocked` for longer than expected, a human is needed. That
  is not a reason to add more auto-approve flags.
