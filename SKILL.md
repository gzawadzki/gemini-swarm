---
name: herdr-gemini-swarm
description: Orchestrate parallel Gemini CLI / Antigravity CLI (agy) sub-agents through herdr. Writes a task config, launches each task as an auto-approving background agent on its own git worktree and branch, falls back to codex when the Antigravity quota is empty, then checks status, reads logs, runs a two-stage egress gate (tests plus a cheap-model critique of the diff), reviews the diff before it touches the user's branch, and cleans up task workspaces, worktrees, branches and scratch state once the result is integrated or discarded. Use this when the user asks to run Gemini/Antigravity sub-agents, spin up a swarm of coding agents, or delegate parallel coding tasks through herdr.
---

# herdr Gemini/Antigravity swarm

Runs one or more `gemini` / `agy` (Antigravity CLI) instances as background agents
inside `herdr` panes, each on its own git worktree and branch, with auto-approve
enabled. Gives you a way to check on them, read their output, and review their
diff before anything lands on the user's branch. When the Antigravity quota is
gone, tasks run on `codex` instead.

## Operating model: you orchestrate, the swarm executes

The division of labour is the point. **You** — Claude, in this session — are the
scarce, expensive reasoning: you decompose the goal, write the task prompts, run
the deterministic gate, read the diffs, and decide what merges. The **swarm** is
the cheap, abundant execution running in parallel on the Antigravity Gemini pool.
Every design choice below serves keeping those roles separate:

- **Spend the swarm pool, not your attention.** Default tasks to Gemini models
  (section 2), let deterministic scripts watch them (never poll an agent with your
  own tokens), and let the two-stage egress gate bounce bad work before it reaches
  your eyes: `verify.sh` (section 8) proves the tests run, and `critique.sh`
  (section 9) puts a cheap model on the diff first. Both stages spend the swarm
  pool. Neither one approves anything.
- **Decompose for parallelism.** Throughput comes from fanning out, so split a
  large goal into the most independent slices you can. Two agents editing the same
  files collide even on separate worktrees at merge time, so prefer slices that
  touch disjoint files or modules. When tasks genuinely depend on each other, run
  the upstream one, review and merge it, then launch the downstream one from the
  new base rather than guessing at a moving target.
- **Give each task a self-check.** A prompt that ends in "run these tests" plus a
  scoped `verify` command turns a vague "done" into a fact you can gate on.
- **Keep the wrappers thin.** These scripts are output filters and contract
  enforcers over `herdr`, not a framework. When herdr changes, fix `lib.sh`, not
  four files. Resist growing features here; the maintenance drag is the failure
  mode.

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

Most agy slugs bake the reasoning effort into the name, so `gemini-3.8-flash-low`
and `gemini-3.8-flash-high` are separate slugs. A `--effort` flag
(`low|medium|high`) exists as well. Run `agy models` on the target machine to
confirm the live list, since it changes between versions. Confirmed with
Antigravity CLI 1.1.27:

| Model slug | Use it for |
|------------|------------|
| `gemini-3.8-flash-low`, `-medium`, `-high` | Cheap and fast. Formatting, boilerplate, mechanical fixes. Do not park it on a hard bug. Newest Flash generation; prefer it over the 3.7 and 3.6 slugs. |
| `gemini-3.1-pro-low`, `gemini-3.1-pro-high` | The default pick for agentic work. 1M context, steady on big repos. Choose this when nothing else fits better. |
| `claude-sonnet-4-6` | Step-by-step reasoning without Opus pricing. Code review, non-trivial refactor, explaining why something breaks. |
| `claude-opus-4-6-thinking` | The heaviest model here. Security review, nasty bugs, architecture. Expensive, so save it for tasks where Sonnet and Gemini Pro already failed. |
| `gpt-oss-120b-medium` | Open-weight, 400K context, generally below Gemini Pro and Opus at coding. Use it for a second opinion, rarely as the first pick. |

Older slugs (`gemini-3.7-flash-*`, `gemini-3.6-flash-*`) are still listed and
still work. Prefer the newest generation unless the user asks otherwise. Google
adds a Flash generation faster than this file gets updated, so if `agy models`
shows a higher number than the table does, trust `agy models` and use it.

### Default to the Gemini pool; you are the reasoning

The whole point of this setup is division of labour: **you** (Claude, orchestrating
this session) do the heavy thinking, decomposition and review, and the swarm does
volume in parallel on the cheap, abundant resource. Antigravity meters two pools
separately (see section 3), and the **Gemini Models** pool is the large one the
user actually pays for. The **Claude and GPT models** pool is scarcer, and routing
swarm work into it both drains it fast and duplicates reasoning you already
provide as the orchestrator.

So the default routing when generating `tasks.json` is:

