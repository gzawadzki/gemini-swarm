#!/usr/bin/env bash
# Shared helpers for the swarm scripts.
#
# herdr's JSON field names are the fragile part here. They are not documented
# upstream and differ from what you'd guess. Two that bit us:
#   * agent status lives at .result.agent.agent_status, not .status
#   * the worktree checkout lives at .result.workspace.worktree.checkout_path,
#     not .result.workspace.cwd (which is absent)
# Keep those paths in this file only, so a herdr upgrade means one edit.

# Lifecycle state of an agent: idle | working | blocked | done | unreachable.
agent_state() {
  herdr agent get "$1" 2>/dev/null \
    | jq -r '.result.agent.agent_status // "unreachable"' 2>/dev/null \
    || echo "unreachable"
}

# Whether the agent's TUI is ready to accept a prompt. Prompting before this is
# true silently drops the prompt: herdr reports the submission as accepted, the
# CLI never receives it, and the pane sits idle with an empty input box.
agent_ready() {
  [[ "$(herdr agent get "$1" 2>/dev/null | jq -r '.result.agent.interactive_ready // false')" == "true" ]]
}

# Counter herdr bumps on every observed agent state change. Used to tell "the
# prompt landed" from "herdr accepted it and the agent never noticed".
agent_seq() {
  herdr agent get "$1" 2>/dev/null | jq -r '.result.agent.state_change_seq // -1'
}

# Send a prompt and confirm the agent actually reacted; resend once if it didn't.
# Returns non-zero when even the resend goes nowhere.
submit_prompt() {
  local name="$1" text="$2" attempt before resp type
  for attempt in 1 2; do
    before=$(agent_seq "$name")
    resp=$(herdr agent prompt "$name" "$text" 2>&1)
    type=$(jq -r '.result.type // empty' <<<"$resp" 2>/dev/null || true)
    if [[ "$type" != "agent_prompted" ]]; then
      echo "WARN: [$name] herdr rejected the prompt: $resp" >&2
    else
      # Two independent signals that it landed: the change counter moved, or the
      # agent left idle. On a busy agent the counter can lag past our window,
      # so relying on it alone caused needless resends.
      for _ in $(seq 1 15); do
        [[ "$(agent_seq "$name")" != "$before" ]] && return 0
        case "$(agent_state "$name")" in working|blocked) return 0 ;; esac
        sleep 1
      done
      echo "WARN: [$name] prompt accepted but the agent did not react (attempt $attempt)." >&2
    fi
    sleep 2
  done
  return 1
}

# Checkout path of a workspace's worktree, with backslashes normalised so that
# `git -C` takes it on Windows.
worktree_path_of() {
  herdr workspace get "$1" 2>/dev/null \
    | jq -r '.result.workspace.worktree.checkout_path // .result.workspace.cwd // empty' \
    | tr '\\' '/'
}

# Path from state.json, falling back to asking herdr. State written by an older
# launch.sh has an empty string here.
resolve_worktree() {
  local from_state="$1" workspace_id="$2"
  if [[ -n "$from_state" && "$from_state" != "null" ]]; then
    printf '%s' "$from_state" | tr '\\' '/'
    return
  fi
  [[ -n "$workspace_id" && "$workspace_id" != "null" ]] && worktree_path_of "$workspace_id"
}

# --- Antigravity quota and account switching --------------------------------
#
# `agy -p "/usage"` is the only machine-readable quota source. There is no
# `agy usage` subcommand, and the slash command only expands in print mode.
# It prints tab-separated rows:
#
#   Gemini Models<TAB>Weekly Limit Remaining<TAB>80%<TAB>2026-09-04T00:18:35Z
#   Gemini Models<TAB>Five Hour Limit Remaining<TAB>22%<TAB>2026-08-28T12:31:35Z
#   Claude and GPT models<TAB>Weekly Limit Remaining<TAB>94%<TAB>...
#   Claude and GPT models<TAB>Five Hour Limit Remaining<TAB>82%<TAB>...
#
# MSYS_NO_PATHCONV=1 is not optional on Windows. Without it, Git Bash rewrites
# the leading slash and agy receives "C:/Program Files/Git/usage", which it
# treats as an ordinary prompt about a file path. The call then burns a model
# turn and returns prose instead of quota numbers.
#
# Both accounts run as you, in an ordinary herdr pane with a full TUI. agy has
# no account flag, so scripts/agy-account.ps1 swaps the OAuth credential in
# Windows Credential Manager instead: one live entry that agy reads, plus a
# vault entry per account. Two properties of that arrangement shape everything
# below.
#
# Only the live account's quota can be read. Asking about the other one means
# making it live first, which changes the machine, so it is done only once the
# live account has actually run dry.
#
# Accounts cannot be mixed. agy refreshes its token mid-session and writes it
# back to the live entry, so a running agent would overwrite a credential
# swapped in underneath it, and would itself change account. When a switch is
# needed while agents are still running, the swarm launches nothing and says so.
#
# There is no codex fallback: when both accounts are empty, nothing is launched.

