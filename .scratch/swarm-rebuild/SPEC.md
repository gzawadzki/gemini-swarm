# Spec: make the swarm define tasks it can finish

**Status:** ready-for-agent
**Tracker:** local, this directory. Tickets land in `.scratch/swarm-rebuild/issues/`.
**Depends on:** commit `bc6e428` (P0: junction, split timeout fields, brief-as-file,
branch rollback, honest launch tests).
**Primary source:** `.scratch/swarm-rebuild-findings.md`
**ADRs:** [0001](../../docs/adr/0001-junction-not-installer.md),
[0002](../../docs/adr/0002-required-files-and-pitfalls.md),
[0003](../../docs/adr/0003-flash-high-is-the-default.md),
[0004](../../docs/adr/0004-split-the-timeout-field.md).
Vocabulary: [CONTEXT.md](../../CONTEXT.md).

## Problem Statement

The operator delegates work to the swarm and gets back diffs that cost more to fix
than the work saved. Two complaints, one cause.

Tasks are badly defined. A task says "improve error handling" instead of naming what
has to change, so the agent invents the specification as it goes: dead branches built
from prompt conditions no input satisfies, prompt steps pasted into the source as
numbered comments, compatibility shims nobody asked for. The egress gate cannot catch
any of it, because the critique grades the diff against the task text and the task
text says nothing measurable.

Runs take a long time, and the agent is not where the time goes. Measured on a real
run: the agent worked 9.5 minutes, verify took 95 seconds, the critique about a
minute, and the whole thing took 20 minutes from launch to merge. The rest went into
the orchestrator working around the tool — two failed launches, a leftover branch
blocking the retry, cleanup by hand.

The cause behind the badly defined tasks is not a missing instruction. SKILL.md
already tells the orchestrator to be specific. The cause is that the orchestrator
writes a task **without reading the code it will touch**, so the agent has to
discover the traps, and every discovery comes back as a bounced verify or a diff the
operator has to unpick. The counter-example settles it: one four-part ticket landed
first time, in 9.5 minutes, zero bounces, because three minutes of reading produced
three named pitfalls in the prompt.

Two smaller problems make each run harder to trust than it should be. The
deterministic half of the gate can pass a diff it never ran — an editable install
pins imports to the main checkout, so a test inside a worktree can exercise the code
from `main` — and cleanup deletes the run's task config, so nothing is left to learn
from afterwards.

## Solution

Make a task's definition carry the recon that makes it finishable, and enforce that
in the schema rather than in prose.

A task declares the files it may touch and the pitfalls found by reading them. The
launch step refuses to start a task that declares neither. The pitfalls reach the
agent inside the brief as constraints, with an explicit instruction not to restate
them as comments, and reach the reviewer as extra grading criteria. Declared scope is
reported after the fact rather than enforced, because a false bounce costs more than
a line to read.

Verify stops being able to lie: it confirms the code it tested resolves inside the
worktree, and fails when it does not. Every run archives its own evidence before
cleanup removes anything, so the next argument about what went wrong is settled from
a record instead of memory.

The documentation gets restructured so the part about defining tasks is findable: a
thin operational document plus reference files loaded on demand, with the
prompt-writing rules living next to the schema they constrain instead of three
sentences at the top of a 694-line file.

The operator's measure of a good run, taken from the run that worked: one slice per
task, 15 minutes or less of agent time, at most one bounce off the gate, diff of
about 400 lines or fewer, suite green without editing tests, cleanup with no manual
step.

## User Stories

### Defining a task