1. Mechanical, low-risk, well-defined goes to `gemini-3.8-flash-medium`.
2. **Everything else** — ordinary features, bugfixes, refactors, and reviews —
   goes to `gemini-3.1-pro-high`. This is the default for almost every task.
3. Reach for a `claude-*` or `gpt-*` slug **only when the user names it**, or when
   a task genuinely failed on Gemini Pro twice and needs a different model. When
   you do, say so, because it spends the scarce pool.

If the user names a model outright, use it and skip the heuristic. If you think a
task truly needs Claude-grade reasoning, the cheaper move is usually to keep the
heavy thinking in *this* session and hand the swarm a smaller, well-specified
slice, rather than paying for `claude-*` inside agy.

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
   rather than in four places. Confirmed with herdr 0.8.2 and Antigravity CLI
   1.1.27:
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
4. **Run the deterministic gate before you read anything.** Once those three line
   up, run `scripts/verify.sh <name>`. It runs the task's `verify` command (or an
   auto-detected test/build) inside the worktree and caches pass/fail. This is a
   deterministic filter that costs zero of your tokens: a task that broke the
   build or failed its own tests should never reach your eyes. Send failures
   straight back to the agent (step 7) instead of reading the diff.
5. **Then run the machine critique**, `scripts/critique.sh <name>`. A cheap model
   on the swarm pool reads the diff against the task's own prompt and answers the
   question verify cannot: is this the change that was asked for. `revise` and
   `reject` go back to the agent (step 7) with the issues attached, again without
   costing you a read. Only `pass`, `skipped` and a failed critique reach step 6.
6. **Read the diff yourself before touching the user's branch.** Do not trust the
   agent's own summary, and do not trust a critique `pass` either — it is one
   cheap model's opinion, weaker evidence than the test run. Read
   `git log <base>.. --oneline` and the actual `git diff <base>...` for the task's
   worktree. The gate decides which diffs are worth reading; it never decides that
   a diff does not need reading. An unreviewed diff from a model with no
   confirmation gate is the failure mode to guard against.
7. **Send fixes back to the same agent** with
   `herdr agent prompt <name> "<specific fix>" --wait` rather than rewriting the
   code yourself, since it already has the context. A verify failure is the
   clearest thing to bounce back: paste the failing command and its output. A
   critique `revise` is the next clearest: paste its issue list verbatim. Cap this
   at 2 review-fix rounds per task, then surface the problem to the user instead
   of re-prompting forever.
8. **Never merge into the user's active branch automatically.** Once a task
   passes review, stop and present the branch name, commit log, diff stat, which
   model produced it, the verify and critique results, and your verdict. Then ask
   how they want to bring it in: merge, squash, cherry-pick specific commits, or
   discard. This changes the branch the user is actively working on, so it gets
   the same explicit confirmation as any other side-effectful action, even though
   git makes it reversible.
9. **Clean up before reporting completion.** Once the reviewed result is
   integrated, preserved on another ref, or explicitly discarded, cleanup is part
   of the task rather than an optional follow-up:
   - Confirm the task worktree is clean, then remove it with
     `herdr worktree remove --workspace <id>`; add `--force` only when the user
     explicitly chose to discard a dirty checkout. Close any duplicate or
     orphaned workspace created for the same task. This removes the checkout,
     never the branch.
   - Delete `agent/<name>` only after confirming its desired commits are present
     on the user's branch, a PR ref, or a deliberate backup — or after the user
     chose to discard them. The branch is the only copy of that work.
   - Remove that task's entry, result file, logs and gate artifacts from
     `.herdr-swarm` (`<name>.result.json`, `<name>.verify.json`,
     `<name>.verify.log`, `<name>.critique.json`, `<name>.critique.brief.md`,
     `<name>.critique.reply.txt`). Remove the directory only when no active task
     still uses it; preserve shared state for workers that are still running.
   - Verify the cleanup: the task is absent from `herdr workspace list`, its path
     is absent from `git worktree list`, its disposable branch is absent from
     `git branch --list 'agent/<name>'`, and the user's pre-existing
     working-tree changes are unchanged.

   A swarm task is not complete until that verification passes. Report anything
   intentionally retained, such as a backup branch, and why it remains.

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
      "verify": "pytest -q tests/test_auth.py",
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
  the prompt text either. Write it specifically enough to be checkable, because
  `critique.sh` (section 9) grades the diff against this text: "add a retry with
  backoff to the S3 upload in storage.py and cover it with a test" gives the
  reviewer something to measure, "improve error handling" does not.
- `args` are extra CLI flags. `launch.sh` injects the auto-approve flag and the
  model flags on its own, so only add flags beyond those.
