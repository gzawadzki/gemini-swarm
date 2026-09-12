# Reference: defining a task

Everything that decides whether a task comes back mergeable. Read it while you
fill the fields in, not afterwards.

The vocabulary here — task, slice, pitfall, brief, recon — is defined in
[CONTEXT.md](../../CONTEXT.md).

## Recon comes first

Read the code the task will touch before you write the task. Not the file tree,
the code: the functions it changes, their callers, the fixtures the tests use.

This is the step the schema now enforces, because guidance did not. The measured
counter-example is one four-part ticket that landed first time, in 9.5 minutes,
with zero bounces, because three minutes of reading produced three named traps in
the prompt. Tasks written without that reading came back with bounced verifies,
dead branches built from conditions no input satisfies, and prompt steps pasted
into the source as numbered comments. See
[ADR 0002](../adr/0002-required-files-and-pitfalls.md).

Recon is yours. Do not delegate it to a cheap agent: a hallucinated pitfall
enters the brief labelled as a verified fact.

## The slice test

A unit of work belongs in the swarm only if you can describe it as a **slice**.
All four, not three:

1. **Roughly 15 minutes of agent time.** If you estimate longer, it is more than
   one slice.
2. **A named list of files.** Not "the auth layer" — the paths.
3. **One `verify` command.** The narrowest check that proves the task worked,
   usually the test file it touched.
4. **Pitfalls written down.** The traps you found while reading. An honest empty
   list is allowed; an unread empty list is the failure this whole mechanism
   exists to stop.

Work that cannot be described that way stays with you. Splitting it until each
part can is the usual answer; keeping it is the other.

## Schema

Generate a JSON file shaped like [`tasks.example.json`](../../tasks.example.json).
The scripts depend on this schema, so do not invent another one.

```json
{
  "tasks": [
    {
      "name": "add-rate-limiter",
      "kind": "agy",
      "model": "gemini-3.8-flash-high",
      "repo": "/absolute/path/to/repo",
      "branch": "agent/add-rate-limiter",
      "prompt": "Add a token-bucket rate limiter middleware to src/api/middleware.py, with a unit test in tests/test_rate_limiter.py. Run the new test and make sure it passes.",
      "files": ["src/api/middleware.py", "tests/test_rate_limiter.py"],
      "pitfalls": [
        "Middleware order in src/api/app.py is load-bearing: the auth middleware sets request.state.user, so the limiter has to run after it to key on a user id.",
        "time.monotonic() is frozen by the freezegun fixture in conftest.py, so a bucket that refills off time.time() will look empty forever in tests."
      ],
      "args": [],
      "verify": "pytest -q tests/test_rate_limiter.py",
      "work_budget_ms": 900000
    }
  ]
}
```

### Required

- `name` — unique, lowercase, matching `[a-z][a-z0-9_-]{0,31}`, which is herdr's
  agent-name rule.
- `kind` — `gemini`, `agy` or `codex`.
- `repo` — absolute path to the main repository. `launch.sh` creates a worktree
  from it, so the agent never touches this path directly.
