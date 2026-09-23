# Reference: the egress gate

Two stages stand between an auto-approving agent's diff and the merge handoff:
`verify.sh`, which is deterministic, and `critique.sh`, which first uses Jev's
typed risk signals and falls back to a generative reviewer. Jev may approve a
strictly bounded result without a full diff read. No gate result merges code.

The vocabulary here — gate, soundness, stray — is defined in
[CONTEXT.md](../../CONTEXT.md).

## Stage 1: verify, the deterministic half

```bash
scripts/verify.sh <task-name>
```

Runs the task's `verify` command inside its worktree, or an auto-detected
test/build command when the task set none, and caches the result so `status.sh`
can show it without re-running anything. `pass` and `skipped` move the task on to
the critique; `fail` goes back to the agent, and no tokens are spent reading a
diff that does not build. `skipped` means nothing was proven — treat that diff
with the extra care of an unverified one.

Auto-detection recognises npm/yarn/pnpm `test`, `pytest`, `cargo test`,
`go test`, and a `test:` Make target. Finding nothing, it reports `skipped`
rather than blocking, so an unknown stack never wedges the pipeline.

### A green command is not yet a pass

After the command succeeds, verify asks where the code under test actually
resolved from. An editable install pins imports to a fixed path, so a suite run
inside a worktree can import the package from the main checkout and go green on a
diff it never touched. That happened here, and one project's `pythonpath` line
saved it by accident. A gate that can test the wrong tree is worse than no gate,
because it is counted as evidence.

| resolution | status | meaning |
|------------|--------|---------|
| inside the worktree | `pass` | the tests ran on this task's code |
| outside it | `fail` | naming the module and the path. **Do not re-prompt the agent**: the diff may be fine and the environment is what lied |
| could not be established | `skipped` | the command passed, but which tree ran it is unproven, so it is not a pass |
| not checked | `pass` | only with `HERDR_SWARM_NO_SOUNDNESS=1`, and the result records `"soundness": "disabled"` |