- `verify` is an optional shell command `verify.sh` runs inside the worktree as
  the egress gate (section 8). Set it to the narrowest check that proves the task
  worked, usually the test file it touched, e.g. `pytest -q tests/test_auth.py`.
  Omit it and `verify.sh` tries to auto-detect one from the project (npm/yarn/pnpm
  `test`, `pytest`, `cargo test`, `go test`, a `test:` Make target); if it finds
  nothing the gate reports `skipped` rather than blocking. Prefer setting it
  explicitly, since a scoped command is faster and less flaky than a full suite.
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
5. Records `{name, kind, model, effort, fallback_from, branch, base, base_sha,
   pane_id, workspace_id, worktree_path, status_file, verify, prompt}` into
   `.herdr-swarm/state.json`. The `prompt` is stored because `critique.sh`
   (section 9) needs to know what the task was asked to do in order to judge
   whether the diff did it.

Launching confirms that the agent started and accepted the prompt. It confirms
nothing about the work.

Add `--trace` (section 12) when you want the launch decisions on the record —
which pool was read, which model each task ended up on, and whether the prompt
actually landed. Worth doing on the first run in a new repo.

## 7. Check status

```bash
scripts/status.sh
```

For every task this prints the herdr lifecycle state from `herdr agent get <name>`,
which agent kind actually ran, whether `status_file` exists and what it says,
whether the worktree is clean per `git status --porcelain`, and the last cached
VERIFY and CRITIQUE results. A task is ready for the gate only when the first
three line up: herdr `idle` or `done`, `status: success`, and a clean tree. An
agent name ending in `*` fell back to codex.

The output ends with a **NEXT** block: one prescriptive command per task
(`logs.sh`, `verify.sh`, `critique.sh`, or `review.sh`). Follow it rather than
re-deriving the state yourself — that is the point of the block. It never runs
the verify check or the critique itself, so reading status stays free and never
spawns an agent.

`blocked` means something needs a human despite auto-approve. Read its logs and
decide, rather than looping retries.

`unreachable` for a task you just launched means the script is asking herdr the
wrong question, not that the agent died. Check `herdr agent list` before
relaunching anything. Same for `n/a` under CLEAN, which is an unresolved worktree
path rather than a clean tree.

## 8. Verify: the deterministic half of the gate

Once a task shows herdr `idle`/`done` + `success` + clean, run the gate before
you read a single line of its diff:

```bash
scripts/verify.sh <task-name>
```

This runs the task's `verify` command inside its worktree, or an auto-detected
test/build command when the task set none, and caches the result so `status.sh`
can show it. `pass` and `skipped` move the task on to the critique; `fail` sends
it back to the agent instead (section 4 step 7), and you never spend tokens
reading a diff that does not build. `skipped` means no check could be found —
treat that diff with the extra care of an unverified one.

This is the deterministic half of "verify at egress". It is what lets the swarm
run wide without you hand-checking every mechanical failure. It answers "does it
still build", and nothing else.

## 9. Critique: the judgement half of the gate

```bash
scripts/critique.sh <task-name>
```

A passing test suite says nothing about whether the agent did what it was asked.
That question is what actually costs you a full diff read, so put a cheap model
on it first. `critique.sh` runs one-shot print mode on the Antigravity Gemini
pool, hands the reviewer the task's original prompt plus the diff against its
base, and asks for a verdict against a fixed rubric: completeness, scope
(deleted tests, disabled checks, unrelated edits), correctness, safety, tests.
Style and refactor opinions are explicitly out of scope, because they generate
noise rather than blockers.

The verdict lands in `.herdr-swarm/<name>.critique.json` and shows up in the
CRITIQUE column of `status.sh` and at the top of `review.sh`:

| verdict | meaning | what to do |
|---------|---------|------------|
| `pass` | no blocker or major issue found | go read the diff (section 10) |
| `revise` | real problems the same agent can fix | bounce the issue list back, section 4 step 7 |
| `reject` | wrong approach, or dangerous | take it to the user; re-prompting will not fix it |
| `skipped` | no diff, or no reviewer binary available | read the diff yourself |
| `unparseable` / `error` | the reviewer misbehaved or crashed | read the diff yourself; this is not a verdict |

Exit status is 0 for everything except `revise` and `reject`, which exit 1, so a
tooling failure never wedges the pipeline — it just falls through to your read.

It runs on `gemini-3.8-flash-high` by default and falls back to `codex`, then to
classic `gemini`, the same way `launch.sh` does. Override with
`HERDR_SWARM_CRITIQUE_MODEL`, `HERDR_SWARM_CRITIQUE_KIND`,
`HERDR_SWARM_CRITIQUE_EFFORT`, `HERDR_SWARM_CRITIQUE_TIMEOUT` (seconds, default
600) and `HERDR_SWARM_CRITIQUE_DIFF_LINES` (default 1500, past which the diff in
the brief is truncated and the reviewer is told to read the repo itself).

