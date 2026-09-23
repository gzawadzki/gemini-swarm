# Reference: quota preflight feasibility and routing

Proposal P2 suggests adding a quota-aware warning before starting parallel runs,
or routing tasks according to available quota runway. This document records the
feasibility check on the current machine and defines requirements for any future
implementation.

## Current Tooling Feasibility

We examined the available CLI commands on this machine: `agy --help` and `pi auth --help`.

### `agy --help`
`agy --help` lists session options (`--model`, `--effort`, `--print`, etc.) and
subcommands (`agent`, `changelog`, `help`, `install`, `mcp`, `mic-serve`, `models`,
`plugin`, `remote-control`, `update`).
- `agy models` lists available model names and aliases.
- Neither `--help` nor `models` exposes remaining quota, available request/token
  capacity, rate-limit state, or quota reset times.

### `pi auth --help`
`pi auth --help` lists credential inspection commands:
- `pi auth print-api-key [--provider <p>] [--model <m>]`
- `pi auth print-bearer-token [--provider <p>] [--model <m>]`
- `pi auth check [--provider <p>] [--model <m>] [--json] [--credentials] [--no-refresh]`

`pi auth check` verifies model and credential presence, refreshing OAuth tokens if
needed. It exposes credential validity, but no remaining quota, runway, or reset time.

Neither tool provides trustworthy remaining quota or reset time for preflight decisions.

## The Rule: Do Not Estimate Quota from Failures or Elapsed Time

We do not estimate remaining quota from previous 429 failures or elapsed time:
1. **Shared / concurrent usage:** Quota is consumed concurrently across parallel swarm
   tasks and external developer sessions on the host. An elapsed-time heuristic
   cannot observe out-of-band usage.
2. **Ambiguous failures:** A 429 error can indicate transient concurrency throttling
   rather than account-wide budget exhaustion. Assuming a cool-down duration causes
   unnecessary task rejections (false positives).
3. **Window variance:** Quota algorithms vary (per-minute leaky buckets, rolling windows,
   daily resets). Guessing resets from local timers leads to agent crashes mid-flight
   when guesses are wrong (false negatives).

## Requirements for a Reliable Quota Source

Swarm routing and preflight checks will remain unchanged until a dedicated provider
or CLI source exposes trustworthy remaining quota. To be usable, such a source
would need to return:

- **Format:** Structured, machine-readable output (e.g. JSON to stdout with clear exit codes).
- **Execution:** Headless, non-interactive (no TUI or interactive prompts).
- **Fields:**
  - Account identifier or alias.
  - Quota tier / model group.
  - Remaining capacity (percentage or token/request runway).
  - Window reset time (UTC ISO 8601 timestamp or seconds to reset).
  - Throttled status (boolean indicating active 429/exhaustion).

Until a reliable source satisfying these requirements exists, routing logic remains
unchanged, and the swarm relies on provider-level failover upon hard quota exhaustion.