1. As an orchestrator, I want the task schema to require the files a task may touch, so that I cannot write a task without having decided what it changes.
2. As an orchestrator, I want the task schema to require the pitfalls I found in the code, so that the step I used to skip is the step the tool will not let me skip.
3. As an orchestrator, I want the launch step to refuse a task with no declared pitfalls, so that a paragraph of guidance is replaced by a gate I cannot walk past.
4. As an orchestrator, I want to declare an empty pitfall list explicitly when the code really has no traps, so that "I checked and found nothing" stays distinguishable from "I did not look".
5. As an orchestrator, I want the refusal message to tell me to read the code first, so that the fix is obvious at the moment I hit the error.
6. As an orchestrator, I want one task's validation failure not to abandon the tasks after it, so that a typo in the third task does not cost me the fourth and fifth.
7. As an orchestrator, I want a written test of whether a unit of work is a slice at all, so that I can tell before launching whether it belongs in the swarm or stays with me.
8. As an orchestrator, I want that test to name its thresholds — roughly 15 minutes of agent time, a file list, one verify command, pitfalls written down — so that it is a check and not a sentiment.
9. As an orchestrator, I want the rules for writing a prompt to sit next to the schema they constrain, so that I read them while filling the fields in.
10. As an orchestrator, I want a rule against pasting prompt steps into the code as comments, so that the numbered-step comments in previous diffs stop recurring.
11. As an orchestrator, I want a rule against compatibility shims and aliases the task did not ask for, so that a port stops leaving "ported from" scaffolding behind.
12. As an orchestrator, I want a rule that steps in a prompt are requirements rather than a sequence to mirror in the source, so that the agent stops reproducing my ordering as code structure.
13. As an orchestrator, I want a rule that a verify command must not reinstall the package, so that a task cannot repoint an editable install at its own worktree.
14. As an orchestrator, I want a rule to name concrete symbols rather than generalities, so that the verify command can grep for them.
15. As an orchestrator, I want a rule that a task should aim at a diff of about 400 lines, so that the diff stays inside what I will actually read.
16. As an orchestrator, I want to be told to split a task I estimate above that, so that the size decision happens before the work rather than after.

### Handing the task to the agent

17. As an agent, I want the pitfalls in my brief under a heading that says they are constraints, so that I treat them as requirements instead of background.
18. As an agent, I want to be told explicitly not to restate the pitfalls as comments or docstrings, so that the brief does not leak into the source.
19. As an agent, I want the declared file list in my brief, so that I know where the task expects its changes.
20. As an orchestrator, I want the constraints section generated rather than hand-written per task, so that the anti-restate wording cannot be forgotten.
21. As an operator, I want the brief to stay a file with a one-line pointer, so that a long task description keeps arriving intact.

### Grading the diff

22. As a reviewer, I want each declared pitfall as a grading criterion, so that I can say which ones the diff avoided rather than judging overall vibe.
23. As a reviewer, I want the declared scope in my brief, so that I can flag changes outside it and say whether each was necessary.
24. As an operator, I want the critique verdict to record which pitfalls it checked, so that a pass tells me what was actually examined.
25. As an operator, I want the gate to keep filtering rather than approving, so that a passing critique never reads as permission to merge — a real defect passed both halves once already.
26. As an operator, I want reading the diff myself to stay a required step, so that the comment-no-longer-describing-the-code class of defect still gets caught.

### Trusting the deterministic half

27. As an operator, I want verify to confirm the code it tested resolves inside the worktree, so that a green result cannot come from the main checkout.
28. As an operator, I want that check to fail rather than warn, so that a gate which silently tested the wrong tree stops being worse than no gate.
29. As an operator, I want an environment escape hatch for projects where the check makes no sense, so that a false hard failure does not block a legitimate run.
30. As an operator, I want a project where soundness cannot be established to report skipped, so that "I could not tell" never renders as pass.
31. As an operator, I want the failure message to name what resolved where, so that I can tell an editable-install problem from a genuine test failure.

### Watching a run

32. As an operator, I want changes outside the declared files reported in the status view, so that scope drift is visible without reading the diff.
33. As an operator, I want the same report before merging, so that the last thing I see is what the task touched beyond what it declared.
34. As an operator, I want out-of-scope changes not to block the task, so that a new test file or a package import does not cost a bounce.
35. As an operator, I want a diff far above the 400-line guideline called out after the fact, so that I learn the task was too wide and split the next one.
36. As an operator, I want that call-out to be advisory, so that work already done is not thrown away over an estimate I got wrong.
37. As an operator, I want the status and review views to agree about scope, so that I am not comparing two different answers.

### Keeping the evidence

