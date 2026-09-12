# 06 — A run archives its own evidence before anything is removed

**What to build:** after a run is over, the operator can still answer "how was that
task defined, and what did the gate actually see?". Every run leaves a directory of
its own, outside any working repository, and cleanup writes it before it closes
agents or removes worktrees.

Today cleanup deletes the task config, so the tool destroys the evidence a post-mortem
needs: reconstructing a recent run meant working from memory because no config
survived. That is also what makes the model-default decision unreviewable — there is
nothing to compare runs against.

**Blocked by:** 01 — One shared test harness for the fake binaries.

**Status:** ready-for-agent

- [ ] Each run gets its own directory, named by the run's launch timestamp, outside
      every working repository and alongside the briefs the skill already keeps there.
- [ ] The archive holds the run's task config, so how each task was defined stays
      inspectable.
- [ ] The archive holds the trace, so the order in which things failed is recoverable.
- [ ] The archive holds a status snapshot, and per task the diff, the verify verdict
      and the critique verdict.
- [ ] The archive records the skill's commit and whether its tree was dirty at launch,
      so an odd run is attributable to a version. The launch step already reports
      this; the archive keeps it.
- [ ] Cleanup archives as its first action, before closing any agent or removing any
      worktree.
- [ ] Archiving does not depend on the rest of cleanup succeeding: a pane that will
      not close must not cost the record.
- [ ] Cleanup prints where the archive went.
- [ ] A run cleaned up twice does not lose or corrupt the first archive.
- [ ] Tests assert that the archive exists with its contents after a successful
      cleanup, and still exists after a cleanup that failed partway.
