# Reference: run outcomes and rework measurement

Evaluating agents by prompt quality in isolation is an anti-pattern. Interactions
with leaf agents are iterative, so what matters is the outcome of the entire run
and the rework required to reach a correct solution.

The swarm archives execution facts (`run.json`, `state.json`, `trace.log`,
verdicts, and diffs). However, human review and integration outcome occur after
the run finishes. `scripts/run-outcome.py` provides stdlib-only post-run annotation
and cross-run reporting.

## Command Usage

```bash
# Report outcomes across all archived runs
python scripts/run-outcome.py report

# Report in JSON format
python scripts/run-outcome.py report --json

# Inspect a single run
python scripts/run-outcome.py show 20260919T161853Z

# Annotate a run after cleanup
python scripts/run-outcome.py annotate 20260919T161853Z \
  --merge-outcome merged \
  --human-minutes 15 \
  --post-merge-fixes 0 \
  --elapsed 25m \
  --cost 0.42 \
  --notes "clean merge, no regressions"

# Annotate the latest run
python scripts/run-outcome.py annotate latest --merge-outcome merged --post-merge-fixes 0
```

## Metrics and Definitions

- **Human minutes (`human_minutes`):** Operator minutes spent steering, reading diffs,
  manually testing, or fixing code.
- **Merge outcome (`merge_outcome`):** Integration outcome (`merged`, `abandoned`,
  `rejected`, `amended`, etc.).
- **Post-merge fixes (`post_merge_fixes`):** Count or description of fixes required
  after merge. This is the primary rework indicator. `0` indicates clean merge
  (zero rework); unrecorded is `unknown`.
- **Elapsed time (`elapsed_seconds`):** Wall-clock time from launch to a verified,
  accepted solution (including human review/rework).
- **Cost (`cost_usd`):** Total known model API / inference cost in USD.
- **Prompt retries (`prompt_retries`):** Task re-prompts after operator review.
  `trace.log` records launcher prompt *delivery attempts* (`submit_prompt`), not
  subsequent re-prompts. A single initial prompt in trace does not justify rework=0.
  `prompt_retries` is marked `unknown` unless explicitly annotated or a dedicated
  rework event is logged in trace. Launcher delivery retries are tracked separately
  as `prompt_delivery_retries`.

## Absent Data is Unknown, Never Zero

Absent data is never assumed to be zero:
- Unannotated fields display as `unknown` (and `null` in JSON).
- `post_merge_fixes = 0` means zero rework; omitted `--post-merge-fixes` remains `unknown`.
- Missing `trace.log` or a trace without dedicated rework events leaves `prompt_retries`
  as `unknown`.

## Worktree Decoupling and Historical Archives

`scripts/cleanup.sh` archives artifacts before closing panes and deleting worktrees.
`scripts/run-outcome.py annotate` writes directly to `outcome.json` inside the run
archive directory (`~/.herdr/runs/<run_id>/outcome.json` or `HERDR_SWARM_RUN_DIR`).
It never modifies or requires an agent worktree.

Historical archives without `outcome.json` remain fully readable by `report` and
`show`, displaying `unknown` for unrecorded values without errors.
