# Reference: quota preflight and routing

`launch.sh` checks Antigravity quota before creating any worker worktree or pane.
The headless helper `scripts/quota-preflight.mjs` calls the provider's structured
`fetchAccountUsage()` function, fetching linked accounts concurrently once per
wave. It does not scrape the TUI or estimate quota from previous failures.

## Eligibility

The check uses the exact runtime model after model/effort normalization, plus all
reported windows in its shared quota group (for example Gemini weekly and 5-hour
limits). A zero in any applicable limit makes the account exhausted. Missing or
invalid remaining quota, an unreported model, or a failed/timed-out account probe
is unknown, not available. When the aggregate subscription-gated endpoint is
unavailable, the per-model quota remains usable.

No percentage reserve is guessed: a small positive balance is eligible, but does
not guarantee enough quota to complete the task. A past reset timestamp is not
proof of replenishment; a later wave fetches fresh provider data.

## Assignment

- Automatic multi-task waves alternate among eligible accounts only. With A
  available and B exhausted, every automatic task starts on A.
- Explicit `account` selectors (A/B, account ID/email, or 1-based index) must be
  eligible. An exhausted, unknown, or nonexistent explicit account blocks that
  task; the launcher does not silently substitute another account at startup.
- `account: "auto"` or `"round-robin"` requests eligible round-robin explicitly.
  `HERDR_SWARM_ROUND_ROBIN=1` enables it even for a single task;
  `HERDR_SWARM_NO_ROUND_ROBIN=1` disables the multi-task default. Without
  round-robin, the active account is preferred if eligible, otherwise the first
  eligible account is used.
- If no eligible account exists, no worker is opened for that task. The launcher
  reports the reason and known reset time and exits nonzero. Independent Codex
  or other-provider tasks can still launch.
- Account assignment is a starting preference, not a strict account lock during
  execution. Status shows that initial assignment.

The launcher stores sanitized decisions in `.herdr-swarm/quota.json`, archived by
cleanup, and the initial alias/identity in `state.json`. Tokens and raw credential
objects must never appear in those files. CLI model/provider/thinking overrides
in task `args` are rejected for Antigravity tasks: declare `model`/`effort` instead,
so preflight checks the model the worker actually uses.

## Runtime safety

Quota can run out after preflight because other processes consume the same pool.
A confirmed hard quota failure triggers provider failover; transient 429 rate
limits do not switch accounts. The replacement account is remembered in that
worker process across turns and usage commands. Failover does not change the
shared active account or `auth.json`. Stable account IDs bound per-request retries
when access tokens rotate. If all accounts fail, the task receives an error.

Credential refresh updates only the remembered account's tokens, serialized by
`antigravity-accounts.json.refresh.lock`. A normal process exit releases its lock.
An abruptly killed refresh owner can leave a lock: check the PID inside the file,
confirm the owner is gone, then remove that stale lock before retrying. Do not
remove a live worker's lock.

## Installation and verification

The helper uses the installed Pi's `jiti` loader. The provider defaults to
`$PI_CODING_AGENT_DIR/npm/node_modules/pi-antigravity` (agent directory defaults to
`~/.pi/agent`); `HERDR_SWARM_ANTIGRAVITY_DIR` can point at another provider install.

This feature requires the local provider patch in
`patches/pi-antigravity-0.10.0-quota.patch`. It includes process-local selection and
structured quota assessment. Reinstalling/upgrading the npm provider can remove
it; the helper fails closed when the required exports are absent. On pristine
**0.10.0**, restore it from this skill's root with:

```bash
git -C "$HOME/.pi/agent/npm/node_modules/pi-antigravity" apply --check \
  "$PWD/patches/pi-antigravity-0.10.0-quota.patch"
git -C "$HOME/.pi/agent/npm/node_modules/pi-antigravity" apply \
  "$PWD/patches/pi-antigravity-0.10.0-quota.patch"
```

Do not force the patch onto a different upstream version. Restart existing Pi
workers after applying it; already-loaded extensions keep their old code.

```bash
bash tests/test-quota.sh   # fixtures, actual provider stream/parser, synthetic OAuth refresh
bash tests/test-launch.sh # blocked quota creates no worktree; eligible identity reaches pane setup
```

Tests use temporary credentials and mocked transports, not real account tokens.
