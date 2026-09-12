# Reference: cleanup, and the run archive

Cleanup is a step of the run, not tidying up afterwards. It also writes the only
record of the run that outlives it.

```bash
scripts/cleanup.sh                          # agents that reported a result
scripts/cleanup.sh --all                    # working ones too, interrupting them
scripts/cleanup.sh --worktrees [--force]    # also remove their workspace
scripts/cleanup.sh --dry-run                # say what it would do
```

## The archive comes first

Before it closes anything, `cleanup.sh` writes the run's archive to
`~/.herdr/runs/<launch-timestamp>/` and prints the path. It holds:

| file | what it is |
|------|------------|
| `tasks.json` | the task config **as launched**, embedded by `launch.sh` rather than read back from disk, since the file the orchestrator wrote is routinely edited or deleted between runs |
| `run.json` | the run id, the skill commit it ran on, how many files were uncommitted in that tree at launch, and the dirty-file list |
| `state.json` | the per-task state file |
| `trace.log` | the trace, when the run was traced, so the order in which things failed is recoverable |
| `status.txt` | a status snapshot taken while the worktrees still existed |
| `<name>.diff` | each task's diff against its pinned base |
| `<name>.verify.json`, `<name>.critique.json` | each task's two gate verdicts |

Archiving is first precisely because everything after it is destructive: the
diffs live in the worktrees this script removes, and an agent that will not close
must not cost the record. Each file is collected best effort, so one unreadable
diff does not cost the rest; the whole thing is built in a staging directory and
moved into place, so the run id never names a directory still being filled, and a
second cleanup — run once the worktrees are gone — finds the first archive and
leaves it alone rather than overwriting it with an emptier one. `--dry-run`
writes nothing and says where the archive would have gone.

`HERDR_SWARM_RUN_DIR` moves the root. The default sits beside the briefs, outside
every working repository, because writing into a worktree flips its CLEAN column
to `DIRTY` and the archive is written while the worktrees are still being judged.

**That directory is what a post-mortem reads.** Point the user at it when a run
behaved oddly, and read it before concluding anything about how a model or a task
shape performed. Cleanup used to delete the task config, so "how was that task
defined" was answerable only from memory, and the model-default decision had
nothing to compare runs against.

## Which agents get closed

An agy agent that finished its task does not exit. It sits in its pane as an idle
process still holding the shared OAuth credential, so the next launch that needs
the other account is refused with "accounts cannot be mixed" — true, but it reads
like a quota problem rather than "your last swarm is still open".

By default `cleanup.sh` closes only agents that wrote a result file or that herdr
calls `done`. An `idle` agent with no result file is left alone on purpose: that
is what a dropped prompt looks like, and closing it would throw away a task
nobody has looked at. `--all` closes those too, interrupting their work.

herdr has no `agent stop`, so `cleanup.sh` sends the TUI's own interrupt. Two
details are load-bearing and easy to get wrong by hand: the key name is `ctrl+c`
(`ctrl-c` comes back as `unsupported key`), and both presses must go in a single
`herdr agent send-keys <name> ctrl+c ctrl+c` call. Sent as two calls with a sleep
between them, the second is mostly swallowed and the pane stays open.

## Which worktrees get removed

`--worktrees` removes the herdr workspace of every agent closed in the same run,
but only when the worktree is clean **and** the branch is already merged into its
base. Both checks are about not losing work: uncommitted files, and commits on a
branch nobody has merged. `--force` overrides both; use it only once the user has
said the branch can go.

Removing a workspace removes the checkout, never the branch.

## Finishing the job

A swarm task is not complete until the following is true. Report anything
intentionally retained, such as a backup branch, and why.

- The reviewed result is integrated, preserved on another ref, or explicitly
  discarded by the user.
- The agent is closed and its worktree removed. Close any duplicate or orphaned
  workspace created for the same task.
- `agent/<name>` is deleted **only after** confirming its desired commits are on
  the user's branch, a PR ref, or a deliberate backup. The branch is the only copy
  of that work.
- That task's scratch state is gone from `.herdr-swarm`: `<name>.result.json`,
  `<name>.verify.json`, `<name>.verify.log`, `<name>.critique.json`,
  `<name>.critique.brief.md`, `<name>.critique.reply.txt`, `<name>.trim.json`,
  `<name>.trim.brief.md`, `<name>.trim.reply.txt`. Remove the directory itself
  only when no active task still uses it. The archive already holds what matters.
- The cleanup is verified: the task is absent from `herdr workspace list`, its
  path is absent from `git worktree list`, its disposable branch is absent from
  `git branch --list 'agent/<name>'`, and the user's pre-existing working-tree
  changes are unchanged.

A worktree that will not remove on Windows is usually a directory lock, not a
git problem — see [troubleshooting](troubleshooting.md#a-worktree-that-will-not-remove).
