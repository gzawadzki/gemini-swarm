# 04 — Scope and size are visible before the operator reads the diff

**What to build:** the operator can see, without opening the diff, that a task
touched files it never declared, or produced a diff far wider than the task should
have been. Both the status view and the pre-merge review report it, and neither
blocks on it.

Advisory on purpose. Legitimate strays exist — a new test file, a package import —
and a false bounce costs more than reading the line. A diff above the size guideline
is already written, so failing it does not make it smaller; the value is learning
that the task was too wide before writing the next one.

**Blocked by:** 02 — A task cannot launch without recon.

**Status:** ready-for-agent

- [ ] One shared reader computes which files a task's diff touched outside its
      declared list, so the two views cannot give different answers.
- [ ] The status view reports out-of-scope files per task, naming them.
- [ ] The pre-merge review reports the same thing, so the last thing the operator
      sees before merging is what the task touched beyond what it declared.
- [ ] Neither view fails, blocks or bounces a task over scope.
- [ ] A diff far above the roughly-400-line guideline is called out after the fact,
      as a signal that the task was too wide.
- [ ] A task whose diff stays inside its declared files and the size guideline shows
      no noise at all, so the report means something when it does appear.
- [ ] Reading status stays free: no agent is spawned and no gate is run by either
      report.
- [ ] Tests cover a task that stays in scope, one that strays, and one whose diff is
      oversized, asserting on what the views produced.
