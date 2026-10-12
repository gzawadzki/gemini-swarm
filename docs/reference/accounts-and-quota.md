# Reference: Antigravity accounts and quota through Pi

Pi's `pi-antigravity` provider owns authentication and linked accounts. The swarm
checks structured quota before launch and assigns a process-local starting
account; it never swaps Windows credentials.

1. Install the provider with `pi install npm:pi-antigravity` and apply the versioned
   local patch described in [quota preflight](quota-preflight.md).
2. Start `pi` and run `/login antigravity`.
3. Add another subscription by running `/login antigravity` again. Inspect linked
   accounts with `/antigravity.accounts`; use
   `/antigravity.accounts switch <index|email>` to choose the interactive account.

Automatic multi-task waves alternate among accounts with available quota for the
requested model. Exhausted/unknown accounts are excluded. Explicit task `account`
selectors must pass the same check. If none are eligible, the launcher reports a
block without opening a worker. See [quota preflight](quota-preflight.md) for the
routing rules, snapshot, installation and tests.

`ANTIGRAVITY_ACCOUNT` (or `PI_ANTIGRAVITY_ACCOUNT`) selects a worker's initial
account. Supported selectors include A/B, acc1/acc2, 1-based indices and stored
account IDs/emails. The launcher injects the checked canonical identity so changes
to account ordering cannot alter the assignment.

During execution, the provider retries another linked account after a confirmed
hard quota failure. That choice remains local to the worker across turns, without
switching the global active account or rewriting `auth.json`. Assignment is a
starting preference, not a strict account lock; status reports the initial account.

Check `/antigravity.usage` for shared quota groups and reset times, and
`/antigravity.models` for the model catalog and remaining pool quota.
`/antigravity.doctor` gives sanitized diagnostics. These are Pi extension commands
in its TUI. Existing Pi processes need a restart to load a newly applied patch.

If quota runs out on every linked account after launch, Pi reports the failure.
The swarm keeps the task and worktree for inspection; it does not silently replace
the requested model with Codex. Check `scripts/logs.sh <task-name>` and
`scripts/status.sh`, then resume when quota returns or explicitly choose another
agent kind.

Pi stores tokens under its agent configuration directory. Keep its auth and
linked-account files private. Preflight snapshots contain no tokens.
