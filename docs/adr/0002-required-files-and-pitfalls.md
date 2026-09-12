# ADR 0002: `files` and `pitfalls` are required fields

**Date:** 2026-09-12
**Status:** accepted, implemented in `launch.sh`

## Context

Tasks were badly defined, and the visible symptom was a missing acceptance
criterion: `critique.sh` grades a diff against the task text, so "improve error
handling" gives it nothing to measure.

The cause sits one step earlier. The orchestrator wrote tasks without reading the
code they would touch, so the agent had to discover the traps itself — and its
discoveries came back as bounced verifies, invented dead code
(a `val_recoverable` branch built from a prompt condition no input satisfies) and
prompt steps pasted into the source as numbered comments.

The counter-example is decisive. One four-part ticket — per-country seed offsets,
CLI help derived from a profile cycle, comment translation, golden tests off
limits — landed first time, in 9.5 minutes, with zero bounces, because the
orchestrator spent three minutes reading the code first and wrote the three traps
it found into the prompt.

SKILL.md already said "write it specifically enough to be checkable". Guidance was
not the missing piece.

## Decision

`tasks.json` requires `files` (what the task may touch) and `pitfalls` (traps
found by reading the code). `launch.sh` refuses to start a task without them.

Filling `pitfalls` honestly is not possible without reading the code, so the
schema enforces the step that a paragraph of prose did not. Recon stays with the
orchestrator rather than a cheap recon agent: a hallucinated pitfall would enter
the brief labelled as a verified fact.

`pitfalls` goes into the brief as constraints, under an explicit instruction not
to restate them as comments, and into `critique.sh` as extra grading criteria.
`files` is advisory at the gate: straying outside it warns and is flagged to the
critique, but does not fail, because legitimate strays exist (a new test file, an
`__init__.py` import) and a false bounce costs more than a line to read.

## Alternatives rejected

- **A recon section in SKILL.md.** Same shape as the guidance that already failed.
- **Hard-failing on out-of-scope files.** Punishes the orchestrator's estimate
  after the work is done; the target is ≤1 bounce per run.

Primary source: local working notes, `.scratch/swarm-rebuild-findings.md` §5, §6. Untracked on purpose: they quote a private repository and this one is public.