- `prompt` — the task itself. See [Writing the prompt](#writing-the-prompt).
- `files` — the files this task is expected to touch, as an array of paths
  relative to the repo. It reaches the agent in the brief as the expected scope.
  **Straying outside it is never an error**, because legitimate strays exist (a
  new test file, a package import) and a false bounce costs more than a line to
  read. An empty array is rejected: a task that may change nothing is not a task.
- `pitfalls` — the traps you found by reading, as an array of strings. They reach
  the agent as constraints in its brief. An empty array is accepted with a
  warning, so "I read it and found none" stays expressible and stays
  distinguishable from a forgotten field.

Every entry in either array is one non-empty string — one path, or one trap
written out. A task whose entries are anything else is skipped, with the
offending field named.

Two consumers are specified but not yet built: reporting the files a diff touched
outside `files` (ticket 04), and grading the diff against each pitfall
(ticket 03). Until those land, both fields act on the agent through the brief
only.

`launch.sh` validates `files` and `pitfalls` before it creates a worktree, and
skips a task that fails with an error naming the missing field. The tasks after
it still launch.

### Optional

- `branch` — the task's branch, `agent/<name>` by default. It branches from the
  repo's current `HEAD` unless `base` is set.
- `base` — an explicit base ref instead of `HEAD`.
- `model`, `effort` — apply to `agy` and `codex`, not to `gemini`. Most agy slugs
  already encode the effort, so `effort` is usually unnecessary there; for codex
  it becomes `-c model_reasoning_effort="<effort>"`. Defaults follow
  [ADR 0003](../adr/0003-flash-high-is-the-default.md).
- `args` — extra CLI flags. `launch.sh` injects the auto-approve flag and the
  model flags itself, so add only flags beyond those.
- `verify` — the shell command `verify.sh` runs inside the worktree as the
  deterministic half of the gate. Omit it and `verify.sh` tries to auto-detect
  one (npm/yarn/pnpm `test`, `pytest`, `cargo test`, `go test`, a `test:` Make
  target); finding nothing it reports `skipped` rather than blocking. Prefer
  setting it: a scoped command is faster and less flaky than a full suite.
- `ready_timeout_ms` — how long herdr waits for the agent's TUI to accept input,
  default 60000. **herdr rejects anything above 300000** with
  `invalid_agent_timeout`, which fails the launch outright, so `launch.sh` clamps
  it and warns. The old name `timeout_ms` still parses, with a warning.
- `work_budget_ms` — how long you expect the task to take, default 900000.
  **Nothing enforces it.** `status.sh` reads it to print `OVERDUE` once a task
  passes it without writing a result file, which is the only signal that tells a
  hung agent from a thinking one. A task needing far more than 15 minutes is a
  task to split, not a number to raise. See
  [ADR 0004](../adr/0004-split-the-timeout-field.md).

## Writing the prompt

`critique.sh` grades the diff against this text, so a prompt that says nothing
measurable gives the reviewer nothing to measure. These rules constrain the
schema above; they are why the fields are shaped the way they are.

- **Name concrete symbols, not generalities.** "Add a retry with backoff to
  `upload()` in `src/storage.py` and cover it in `tests/test_storage.py`" can be
  checked and grepped for. "Improve error handling" cannot.
- **Do not paste the prompt into the code.** The brief already tells the agent
  not to restate the task or the pitfalls as comments, docstrings or test names —
  earlier diffs reproduced prompt steps in the source verbatim, numbering
  included. Commit messages are exempt: explaining a change there is the point.
- **Steps are requirements, not a sequence to mirror.** A four-step prompt does
  not mean four functions in that order.
- **No compatibility shims or aliases the task did not ask for.** A port that
  leaves `load_yaml_config = load_config` behind has added a caller-less symbol
  and called it caution. Say so explicitly when porting.
- **A `verify` command must not reinstall the package.** `pip install -e .` in a
  verify command repoints an editable install at the agent's worktree, or worse
  leaves the tests importing the main checkout — a gate that passes code it never
  ran.
- **Aim at a diff of about 400 lines.** Above that you stop reading it properly,
  which is the point of the number. Split anything you estimate above it, before
  the work rather than after.
- **Do not write the commit discipline or the result-file contract.** `launch.sh`
  generates those, along with the constraints section. Do not put the
  auto-approve flag in the prompt text either.

## What the agent receives

`launch.sh` writes a brief to `~/.herdr/briefs/<name>.md` and sends the agent a
one-line pointer at it. The indirection is load-bearing: `herdr agent prompt`
only reliably delivers one short line, and a multi-line brief pasted into the
input box comes back `agent_prompted` with the pane empty — indistinguishable
from a launched task nobody has reviewed yet.

The brief is the prompt plus three generated sections:

- **Constraints** — the pitfalls, stated as requirements, with the instruction
  not to restate them in the source.
- **Files this task is expected to touch** — the declared list, described as the
  expected scope rather than a lock.
- **Ground rules and the result file** — worktree isolation, commit discipline,
  and the JSON result file the agent writes as its last action.

Those sections are generated from the fields rather than written per task, so the
anti-restate wording cannot be dropped by an orchestrator in a hurry.
