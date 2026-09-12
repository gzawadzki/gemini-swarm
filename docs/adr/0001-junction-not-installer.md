# ADR 0001: the installed skill is a junction, not a copy

**Date:** 2026-09-12
**Status:** accepted

## Context

`~/.claude/skills/gemini-swarm` is what Claude Code loads and executes. This repo
is what gets developed. They had drifted: the installed `scripts/` were an exact
snapshot of `4c1ae7c` (2026-09-09), three days and one merged branch behind, so
the installed `SKILL.md` did not mention `cleanup.sh`, `trim.sh` or
`agy-account.ps1` at all — none of which were installed either.

The cost landed on a real run: the orchestrator was told to clean up by hand,
walked into a Windows directory-lock bug, and worked around it manually, while the
script that does it correctly sat two directories away, uninstalled.

Four installed files also carried local hand edits that existed in no commit
(`CODEX_FALLBACK_EFFORT` set to `max`, examples moved to `gemini-3.8-flash-high`),
which proves the installed copy is edited in place, so any copy-based sync would
silently destroy work.

## Decision

Replace the installed directory with a Windows junction pointing at this repo.
Junctions need no elevation.

Drift becomes structurally impossible rather than something a check has to catch,
and an edit made in the installed path shows up as an uncommitted change in
`git status` here — visible instead of silent.

Its side effect is accepted deliberately: an uncommitted half-rewrite executes
live. `launch.sh` therefore reports the skill's `HEAD` and its dirty files at the
start of every run, and does **not** block on them. During a rebuild the tree is
dirty continuously, so blocking would break the edit-and-try loop the junction
exists to enable. Attribution, not prevention.

## Alternatives rejected

- **`install.ps1` plus `--check`.** Keeps two copies, so live edits still get
  lost; needs a step nobody remembers to run, which is how the drift happened.
- **A hash check in step 0.** Detects drift without fixing it.

## Consequences

- The local hand edits were migrated into the repo before the junction was made.
- Unverified: whether Claude Code's skill discovery follows a junction. If it does
  not, the fallback is `install.ps1 -Check`, and the live-edit problem returns.

Primary source: local working notes, `.scratch/swarm-rebuild-findings.md` §1. Untracked on purpose: they quote a private repository and this one is public.