The mechanism is provisional and deliberately narrow: it resolves the module
named by `pyproject.toml` and checks the path. Only Python is in evidence, so
every other project reports `skipped` rather than assuming soundness. Widening it
means adding a positive check per ecosystem — never treating a language as safe
because the trap has not been seen there yet. The requirement is the guarantee,
not the technique. The failure mode this exists for is written up in
[troubleshooting](troubleshooting.md#tests-that-pass-against-another-checkout).

## Stage 2: critique, the judgement half

```bash
scripts/critique.sh <task-name>
```

A passing test suite says nothing about whether the agent did what it was asked.
That question is what actually costs a full diff read, so `critique.sh` starts
with a narrow Jev decision and escalates anything it cannot safely clear.

### Jev modes and automatic acceptance

Jev runs when `TYPESAFE_API_KEY` or `OPENROUTER_API_KEY` is present. The
TypeSafe route wins when both are set. The request asks separate Noul questions
whose answers are probabilities that a bad condition is true:

- a material requirement is missing;
- the diff contains a concrete correctness defect;
- it changes unrelated behavior;
- it introduces a security or destructive-operation risk;
- it weakens an existing check;
- changed behavior lacks a reasonable regression test;
- each declared pitfall is violated.

Three operational modes are supported:

- **`shadow` (default)**: Jev evaluates the typed risk questions and records the
  signals and maximum risk in the verdict and state archive, but always passes
  the diff through to the generative reviewer. Shadow mode remains the default
  until a labeled local evaluation demonstrates an acceptable false-accept rate.
- **`auto_accept` (explicit opt-in)**: allows Jev to approve verified, clean,
  bounded diffs without starting a generative reviewer when every risk signal is
  at or below `HERDR_SWARM_JEV_ACCEPT_MAX` (`0.10` by default). Opt in by setting
  `HERDR_SWARM_JEV_MODE=auto_accept` or `HERDR_SWARM_JEV_AUTO_ACCEPT=1`.
- **`disabled`**: skips Jev calls entirely (`HERDR_SWARM_JEV_MODE=disabled` or
  `HERDR_SWARM_JEV_AUTO_ACCEPT=0`).

Automatic acceptance requires explicit opt-in, verify `status == pass` AND
verify `soundness == sound` (pass alone cannot authorize Jev, e.g. when soundness
is disabled via `HERDR_SWARM_NO_SOUNDNESS=1`, unknown, or unsound), a clean
worktree, a complete diff, readable scope data, no strays, no oversize report,
and no protected paths such as credentials, authorization, security, permissions,
CODEOWNERS, CI workflows, or environment-secret files. These are hard
preconditions, not additional model questions.

Malformed responses, request failures, high risk, missing keys, and failed
preconditions all fall through to the generative reviewer. They do not create a
false pass. The exact request and response are retained as
`<name>.critique.jev-request.json` and `<name>.critique.jev-response.json`; the
verdict records the mode (`shadow`, `auto_accept`, or `disabled`), route, model,
threshold, maximum risk, and every signal. In shadow mode, `auto_accepted` is
`false` and Jev risk signals are recorded alongside the generative reviewer's
findings. The API key is supplied through a permission-restricted temporary curl
config, not the command line or trace.

### Generative fallback

The fallback runs one-shot print mode on the Antigravity Gemini pool, hands the
reviewer the task's original prompt plus the diff against its base, and asks for
a verdict against a fixed rubric: the declared pitfalls, completeness, scope
(deleted tests, disabled checks, unrelated edits), correctness, safety, tests.
Style and refactor opinions are explicitly out of scope, because they generate
noise rather than blockers.

**The declared pitfalls are the first thing it judges.** Each one from the task
config is numbered in the reviewer's brief as a criterion, and the reply carries a
`pitfalls_checked` entry per pitfall saying whether the diff respected it,
violated it, or whether it did not apply. The verdict file resolves those numbers
back to the pitfall text and records `pitfalls_declared`, so a later reader can
tell a thorough pass from a shallow one without the task config beside it. This
is the fix for a real miss: a diff where a translated comment stopped describing
the code one line below it came back `pass`, `confidence: high`, "completely and
correctly implemented", because the reviewer had nothing specific to look for.

The declared `files` go in as a scope criterion: the generative reviewer flags
every change outside the list and says whether each was necessary. It reports,
it does not fail — a new test file or a package import is a legitimate stray.
For Jev automatic acceptance, any stray instead forces this fallback.

A reply that marks a pitfall `violated` while returning `pass` contradicts itself
and the brief it was given, so `critique.sh` downgrades it to `revise` and says
why. The reviewer's own word is kept as `reviewer_verdict`, so the downgrade is
auditable rather than a quiet rewrite.

| verdict | meaning | what to do |
|---------|---------|------------|
| `pass` with `auto_accepted: true` | Jev cleared every typed risk under all hard preconditions | inspect the merge handoff; a full diff read is optional |
| ordinary `pass` | the generative reviewer found no blocker or major issue | go read the diff |
| `revise` | real problems the same agent can fix | bounce the issue list back |
| `reject` | wrong approach, or dangerous | take it to the user; re-prompting will not fix it |
| `skipped` | no diff, or no reviewer binary available | read the diff yourself |
| `unparseable` / `error` | the reviewer misbehaved or crashed | read the diff yourself; this is not a verdict |

Exit status is 0 for everything except `revise` and `reject`, which exit 1, so a
tooling failure never wedges the pipeline — it falls through to your read.

### The reviewer is a different model

A model grading its own output shares its own blind spots. When the task's
`model` in `state.json` is the critique model, `critique.sh` reviews on
`HERDR_SWARM_CRITIQUE_ALT_MODEL` instead (default `gemini-3.1-pro-high`, still on
the Gemini pool). The verdict file records `worker_model` and `independent`. The
one case this cannot avoid is a codex task critiqued by codex while the
reviewer is also Codex; the script warns and writes `"independent": false`. Tell
the user when that happens, and weigh that `pass` as the self-review it is.

### Plugins are off for every codex the swarm starts

Worker or reviewer, every codex runs with `--disable plugins`, so user plugins
such as caveman cannot inject a SessionStart hook that changes how it writes the
result file, commit messages or the verdict JSON. Per-plugin
`-c plugins."x".enabled=false` overrides do not work for this; they were measured
to leave the prompt unchanged. `~/.codex/AGENTS.md` still loads. Set
`HERDR_SWARM_CODEX_PLUGINS=1` to keep plugins on.

### Overrides

| variable | default | effect |
|----------|---------|--------|
| `TYPESAFE_API_KEY` | unset | use `https://api.typesafe.ai/v1/systemone`; preferred when both keys exist |
| `OPENROUTER_API_KEY` | unset | use `https://openrouter.ai/api/alpha/decisions` when no TypeSafe key exists |
| `HERDR_SWARM_JEV_MODE` | `shadow` | `shadow` records signals and sends diffs to generative review; `auto_accept` allows automatic pass; `disabled` skips Jev |
| `HERDR_SWARM_JEV_AUTO_ACCEPT` | `0` | `1` explicitly opts in to automatic acceptance (`auto_accept`); `0` disables |
| `HERDR_SWARM_JEV_ACCEPT_MAX` | `0.10` | maximum accepted probability for every bad-condition signal; must be in `[0, 0.5)` |
| `HERDR_SWARM_JEV_MODEL` | route default | override `jev-latest` or `~typesafe/jev-latest` |
| `HERDR_SWARM_JEV_TIMEOUT` | `60` | request timeout in seconds |
| `HERDR_SWARM_JEV_URL` | route default | endpoint override, primarily for a compatible gateway or tests |
| `HERDR_SWARM_CRITIQUE_MODEL` | `gemini-3.8-flash-high` | the reviewer model |
| `HERDR_SWARM_CRITIQUE_ALT_MODEL` | `gemini-3.1-pro-high` | used when the default would review its own work |
| `HERDR_SWARM_CRITIQUE_KIND` | auto | force `pi`, `codex` or `gemini` |
| `HERDR_SWARM_CRITIQUE_EFFORT` | `medium` | reasoning effort |
| `HERDR_SWARM_CRITIQUE_TIMEOUT` | `600` | seconds |
| `HERDR_SWARM_CRITIQUE_DIFF_LINES` | `1500` | past this the diff in the brief is truncated and the reviewer is told to read the repo itself; the verdict records `"diff_truncated": true`, so a confident pass over a diff nobody saw in full is visible afterwards |
| `HERDR_SWARM_NO_SOUNDNESS` | unset | `1` skips the resolution check in stage 1 |

## Scope and size, reported by both views

`status.sh` and `review.sh` print the same two advisory findings, from one reader
so the two views cannot disagree:

- **Strays** — files a task's diff touched that no entry in its declared `files`
  covers. Usually legitimate: a new test file, a package import. Read the line
  and move on.
- **Size** — the diff's added-plus-deleted lines when it ran well past the
  400-line aim. The call-out threshold sits half again above the aim, so an
  ordinary task that lands a little over stays quiet: a report that fires on
  well-sized work is a report nobody reads. `HERDR_SWARM_DIFF_LINES` moves the
  aim and the threshold follows it.

Neither fails the generative review. Either finding does block Jev automatic
acceptance and routes the diff to that reviewer. An oversized diff is already
written by the time anyone sees it, so the call-out is also useful for the next
task.

## After the gate: the optional trim review

```bash
scripts/trim.sh <task-name>
```

Run this on demand, when a diff that already passed the critique **and your own
read** looks bigger than the task needed. A cheap model
(`HERDR_SWARM_TRIM_MODEL`, default the critique model) reads the diff for
overengineering only: single-use abstractions, options nobody sets,
generalisation the task did not ask for, re-implemented helpers, dead code. It
writes suggested cuts to `.herdr-swarm/<name>.trim.json`, and `review.sh` lists
them afterwards.

It is advice, not a gate. It always exits 0, never judges correctness or safety,
never edits the worktree, and is told not to cut input validation, I/O error
handling or tests. Order matters: correctness first, trimming second, commit
last. Do not run YAGNI as an always-on filter; applied to every task it pushes
agents into cutting corners that matter.

## What the gate does not do

- A verify `pass` means the tests ran, not that the change is correct or safe.
- An ordinary generative critique `pass` means one cheap model, reviewing another
  model's work, found nothing; it does not replace a diff read.
- Jev automatic acceptance is a bounded policy decision, not proof that the code
  is correct. Protected, large, dirty, incomplete, or out-of-scope changes cannot
  take that path.
- A critique `reject` is information, not authority. It can be wrong. Read the
  diff before throwing work away on its say-so.
- A trim suggestion is not a finding. Never apply cuts without reading them.

The user-controlled merge handoff is still the only thing between an
auto-approving agent and the user's branch. The scripts never auto-merge.