38. As an operator, I want every run archived under its own timestamp, so that a post-mortem has a record instead of my memory.
39. As an operator, I want the archive to hold the task config, so that I can see exactly how a task was defined.
40. As an operator, I want the archive to hold the trace, so that the order in which things failed is recoverable.
41. As an operator, I want the archive to hold each task's diff and the verify and critique verdicts, so that "the gate passed this" is checkable later.
42. As an operator, I want the archive to record the skill's commit and whether its tree was dirty, so that an odd run is attributable to a version.
43. As an operator, I want cleanup to archive before it removes anything, so that the tool stops deleting its own evidence.
44. As an operator, I want archiving not to depend on the rest of cleanup succeeding, so that a pane that will not close does not cost me the record.
45. As an operator, I want the archive kept outside the repo I am working in, so that a run does not dirty the project it ran against.
46. As an operator, I want to be told where the archive went, so that I do not have to go looking for it.

### Finding things in the docs

47. As an orchestrator, I want the skill document to be thin and operational, so that the flow is readable without loading everything the skill knows.
48. As an orchestrator, I want the model table, quota rules, gate details and known bugs in reference files, so that I load them when the question is actually about them.
49. As an orchestrator, I want the task-definition material in one reference file, so that the most load-bearing part of this skill stops being scattered between an intro paragraph and a schema list.
50. As an orchestrator, I want each reference file pointed at from the step that needs it, so that the thin document stays navigable.
51. As an operator, I want the docs to name cleanup as an ordinary step, so that cleanup stops being done by hand.
52. As an operator, I want the known Windows and editable-install traps recorded in a troubleshooting reference, so that the next run does not rediscover them.

### Not losing the fixes again

53. As a maintainer, I want the fake binaries shared by one test harness, so that a herdr change is fixed in one place instead of four.
54. As a maintainer, I want every new behaviour asserted against what the fake binary received, so that a test cannot pass while the behaviour is broken — the previous launch test asserted on stdout wording and stayed green through two reverted fixes.
55. As a maintainer, I want verify covered by tests, so that the worktree-resolution check cannot quietly stop working.
56. As a maintainer, I want status covered by tests, so that the scope and overdue reporting cannot quietly stop working.
57. As a maintainer, I want the schema validation covered by tests, so that the required fields cannot become optional again by accident.
58. As a maintainer, I want the harness extraction to leave every existing assertion passing unchanged, so that a refactor of the tests is not a rewrite of what they check.

## Implementation Decisions

**Task schema: `files` and `pitfalls` required.** Both are arrays. The launch step
validates before it creates a worktree, and skips a task that fails with an error
naming the missing field, in the same shape as the existing agent-name and repo
checks: one task failing validation must not abandon the tasks after it. An empty
`pitfalls` array is accepted with a warning, so a deliberate "no traps here" is
expressible and a forgotten field is not (ADR 0002).

**Brief composition.** The brief gains a constraints section carrying the pitfalls
and the declared file list, with the instruction not to restate them in comments or
docstrings. The section is generated from the fields rather than written per task, so
the anti-restate wording cannot be dropped. Brief delivery stays as P0 left it: a
file plus a one-line pointer.

**Critique criteria.** The critique receives the pitfalls and the declared scope and
grades against them in addition to the task text. Its verdict records which pitfalls
were examined, so a `pass` is inspectable rather than a bare word. The critique stays
a filter; nothing here changes the rule that it never approves a merge.

**Scope reporting, not enforcement.** A shared reader computes the files a task's
diff touched outside its declared list. Status and review both report it; neither
fails on it. The reader belongs in the shared library with the other verdict and
state readers, so the two call sites cannot disagree.

**Verify soundness check.** After the verify command runs, verify establishes that
the code under test resolves inside the worktree, and treats a resolution outside it
as `fail`, naming the module and the path it came from. An environment variable
disables the check. The mechanism is language-specific and only Python is in evidence
so far, so it must degrade to `skipped` where soundness cannot be established, never
to a false `pass`.

**Run archive.** Every run gets a directory named by its launch timestamp, outside
any working repository, alongside the briefs the skill already keeps there. It holds
the task config, the trace, a status snapshot, and per task the diff, the verify
verdict and the critique verdict, plus the skill's commit and dirty-file list.
Cleanup writes the archive as its first action, before it closes agents or removes
worktrees, prints where it went, and does not make archiving conditional on the rest
of cleanup succeeding.

