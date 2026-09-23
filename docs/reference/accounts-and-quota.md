# Reference: Antigravity accounts and quota through Pi

Pi's `pi-antigravity` provider owns authentication and linked accounts. The
swarm does not swap Windows credentials or preflight quota before launch.

1. Install the provider with `pi install npm:pi-antigravity`.
2. Start `pi` and run `/login antigravity`.
3. Add another subscription by running `/login antigravity` again. Inspect the
   linked accounts with `/antigravity.accounts`; use
   `/antigravity.accounts switch <index|email>` to choose the initial account.

The provider retries another linked account after a hard quota failure. Check
`/antigravity.usage` for shared quota groups and reset times, and
`/antigravity.models` for the current model catalog and remaining pool quota.
`/antigravity.doctor` gives sanitized diagnostics. These are Pi extension
commands in its TUI.

If every linked account is exhausted, Pi reports the failure in its pane. The
swarm keeps the task and worktree for inspection; it does not silently replace
the requested model with Codex. Check `scripts/logs.sh <task-name>` and
`scripts/status.sh`, then resume the task when quota returns or explicitly
choose another agent kind.

Pi stores tokens under its agent configuration directory. Keep its auth and
linked-account files private.
