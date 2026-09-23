# Reference: run outcomes and rework measurement

Evaluating agents by prompt quality in isolation is an anti-pattern. Interactions
with leaf agents are iterative, so comparing prompts in isolation does not reflect
real-world performance. What matters is the outcome of the entire run and the
amount of rework required to reach a correct solution.

The swarm records execution facts at run time (`tasks.json`, `run.json`, `state.json`,
`trace.log`, `status.txt`, task diffs, gate verdicts). However, whether the resulting
code merged cleanly, was rejected, or required human fixes can only be established
after human review and integration.

`scripts/run-outcome.py` provides stdlib-only post-run annotation and reporting across
archived runs.

```bash
# Report outcomes across all archived runs
python scripts/run-outcome.py report

# Report in machine-readable JSON format
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

## The Metrics

| Metric | Field | Description |
|--------|-------|-------------|
| **Human minutes** | `human_minutes` | Total operator minutes spent steering, reading diffs, manually testing, or fixing code. |
| **Merge outcome** | `merge_outcome` | The integration result: `merged`, `abandoned`, `rejected`, `amended`, or `partial`. |
| **Post-merge fixes** | `post_merge_fixes` | Count or description of corrective commits/edits needed after merge. This is the primary **rework** indicator. |
| **Elapsed time** | `elapsed_seconds` | Total wall-clock time from task launch until a correct, verified solution was achieved (including human review and fixes). |
| **Known cost** | `cost_usd` | Total inference / API cost incurred by the run in USD. |
| **Prompt retries** | `prompt_retries` | Number of prompt submission retries (e.g. stalled agents or herdr rejections). Derived from `trace.log` where available. |

### Critical Rule: Absent Data is Unknown, Never Zero

Absent data is never assumed to be zero:
- If a run was never annotated, `human_minutes`, `merge_outcome`, `post_merge_fixes`, `elapsed_seconds`, and `cost_usd` are **unknown** (`null` in JSON), not zero.
- `post_merge_fixes = 0` indicates a clean merge that required zero rework. An unrecorded fix count displays as `unknown`.
- `prompt_retries`: `trace.log` is only written when tracing was enabled (`--trace` or `HERDR_SWARM_TRACE=1`). A missing trace log does not prove zero retries; if `trace.log` is absent or contains no prompt events, retries is marked **unknown** (`null`), never zero. If `trace.log` is present and proves prompts landed on attempt 1 without resubmissions, retries is recorded as **0**.

## Storage and Decoupling from Worktrees

Annotations are saved directly into the run archive directory:
`~/.herdr/runs/<run_id>/outcome.json` (or under `HERDR_SWARM_RUN_DIR`).

Because `scripts/cleanup.sh` archives artifacts before closing panes and deleting
worktrees, `scripts/run-outcome.py annotate` can be run at any time after cleanup.
It writes directly to the archive and never touches or requires an agent worktree,
preventing any risk of dirtying worktrees or interfering with Git status.

### Outcome JSON Schema

```json
{
  "run_id": "20260919T161853Z",
  "merge_outcome": "merged",
  "human_minutes": 15.0,
  "post_merge_fixes": 0,
  "elapsed_seconds": 1500.0,
  "cost_usd": 0.42,
  "prompt_retries": 2,
  "notes": "clean merge, no regressions",
  "annotated_at": "2026-09-23T12:00:00Z"
}
```

Updating an existing annotation updates only the specified flags, preserving
previously recorded fields unless `--overwrite` is specified.

## Historical Archive Compatibility

`scripts/run-outcome.py` maintains full backward compatibility with historical
archives created before outcome annotations existed. When reporting across runs:
- Unannotated runs are displayed cleanly with `unknown` for all unrecorded fields.
- Prompt retries are derived on-the-fly from `trace.log` if present in the archive.
- If `trace.log` is absent, retries is displayed as `unknown`.
- No files are written or modified during `report` or `show`.

## Command Line Reference

### `scripts/run-outcome.py annotate`

Annotates a run archive with human observations.

```
usage: run-outcome annotate [-h] [--runs-dir RUNS_DIR] [-m HUMAN_MINUTES]
                            [-o MERGE_OUTCOME] [-f POST_MERGE_FIXES]
                            [-e ELAPSED] [--elapsed-seconds ELAPSED_SECONDS]
                            [-c COST] [--cost-usd COST_USD]
                            [-r PROMPT_RETRIES] [--notes NOTES] [--overwrite]
                            [--json]
                            run
```

- `run`: Run ID (e.g. `20260919T161853Z`), path to archive directory, or `latest`.
- `-m, --human-minutes`: Float minutes (e.g. `15` or `12.5`).
- `-o, --merge-outcome`: String (e.g. `merged`, `rejected`, `abandoned`).
- `-f, --post-merge-fixes`: Integer count of post-merge fixes (e.g. `0`, `2`) or description.
- `-e, --elapsed`: Duration string (e.g. `25m`, `1500s`, `1h15m`, `15:30`).
- `--elapsed-seconds`: Duration in seconds as a float/int.
- `-c, --cost, --cost-usd`: Cost in USD (e.g. `0.45` or `$0.45`).
- `-r, --prompt-retries`: Override prompt retries count (default: auto-derived from `trace.log`).
- `--notes`: Free-form notes.
- `--overwrite`: Reset unspecified fields to null instead of merging with existing annotation.
- `--json`: Print the updated outcome record as JSON.

### `scripts/run-outcome.py report`

Lists summary table or JSON across all runs in `HERDR_SWARM_RUN_DIR`.

```
usage: run-outcome report [-h] [--runs-dir RUNS_DIR] [--json] [run]
```

### `scripts/run-outcome.py show`

Displays detailed outcome information for a single run.

```
usage: run-outcome show [-h] [--runs-dir RUNS_DIR] [--json] run
```
