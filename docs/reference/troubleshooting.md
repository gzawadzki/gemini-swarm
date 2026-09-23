# Reference: traps, and how to see what actually happened

The interesting failures here are not exceptions. A prompt herdr accepted that
the agent never saw, or a base ref that resolved to the branch tip, can look
like success from the outside. This file is
the list of the ones that have actually happened, and the tool for finding the
next one.

## Trace mode

Every script but `cleanup.sh` takes `--trace`, anywhere in the arguments:

```bash
scripts/launch.sh --trace tasks.json
scripts/critique.sh fix-auth-bug --trace
```

For a whole session set `HERDR_SWARM_TRACE=1` and drop the flag; `--no-trace` on
a single call overrides it. Off by default, and when off it costs nothing — no
subprocesses run and no file is created.

Every external call gets one line in `$HERDR_SWARM_STATE_DIR/trace.log`
(`.herdr-swarm/trace.log` by default): timestamp, script, task, event, and the
command with its exit code. The log lives in the state dir and never inside a
worktree, because writing into a worktree would flip its CLEAN column to `DIRTY`
and break the review gate. It is append-only; delete it yourself when it gets
long, and note that [the run archive](cleanup-and-archive.md#the-archive-comes-first)
keeps a copy of it.

```
2026-09-09T00:02:31Z critiq  demo    reviewer.pick  pi for model gemini-3.8-flash-high
2026-09-09T00:02:32Z critiq  demo    verdict.parse  revise (1 issues, confidence high)
```

Source tags are `launch`, `status`, `verify`, `critiq`, `trim`, `review`, `logs`,
and `lib` for anything written by the shared helpers. A task column of `-` means
the event belongs to the run rather than one task.

| script | events |
|--------|--------|
| `launch` | `run.start`, `run.meta`, `skill.state`, `recon.accept` / `recon.reject`, `kind.resolve`, `timeout.clamp`, `base.pin`, `herdr.exec`, `worktree.ready`, `agent.start`, `agent.ready`, `prompt.submit` / `prompt.landed` / `prompt.stalled` / `prompt.lost`, `rollback`, `state.write`, `run.end` |
| `status` | `poll`, one compact line per task, and `scope.read` |
| `verify` | `cmd.resolve` (the command, and whether it came from `tasks.json` or auto-detection), `cmd.exec`, `soundness` |
| `critiq` | `base.resolve`, `diff.collect`, `reviewer.model`, `reviewer.pick`, `reviewer.exec`, `verdict.parse`, `verdict.downgrade`, `verdict.write` |
| `trim` | `base.resolve`, `diff.collect`, `reviewer.pick`, `reviewer.exec`, `trim.write` |
| `review` | `base.resolve`, `review.read` |
| `logs` | `herdr.exec` |
| `lib` | `archive.write`. `cleanup.sh` is the one script with no `--trace` flag of its own, so its event carries the default source tag and only appears when `HERDR_SWARM_TRACE=1` is set for the session |

Prompts are never written to the log, only their byte count. Keep it that way if
you extend the tracing: the log is meant to stay safe to paste into a chat.

## The traps

### A launch rejected with `invalid_agent_timeout`

`ready_timeout_ms` is how long herdr waits for the agent's TUI to accept input,
and herdr caps it at 300000. A work-budget-sized value in that field fails the
launch outright. `launch.sh` clamps it and warns, and the two clocks are separate
fields now — see [ADR 0004](../adr/0004-split-the-timeout-field.md). A
`timeout_ms` above 300000 anywhere is that bug.

The measured run: `agent.start timeout=900000` at 23:19:38, failed one second
later, no clamping present.

### A prompt herdr accepted that the agent never saw

`herdr agent prompt` only reliably delivers one short line. A long multi-line
brief pasted into the input box comes back `agent_prompted` and arrives empty,
and the pane then sits idle looking exactly like a task nobody has reviewed yet.
Measured at 6519 bytes: it took two attempts.

So `launch.sh` writes the whole brief to `~/.herdr/briefs/<name>.md` and sends a
one-line pointer at it, then compares `state_change_seq` before and after
submitting and resends once if nothing moved. Never send a prompt with its output
redirected to `/dev/null`. In the trace this shows as `prompt.stalled` followed by
`prompt.landed` on attempt 2.

There is a second half to the same window: `agent start` returns when the process
exists, which is earlier than the TUI accepting input, so `launch.sh` waits for
`interactive_ready` before prompting at all.

### A branch left behind by a failed launch

Removing a worktree leaves the branch, and the branch is what blocks the retry:
`herdr worktree create` refuses a branch that already exists. A failed launch used
to need a manual `git branch -D` before the task could be relaunched. `launch.sh`
now deletes the branch as part of its rollback, and warns by name when it cannot.

### A worktree that will not remove

On Windows this is usually a directory lock rather than a git problem: something
still has the checkout open — most often the agent's own pane, which is why
`cleanup.sh` closes agents before it removes worktrees. Use
`scripts/cleanup.sh --worktrees` rather than `herdr worktree remove` by hand; the
script's ordering exists for this. If it still refuses, check that no shell,
editor or file manager is sitting in the directory, then retry.

### Tests that pass against another checkout

An editable install pins imports to a fixed path, so a suite run inside a
worktree can import the package from the main checkout and go green on a diff it
never touched. One project was saved from this by a `pythonpath` line in its
config, by accident rather than design.

`verify.sh` therefore asks where the code under test resolved from, and only
`sound` renders as a pass — see [the gate](the-gate.md#a-green-command-is-not-yet-a-pass).
When it reports `fail` on resolution, **do not re-prompt the agent**: the diff may
be fine and the environment is what lied. Reinstall inside the worktree, or set a
pythonpath for it, then rerun.

The same trap in the other direction is why a `verify` command must never
reinstall the package: `pip install -e .` in a verify command repoints the
editable install at the agent's worktree, or worse leaves the tests importing the
main checkout.

### A diff that looks empty

Inside a task's own worktree `HEAD` **is** the task branch, so resolving the base
from there gives back the branch tip and every diff comes out empty. `launch.sh`
pins `base_sha` at worktree-creation time for this reason. In the trace, check
`base.pin` and `base.resolve`.

### A validation error that looks blank

The `jq` on this platform ends every line with CRLF. Command substitution drops
the trailing CR along with the newline, so `$(jq -r ...)` is clean; `read` strips
only the newline, so a collapsed multi-field `read` leaves a bare CR in the last
variable. That CR is invisible in output and non-empty to `[[ -n ]]`, which once
turned a validation check into one that rejected every task while printing an
error message that looked blank. One `$(...)` per field is the safe shape.

### `unreachable` or `n/a` right after a launch

`unreachable` for a task you just launched means the script is asking herdr the
wrong question, not that the agent died. Check `herdr agent list` before
relaunching anything. `n/a` under CLEAN is an unresolved worktree path, not a
clean tree.

herdr's JSON field names are the fragile part, and they are not documented
upstream: agent status is `.result.agent.agent_status` (not `.status`), input
readiness is `.result.agent.interactive_ready`, and the checkout path is
`.result.workspace.worktree.checkout_path` (not `.workspace.cwd`, which is
absent). All of them live in `scripts/lib.sh` only, so a herdr upgrade means one
edit. Confirmed with herdr 0.8.2 and Antigravity CLI 1.1.27.

### An agent stuck in `blocked`

Something needs a human despite auto-approve. Read its logs with
`scripts/logs.sh <name>` and decide, rather than looping retries. It is not a
reason to add more auto-approve flags.

### A pane that will not close

herdr has no `agent stop`. The key name is `ctrl+c`, not `ctrl-c`, and both
presses must go in a single `herdr agent send-keys <name> ctrl+c ctrl+c` call —
see [cleanup](cleanup-and-archive.md#which-agents-get-closed). A pane that still
will not close is reported by name and closed by hand; it does not cost the run
archive, which is written first.
