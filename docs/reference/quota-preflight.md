# Reference: quota preflight feasibility and routing requirements

Proposal P2 suggests adding a quota-aware warning before starting parallel runs,
or routing tasks according to available quota runway. This document records the
feasibility investigation on the current environment, specifies the requirements
for a reliable quota preflight source, and explains why swarm routing remains
unchanged until such a source exists.

## Investigation of Current Machine Tooling

We investigated the available CLI commands on this host (`agy` and `pi auth`).

### 1. `agy --help`

The `agy` CLI provides subcommands:
`agent`, `agents`, `changelog`, `help`, `install`, `mcp`, `mic-serve`, `models`,
`plugin`, `plugins`, `remote-control`, `update`.

Findings:
- `agy models` lists supported model identifiers (e.g. `gemini-3.8-flash-high`,
  `gemini-3.1-pro-high`, `claude-sonnet-4-6`) and friendly display names.
- None of the `agy` subcommands return remaining quota tokens, request counts,
  percentage runway, or window reset timestamps.
- Legacy invocations like `agy -p /usage` are interactive TUI slash commands
  executed within the model context; they do not provide a structured,
  deterministic CLI response for scriptable preflight decisions. Furthermore,
  the swarm has migrated execution kinds from `agy` to `pi`.

### 2. `pi auth --help`

The `pi auth` CLI provides:
```text
Usage:
  pi auth print-api-key [--provider <provider>] [--model <model>]
  pi auth print-bearer-token [--provider <provider>] [--model <model>] [--min-expiry <duration>]
  pi auth check [--provider <provider>] [--model <model>] [--json] [--credentials] [--no-refresh]
```

Findings:
- `pi auth check` checks credential presence and performs OAuth token refresh.
- It returns whether authentication is valid (`status: ok`) or missing/expired.
- It exposes **no remaining quota, no rate limit bucket levels (RPM/TPM), and no reset times**.

### 3. Pi TUI Slash Commands

Inside an interactive `pi` terminal session, the `pi-antigravity` extension
provides commands such as `/antigravity.usage`, `/antigravity.models`, and
`/antigravity.doctor`.

Findings:
- These commands exist only inside Pi's interactive terminal user interface.
- There is no headless, non-interactive CLI flag or command (such as `pi quota`
  or `pi-antigravity --json`) that outputs machine-readable quota state to stdout
  with predictable exit codes.

## The Rule: Do Not Estimate Quota from Failures or Elapsed Time

A naive approach might attempt to guess remaining quota using heuristic estimation:
tracking when a 429 error occurs and assuming the account or model is exhausted
for some elapsed duration.

**We explicitly reject this heuristic approach.** Estimating remaining quota
from failures or elapsed time introduces severe operational failure modes:

1. **Multi-tenant and out-of-band usage:** Quota pools are shared across tasks,
   multiple agents running in parallel, and interactive user sessions outside the
   swarm. A local timer cannot observe tokens consumed by other processes.
2. **Distinct reset windows:** Providers employ varied quota algorithms:
   per-minute token leaky buckets (TPM), per-minute request ceilings (RPM),
   rolling 5-hour sliding windows, and midnight UTC daily quotas. Guessing when
   a window resets based on elapsed time since the last failure is fragile and
   inaccurate.
3. **Ambiguity of 429 errors:** HTTP 429 (`RESOURCE_EXHAUSTED`) can signify a
   momentary concurrency burst rather than daily budget depletion. Treating a
   transient burst as a total account lockout blocks tasks unnecessarily (false
   positive). Conversely, assuming a cool-down has elapsed when external processes
   are still draining tokens results in tasks crashing mid-flight (false negative).

## Specification: What a Reliable Quota Source Must Return

To enable quota-aware preflight checks or intelligent quota-runway routing, an
upstream provider or CLI must expose a dedicated, headless query interface
(e.g., `pi quota check --json` or `pi-antigravity usage --json`).

A reliable source must return a machine-readable JSON object with the following fields:

```json
{
  "status": "ok",
  "checked_at": "2026-09-23T12:00:00Z",
  "accounts": [
    {
      "account_id": "account-a",
      "is_active": true,
      "pools": [
        {
          "pool_id": "gemini-flash",
          "models": ["gemini-3.8-flash-high", "gemini-3.8-flash-medium"],
          "remaining_percent": 85.0,
          "remaining_requests": 1200,
          "remaining_tokens": 4500000,
          "window_type": "rolling_5h",
          "reset_at": "2026-09-23T14:30:00Z",
          "reset_in_seconds": 9000,
          "is_throttled": false
        },
        {
          "pool_id": "gemini-pro",
          "models": ["gemini-3.1-pro-high"],
          "remaining_percent": 10.0,
          "remaining_requests": 50,
          "remaining_tokens": 200000,
          "window_type": "daily",
          "reset_at": "2026-09-24T00:00:00Z",
          "reset_in_seconds": 43200,
          "is_throttled": false
        }
      ]
    }
  ]
}
```

### Essential Contract Requirements

1. **Non-interactive / Headless:** Must execute cleanly without launching an
   interactive TUI, curses screen, or prompt.
2. **Structured JSON:** Outputs strictly valid JSON to stdout with clear exit
   status (0 on success, non-zero on query failure).
3. **Granular per Quota Pool / Tier:** Quotas differ between Flash, Pro, and
   Thinking tiers; a single account-wide boolean is insufficient.
4. **Explicit Reset Time:** Must provide absolute ISO 8601 UTC timestamp and/or
   seconds remaining until reset.
5. **Fast Execution:** Must resolve within a few seconds (e.g. < 3s) so as not to
   impede swarm launch.

## Architectural Decision

Until a reliable, headless source satisfying the above specification is exposed by
the provider or CLI:

1. **Routing and launch remain unchanged:** `scripts/launch.sh` and routing logic
   will not incorporate speculative preflight quota checks.
2. **Reactive fallback is preserved:** The swarm relies on `pi-antigravity`'s
   built-in linked account failover upon encountering a hard quota failure during
   agent execution.
3. **Inspection via logs:** When every linked account is exhausted, Pi reports the
   failure in its pane and logs, allowing the orchestrator to inspect status via
   `scripts/status.sh` and `scripts/logs.sh` rather than aborting based on guesses.