SWARM_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Windows-form path, because pwsh is a native binary and does not read /d/... .
SWARM_ACCOUNT_SCRIPT="$SWARM_LIB_DIR/agy-account.ps1"
if command -v cygpath >/dev/null 2>&1; then
  SWARM_ACCOUNT_SCRIPT=$(cygpath -w "$SWARM_ACCOUNT_SCRIPT")
fi

# Where agy-account.ps1 records which account the live credential belongs to.
# After a token refresh the blob matches no vault entry, so this file is the
# only thing that knows.
swarm_state_dir() {
  local d="${LOCALAPPDATA:-}"
  [[ -n "$d" ]] || return 1
  printf '%s/herdr-swarm' "$(printf '%s' "$d" | tr '\\' '/')"
}

# The account the live credential belongs to: "a", "b", or nothing at all when
# the vault has never been set up.
account_live() {
  [[ "${HERDR_SWARM_NO_SWITCHING:-0}" == "1" ]] && return 1
  command -v pwsh >/dev/null 2>&1 || return 1
  local dir state
  dir=$(swarm_state_dir) || return 1
  state="$dir/live-account"
  [[ -f "$state" ]] || return 1
  tr -d ' \r\n' < "$state"
}

account_other() { [[ "${1:-a}" == "a" ]] && echo "b" || echo "a"; }

# Does the vault hold a credential for account $1? Read once per run: it costs
# a pwsh start, and the answer cannot change while the swarm is launching.
SWARM_ACCOUNT_LIST_CACHE="${TMPDIR:-/tmp}/herdr-swarm-accounts.$$"
account_vault_has() {
  local acct="${1:-}"
  if [[ ! -s "$SWARM_ACCOUNT_LIST_CACHE" ]]; then
    command -v pwsh >/dev/null 2>&1 || return 1
    MSYS_NO_PATHCONV=1 timeout 60 pwsh -NoProfile -File "$SWARM_ACCOUNT_SCRIPT" -Mode list \
      > "$SWARM_ACCOUNT_LIST_CACHE" 2>/dev/null || return 1
  fi
  grep -q "^vault $acct .*(empty)" "$SWARM_ACCOUNT_LIST_CACHE" && return 1
  grep -q "^vault $acct " "$SWARM_ACCOUNT_LIST_CACHE"
}

# Make account $1 live. Exit codes come straight from agy-account.ps1:
# 0 done, 3 agents are running so accounts would mix, 4 vault entry empty,
# 5 no record of which account is live.
account_switch() {
  local acct="${1:-}" out rc=0
  out=$(MSYS_NO_PATHCONV=1 timeout 60 pwsh -NoProfile -File "$SWARM_ACCOUNT_SCRIPT" \
    -Mode use -Account "$acct" 2>&1) || rc=$?
  [[ -n "$out" ]] && echo "$out" >&2
  return "$rc"
}

AGY_USAGE_CACHE_PREFIX="${TMPDIR:-/tmp}/herdr-swarm-agy-usage.$$"
trap 'rm -f "$AGY_USAGE_CACHE_PREFIX".* "$SWARM_ACCOUNT_LIST_CACHE"' EXIT

# Print the raw /usage table for one account, fetching it at most once per run.
# $1 names the account the numbers belong to, so that a table read before a
# switch is not reused after one. Only the live account can actually be asked.
agy_usage() {
  local acct="${1:-a}" cache="$AGY_USAGE_CACHE_PREFIX.${1:-a}" live
  if [[ -s "$cache" ]]; then cat "$cache"; return 0; fi
  live=$(account_live) || live=""
  [[ -z "$live" || "$live" == "$acct" ]] || return 1
  command -v agy >/dev/null 2>&1 || return 1
  MSYS_NO_PATHCONV=1 timeout 120 agy -p "/usage" 2>/dev/null > "$cache" || return 1
  grep -qE '[0-9]+%' "$cache" || return 1
  cat "$cache"
}