**Documentation split.** The skill document becomes thin and operational: the
operating model, the numbered flow, and a pointer from each step to the reference it
needs. Reference files cover task definition (schema, the slice test, the
prompt-writing rules), models and routing, accounts and quota, the gate, and
troubleshooting. Defaults follow ADR 0003. The prompt-writing rules move out of the
operating-model introduction and into the task-definition reference, next to the
schema they constrain.

**Test harness.** The fake `herdr`, `agy` and `pwsh` binaries and the assertion
helpers move into one shared harness the test files source. Existing tests migrate
onto it without changing what they assert. This mirrors the rule the skill already
applies to its own scripts: when herdr changes, fix one file, not four.

## Testing Decisions

**The seam.** One seam, already established and kept: run the real script as a
subprocess, with fake `herdr`, `agy` and `pwsh` ahead of it on `PATH`, inside a
throwaway git repository, and assert on what those fakes received and on the state
and verdict JSON the script wrote. No new seam is introduced, and no script grows a
test-only code path.

**What makes a good test here.** Assert on the arguments a fake binary actually
received, or on the JSON a script produced — never on the wording a script printed.
This is not a style preference. The previous launch test asserted that stdout
contained "sending prompt", which is printed whether or not the prompt reaches the
agent, so it stayed green while two fixes were reverted, and both came back as bugs
months later. A test that cannot distinguish working from broken is worse than no
test, because it is counted as coverage.

**Prior art.** The launch tests are the reference shape, including the scenarios
added in P0: the clamped timeout asserted against the argument herdr received, the
prompt asserted to be a one-line pointer carrying none of the brief, and the failed
start asserted to leave no branch behind. The cleanup tests show the same harness
driving a script whose decisions depend on git state.

**Coverage this spec adds.** Schema validation and brief composition extend the
launch tests. Critique criteria extend the critique tests. Archiving extends the
cleanup tests. Verify and status get test files that do not exist today: soundness
detection and its escape hatch for the former, scope and overdue reporting for the
latter. The harness extraction lands first, and its own test is that every existing
assertion still passes unchanged.

## Out of Scope

Deliberately untouched, because the evidence says they work: model selection beyond
the default change already made in ADR 0003, the codex fallback after both accounts
run dry, the two-account credential swap, worktree and branch isolation, and the
two-stage gate as a filter.

Rejected during grilling, not deferred:

- **Hard-failing a diff that leaves the declared files.** Legitimate strays exist,
  and a false bounce costs more than reading the line.
- **A hard limit on diff size.** The work is already written by then; bouncing it
  does not make it smaller.
- **Killing a task that passes its work budget.** It would cut a task three minutes
  from done. `OVERDUE` reporting is the whole mechanism.
- **Delegating recon to a cheap agent.** A hallucinated pitfall would enter the brief
  labelled as a verified fact. Recon stays with the orchestrator (ADR 0002).
- **An installer with a drift check.** Superseded by the junction (ADR 0001).

Also out of scope: publishing any of this to GitHub Issues, since the tracker for
this effort is local; and the orphaned worktree under `.claude/worktrees/` — clean,
on a branch already merged to main, removable at the operator's convenience.

## Further Notes

The ordering is not arbitrary. The harness extraction comes first because every later
ticket adds tests, and adding them to four divergent copies of the fakes is the
maintenance drag this spec is partly about. The documentation split comes last
because the earlier tickets change what the docs have to say; splitting first means
writing the reference files twice.

One risk carried forward from ADR 0001: Claude Code's skill discovery follows the
junction, confirmed in this session when the skill description updated to the repo's
version. If a future release stops following it, the whole spec reverts to editing a
copy that does not run, and the installer alternative comes back.

The soundness check rests on one observation, in one Python project, where a
`pythonpath` line in `pyproject.toml` happened to save the run. Treat the mechanism
as provisional: the requirement is that the gate can never report `pass` for code it
did not execute, and reporting `skipped` when it cannot tell is an acceptable answer.
