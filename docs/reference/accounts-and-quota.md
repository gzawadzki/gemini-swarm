# Reference: Antigravity accounts, quota, and the codex fallback

An agent launched against an empty pool cannot make a single call, and in herdr
that looks exactly like an agent still thinking. So `launch.sh` reads the quota
before it starts anything and picks an account that still has room.

## The two pools

Antigravity meters two quota pools separately, each with a weekly and a five-hour
window:

- **Gemini Models** covers every `gemini-*` slug. This is the large one the swarm
  is meant to spend.
- **Claude and GPT models** covers `claude-*` and `gpt-*` slugs. This is the
  scarce one.

## The rules `launch.sh` applies

- Only the pool a task's model draws from matters. If Gemini sits at 0% and
  Claude/GPT at 82%, the `gemini-3.1-pro-high` tasks move to the other account
  and the `claude-opus-4-6-thinking` tasks stay on the live one.
- Either window counts. 0% on the five-hour limit blocks the task now, even when
  the weekly limit still has room.
- A task with no `model` runs on whatever agy defaults to, which the CLI does not
  report, so an empty pool on either side counts as empty.
- Only the live account's quota can be read, because `/usage` answers for whoever
  `agy` is signed in as. The other account is consulted only once the live one
  reads 0%, since asking means swapping the credential first.
- **A switch is refused while any `agy` process is running.** Every agent on this
  profile shares one credential, so a swap would change a running agent's account
  and lose the credential swapped in. `launch.sh` then launches nothing and says
  to wait. Report that; do not force it.
- **When both accounts are empty the task runs on codex** (`gpt-5.6-luna` at
  `max`), recorded as `fallback_from` in `state.json` and marked `*` in
  `status.sh`. The same happens when there is no second account, or when
  `HERDR_SWARM_NO_SWITCHING=1` forbids the switch.
- If the quota cannot be read at all, the task stays on the live account and
  `launch.sh` warns. It does not guess.

Tell the user whenever a task changed account or fell back. They picked a model
for a reason, and a security review done by `gpt-5.6-luna` instead of
`claude-opus-4-6-thinking` is a different piece of work.

## Reading the quota by hand

There is no `agy usage` subcommand, and `/usage` only expands in print mode:

```bash
MSYS_NO_PATHCONV=1 agy -p "/usage"
```

```
Gemini Models	Weekly Limit Remaining	80%	2026-09-04T00:18:35Z
Gemini Models	Five Hour Limit Remaining	22%	2026-08-28T12:31:35Z
Claude and GPT models	Weekly Limit Remaining	94%	2026-09-04T07:31:35Z
Claude and GPT models	Five Hour Limit Remaining	82%	2026-08-28T12:31:35Z
```

`MSYS_NO_PATHCONV=1` is required on Windows, and its absence is a silent failure
rather than an error — see
[troubleshooting](troubleshooting.md#a-quota-read-that-answers-in-prose).

## How the second account works

`agy` has no `--profile` or `--account` flag. Its OAuth token lives in Windows
Credential Manager under one fixed target, `gemini:antigravity`, per Windows
user. Environment variables cannot separate two subscriptions.

`scripts/agy-account.ps1` keeps a vault instead: one extra credential entry per
account (`herdr-swarm:agy-a`, `herdr-swarm:agy-b`) plus the live target that
`agy` actually reads. Switching accounts means copying a vault entry over the
live one before an agent starts. Both accounts then run as the user, in an
ordinary herdr pane with a full TUI, and nothing about the launch differs.

```
list                what is in the vault, and which account is live
save -Account a|b   copy the live credential into the vault
use  -Account a|b   sync the outgoing account, then make a|b live
sync                copy the live credential back over its own vault entry
```

Setup is one-time and the user does it: run `agy`, `/logout`, `/login` as the
second subscription, `save -Account b`; then `/logout`, `/login` as the main one,
`save -Account a`. If both vault entries are empty, or `pwsh` is not installed,
there is no second account and the swarm goes straight to codex when the live one
empties.

The script never prints a credential. It prints a 12-character SHA-256 prefix
with the blob size and write time, which distinguishes two accounts and is
useless to anyone else. Keep it that way if you touch it.

Two consequences:

- **`agy` refreshes its token mid-session and writes it back to the live
  target.** Measured: with twelve sessions running, the entry was rewritten twice
  inside thirty seconds. So accounts cannot be mixed while agents are alive, and
  `use` refuses to swap in that case. It also means a vault entry is stale as
  soon as its account has done work, so `use` syncs the live credential back into
  the outgoing account's entry first.
- **Which account is live is a state file**,
  `%LOCALAPPDATA%\herdr-swarm\live-account`. After a refresh the live blob
  matches no vault entry, so nothing else knows. If that file is missing, `use`
  refuses rather than silently losing a token; the fix is
  `save -Account <whoever is signed in>`.

A task's account is recorded in `state.json` as `account`, shows up in
`status.sh` as `agy@B`, and is called out by `review.sh`. Both accounts run the
model the user asked for, so this changes who paid for the work, not what did it.

## Environment overrides

| variable | effect |
|----------|--------|
| `HERDR_SWARM_NO_SWITCHING=1` | never switch accounts; an empty live account goes straight to the codex fallback |
| `HERDR_SWARM_NO_FALLBACK=1` | never fall back to codex; a task no account can run is not launched, and `launch.sh` prints when each account refills |
| `HERDR_SWARM_CODEX_MODEL` | the fallback model, default `gpt-5.6-luna` |
| `HERDR_SWARM_CODEX_EFFORT` | the fallback reasoning effort, default `max` ([ADR 0003](../adr/0003-flash-high-is-the-default.md)) |
| `HERDR_SWARM_CODEX_PLUGINS=1` | keep user codex plugins on; off by default, see [the gate](the-gate.md#plugins-are-off-for-every-codex-the-swarm-starts) |

## Safety

Switching accounts moves an OAuth credential between entries in the user's own
Windows Credential Manager. Never print a credential blob, never copy one out of
the vault, and never pass `-Force` to `agy-account.ps1 -Mode use` to get around
the "agents are running" refusal: that silently changes the account of a running
agent and loses a token.