# Which quota pool a model draws from. The two pools run down separately, so a
# claude task keeps working after the gemini pool empties.
agy_family_for_model() {
  case "${1:-}" in
    claude-*|gpt-*) echo "Claude and GPT models" ;;
    *)              echo "Gemini Models" ;;
  esac
}

# Lowest remaining percentage across a family's windows, for one account.
# Weekly and five-hour both gate a launch, so the smaller number is the one that
# matters. $1: family, $2: account.
agy_family_remaining() {
  local family="$1" acct="${2:-a}" usage
  usage=$(agy_usage "$acct") || return 1
  awk -F'\t' -v fam="$family" '
    $1 == fam {
      pct = $3; sub(/%/, "", pct); pct += 0
      if (min == "" || pct < min) min = pct
    }
    END { if (min == "") exit 1; print min }
  ' <<<"$usage"
}

# When the empty window of a family refills again, as printed by agy (UTC).
# Only rows that actually read 0% are considered; the earliest one is the answer.
agy_family_reset() {
  local family="$1" acct="${2:-a}" usage
  usage=$(agy_usage "$acct") || return 1
  awk -F'\t' -v fam="$family" '
    $1 == fam {
      pct = $3; sub(/%/, "", pct); pct += 0
      if (pct == 0 && $4 != "" && (first == "" || $4 < first)) first = $4
    }
    END { if (first == "") exit 1; print first }
  ' <<<"$usage"
}

# Is this model out of quota on this account? 0 = yes, 1 = no, 2 = could not tell.
# A task with no model set runs on whatever agy defaults to, which the CLI does
# not report, so treat either pool being empty as a stop.
agy_exhausted() {
  local model="${1:-}" acct="${2:-a}" fam rem
  if [[ -z "$model" ]]; then
    for fam in "Gemini Models" "Claude and GPT models"; do
      rem=$(agy_family_remaining "$fam" "$acct") || return 2
      [[ "$rem" -eq 0 ]] && return 0
    done
    return 1
  fi
  fam=$(agy_family_for_model "$model")
  rem=$(agy_family_remaining "$fam" "$acct") || return 2
  [[ "$rem" -eq 0 ]]
}

# Which account should run a task on this model, switching to the other one if
# the live one has run dry? Prints the account and returns 0. Otherwise:
#   1  both accounts are empty, or there is no second account to fall back to
#   2  the quota could not be read; the printed account is a guess, so the
#      caller should warn and carry on rather than refuse to launch
#   3  a switch is needed but agents are still running, so nothing may start
agy_pick_account() {
  local model="${1:-}" live other rc=0 src=0
  live=$(account_live) || live="a"

  agy_exhausted "$model" "$live" || rc=$?
  case "$rc" in
    1) echo "$live"; return 0 ;;
    2) echo "$live"; return 2 ;;
  esac

  other=$(account_other "$live")
  account_vault_has "$other" || return 1

  account_switch "$other" || src=$?
  case "$src" in
    0) ;;
    3) return 3 ;;
    *) return 1 ;;
  esac

  rc=0
  agy_exhausted "$model" "$other" || rc=$?
  case "$rc" in
    1) echo "$other"; return 0 ;;
    2) echo "$other"; return 2 ;;
  esac
  # Both empty. The other account stays live: switching back costs a second
  # swap, and nothing is being launched either way.
  return 1
}

# Human-readable "when does this get better", for the stop-and-report message.
# Only an account whose usage table was already fetched can answer; asking the
# other one would mean another switch.
agy_reset_note() {
  local model="${1:-}" fam note="" acct reset upper
  fam=$(agy_family_for_model "$model")
  for acct in a b; do
    reset=$(agy_family_reset "$fam" "$acct" 2>/dev/null || true)
    [[ -n "$reset" ]] || continue
    upper=$(printf '%s' "$acct" | tr 'ab' 'AB')
    [[ -n "$note" ]] && note="$note, "
    note="${note}account $upper refills at $reset"
  done
  [[ -n "$note" ]] || note="agy did not report a reset time"
  printf '%s' "$note"
}

# Lifecycle state of a task. Both accounts now run in a herdr pane, so herdr's
# own output scraping is the single source of truth. $1: task name.
task_state() {
  agent_state "$1"
}