The critique is a filter, never an approval. See the safety notes.

## 10. Review before merging

For each task the gate cleared:

```bash
scripts/review.sh <task-name>
```

This prints which model produced the work, whether it fell back to codex, the
verify status, the critique verdict and its issues, the commit log and diffstat
for `<branch>` against its base, and the worktree path. Read the actual diff with
`git -C <worktree_path> diff <base>...` before deciding. This is the
human-in-the-loop step even though Claude is running it, and it is what makes
auto-approve acceptable in the first place. Then follow section 4 steps 7 to 9:
fix by re-prompting if needed, at most twice, present the result and ask the user
how to merge, and once they decide, clean up the workspace, branch and scratch
state and verify that the cleanup actually happened.

## 11. Read logs

```bash
scripts/logs.sh <task-name> [lines]
```

This wraps `herdr agent read <name> --source recent-unwrapped --lines <N>`,
defaulting to 150. Use `recent-unwrapped` rather than `visible`, because it is not
limited to the current terminal viewport.

## 12. Trace mode: see what the swarm actually ran

Every script takes `--trace`. It can go anywhere in the arguments, before or
after the positional ones:

```bash
scripts/launch.sh --trace tasks.json
scripts/critique.sh fix-auth-bug --trace
```

For a whole session, set `HERDR_SWARM_TRACE=1` instead and drop the flag;
`--no-trace` on a single call overrides it. Off by default, and when it is off it
costs nothing — no subprocesses run and no file is created.

Every external call the swarm makes gets one line in
`$HERDR_SWARM_STATE_DIR/trace.log` (`.herdr-swarm/trace.log` by default):
timestamp, which script wrote it, the task, the event, and the command with its
exit code. The log lives in the state dir and never inside a worktree, because
writing into a worktree would flip its CLEAN column to `DIRTY` and break the
review gate. It is append-only; delete it yourself when it gets long.

```
2026-09-09T00:02:31Z critiq  demo    quota.read     agy -p /usage -> rc=0 (80% 42% )
2026-09-09T00:02:31Z critiq  demo    reviewer.pick  agy for model gemini-3.8-flash-high
2026-09-09T00:02:32Z critiq  demo    verdict.parse  revise (1 issues, confidence high)
```

The source tags are `launch`, `status`, `verify`, `critiq`, `review` and `logs`.
A task column of `-` means the event belongs to the run rather than one task.
The events worth knowing:

| script | events |
|--------|--------|
| `launch` | `run.start`, `quota.check`, `kind.resolve` (which model and whether it fell back), `base.pin`, `herdr.exec`, `worktree.ready`, `agent.start`, `agent.ready`, `prompt.submit` / `prompt.landed` / `prompt.stalled` / `prompt.lost`, `state.write`, `run.end` |
| `status` | `poll`, one compact line per task |
| `verify` | `cmd.resolve` (the command and whether it came from `tasks.json` or auto-detection), `cmd.exec` |
| `critiq` | `base.resolve`, `diff.collect`, `quota.read`, `reviewer.pick`, `reviewer.exec`, `verdict.parse`, `verdict.write` |
| `review` | `base.resolve`, `review.read` |
| `logs` | `herdr.exec` |

Reach for this when something looks like success but is not: a prompt herdr
accepted that the agent never saw (`prompt.stalled` / `prompt.lost`), a quota
read that failed open (`quota.read` with a non-zero rc or "no percentages"), or a
base ref that resolved to the branch tip and made the diff look empty
(`base.resolve`, `diff.collect`). Those are the failures that do not raise an
error anywhere else.

Prompts are never written to the log, only their byte count. Keep it that way if
you extend the tracing: the log is meant to stay safe to paste into a chat.

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
- **Both halves of the gate filter; neither approves.** A verify `pass` means the
  tests ran, not that the change is correct or safe. A critique `pass` means one
  cheap model, reviewing another model's work, found nothing — weaker evidence
  than the test run, and produced by exactly the kind of system this whole gate
  exists to distrust. The diff read in section 10 is still the only thing between
  an auto-approving agent and the user's branch. Do not skip it because verify
  passed, the critique passed, or a status file says success.
- Treat a critique `reject` as information, not authority, in the other direction
  too. It can be wrong. Read the diff before you throw work away on its say-so.
- Report when a task fell back to codex. The user picked a model for a reason, and
  a security review done by `gpt-5.6-luna` instead of `claude-opus-4-6-thinking`
  is a different piece of work.
- If `status.sh` shows `blocked` for longer than expected, a human is needed. That
  is not a reason to add more auto-approve flags.
