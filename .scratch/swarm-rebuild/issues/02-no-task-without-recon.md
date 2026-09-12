# 02 — A task cannot launch without recon

**What to build:** the orchestrator can no longer hand the swarm a task it has not
read the code for. A task declares the files it may touch and the pitfalls found by
reading them; the launch step refuses to start one that declares neither, and tells
the orchestrator to read the code first. Those pitfalls and that file list reach the
agent inside its brief, as constraints, with an explicit instruction not to restate
them in the source.

This is the centre of the whole effort. The measured counter-example is a four-part
ticket that landed first time, in 9.5 minutes, zero bounces, because three minutes
of reading produced three named pitfalls in the prompt. The guidance to "be specific"
already existed and did not work, so this ticket moves it from prose into the schema
(ADR 0002).

The reference material about defining a task lands with it: the schema, the test for
whether a unit of work is a slice at all, and the rules for writing a prompt. Those
rules constrain this schema, so they belong next to it — writing them later, during
the documentation split, would mean writing them twice.

**Blocked by:** 01 — One shared test harness for the fake binaries.

**Status:** done

- [x] The task schema requires `files` and `pitfalls`, both arrays.
- [x] The launch step validates them before creating a worktree, and skips a task
      that fails with an error naming the missing field.
- [x] A validation failure on one task does not abandon the tasks after it, matching
      how the existing agent-name and repo checks behave.
- [x] An empty `pitfalls` array is accepted with a warning, so "I checked and found
      nothing" stays expressible and distinguishable from a forgotten field.
- [x] The brief carries the pitfalls under a heading that states they are constraints
      to satisfy, plus the declared file list.
- [x] The brief tells the agent not to restate the pitfalls as comments or
      docstrings. Earlier diffs pasted prompt steps into the source verbatim,
      numbering and all, so this wording is load-bearing.
- [x] That section is generated from the fields rather than written per task, so the
      anti-restate wording cannot be dropped by an orchestrator in a hurry.
- [x] The example task config declares both fields in every task, and shows pitfalls
      specific enough to be checkable rather than placeholders.
- [x] A reference document covers the schema, the slice test and the prompt-writing
      rules, and the launch step of the skill document points at it.
- [x] The slice test names its thresholds: roughly 15 minutes of agent time, a
      declared file list, one verify command, pitfalls written down. A unit of work
      that cannot be described that way stays with the orchestrator.
- [x] The prompt-writing rules cover at least: name concrete symbols rather than
      generalities so the verify command can grep for them; do not paste prompt steps
      into the code as comments; do not add compatibility shims or aliases the task
      did not ask for; steps are requirements, not a sequence to mirror in the source;
      a verify command must not reinstall the package; aim at a diff of about 400
      lines and split anything estimated above it.
- [x] Tests assert that a task missing either field does not start, that the brief
      contains the pitfalls and the anti-restate instruction, and that the following
      task in the same config still launches.
