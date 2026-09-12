# ADR 0003: `gemini-3.8-flash-high` is the default model

**Date:** 2026-09-12
**Status:** accepted

## Context

SKILL.md routed mechanical work to `gemini-3.8-flash-medium` and **everything
else** — ordinary features, bugfixes, refactors, reviews — to
`gemini-3.1-pro-high`, calling it "the default for almost every task".

The installed copy had already been hand-edited away from that, with the examples
moved to `gemini-3.8-flash-high`. A measured run backs the edit: a four-part ticket
that was not simple finished on flash-high in 9.5 minutes, zero bounces, 5 files,
+94/−31, golden tests untouched.

What made that run work was the specification, not the model: the orchestrator had
read the code and named three traps in the prompt. A bigger model does not rescue a
vague task, and does not make a well-specified slice land any harder.

## Decision

`gemini-3.8-flash-high` is the default for ordinary swarm work.
`gemini-3.1-pro-high` becomes the step up, for tasks that genuinely need the larger
context or that flash-high has already produced a bad diff for. Both draw on the
Gemini pool, so the step up costs nothing scarce.

`CODEX_FALLBACK_EFFORT` defaults to `max` rather than `xhigh`, matching the same
hand edit.

## Consequences

Evidence is one run. If flash-high starts bouncing on well-specified slices, this
is the decision to revisit first — and per ADR 0002 the run archive is what makes
that judgeable instead of anecdotal.

Primary source: `.scratch/swarm-rebuild-findings.md` §6.
