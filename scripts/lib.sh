#!/usr/bin/env bash
# Shared helpers for the swarm scripts.
#
# herdr's JSON field names are the fragile part here. They are not documented
# upstream and differ from what you'd guess. Two that bit us:
#   * agent status lives at .result.agent.agent_status, not .status
#   * the worktree checkout lives at .result.workspace.worktree.checkout_path,
#     not .result.workspace.cwd (which is absent)
# Keep those paths in this file only, so a herdr upgrade means one edit.

# Read one jq answer per `$(...)`, never several at once through `read`. The jq
# on this platform ends every line with CRLF. Command substitution here drops the
# trailing CR along with the newline, so `$(jq -r ...)` is clean; `read` strips
# only the newline, so a collapsed multi-field read leaves a bare CR in the last
# variable. That CR is invisible in output and non-empty to `[[ -n ]]`, which
# turned a validation check into one that rejected every task while printing an
# error message that looked blank. The per-field calls are the safe shape.

# --- Trace -------------------------------------------------------------------
#
# Off by default. Turned on with --trace on any script, or HERDR_SWARM_TRACE=1
# for a whole session. Every external call the swarm makes gets one line in
# $STATE_DIR/trace.log: what was run, against which task, and what it returned.
#
# This exists because the interesting failures here are not exceptions. A prompt
# that herdr accepts and the agent never sees, a quota read that silently fails
# open, a base ref that resolves to the branch tip and makes the diff look empty
# — all of those look like success from the outside. The trace is where you find
# out which one happened.
#
# The log goes in the state dir, never in a worktree: writing into a worktree
# would flip its CLEAN column to DIRTY and break the review gate.

# Source tag for the trace, overridden by each script (launch, verify, ...).
TRACE_SRC="${TRACE_SRC:-lib}"

trace_enabled() { [[ "${HERDR_SWARM_TRACE:-0}" == "1" ]]; }

trace_file() {
  printf '%s/trace.log' "${HERDR_SWARM_STATE_DIR:-.herdr-swarm}"
}

# trace <task> <event> [detail...]
# <task> may be "-" for events that belong to the run rather than one task.
trace() {
  trace_enabled || return 0
  local task="$1" event="$2"; shift 2
  local file; file=$(trace_file)
  mkdir -p "$(dirname "$file")" 2>/dev/null || return 0
  printf '%s %-7s %-20s %-16s %s\n' \
    "$(date -u +%FT%TZ)" "$TRACE_SRC" "$task" "$event" "$*" >> "$file" 2>/dev/null || true
}

# trace_run <task> <event> -- <cmd...>
# Runs the command, records it with its exit code, and returns that exit code so
# the caller's own error handling is unchanged. stdout/stderr pass through
# untouched, so this is safe to wrap around a command whose output is captured.
#
# The rc is captured with `|| rc=$?` rather than let through, because every call
# site here runs under `set -e` and a wrapped failure must stay the caller's
# decision to make, not an abort inside the helper.
trace_run() {
  local task="$1" event="$2"; shift 2
  [[ "${1:-}" == "--" ]] && shift
  if ! trace_enabled; then "$@"; return $?; fi
  trace "$task" "$event" "exec: $*"
  local rc=0
  "$@" || rc=$?
  trace "$task" "$event" "rc=$rc"
  return "$rc"
}

# Pull --trace / --no-trace out of a script's arguments before it reads its
# positional ones, so the flag works on every script without each of them
# growing its own parser. Results land in the ARGV array; callers do:
#   strip_trace_flag "$@"; set -- ${ARGV[@]+"${ARGV[@]}"}
strip_trace_flag() {
  ARGV=()
  local a
  for a in "$@"; do
    case "$a" in
      --trace)    HERDR_SWARM_TRACE=1 ;;
      --no-trace) HERDR_SWARM_TRACE=0 ;;
      *)          ARGV+=("$a") ;;
    esac
  done
  export HERDR_SWARM_TRACE
}

# Announce the log once per run, so a --trace invocation says where to look
# instead of leaving the user to guess.
trace_banner() {
  trace_enabled || return 0
  echo "trace: $(trace_file)" >&2
}

# Two different clocks, kept apart on purpose. `ready_timeout_ms` is how long
# herdr waits for the agent's TUI to accept input; herdr rejects anything above
# 300000 with invalid_agent_timeout, which is what a work-budget-sized value in
# this field used to cause. `work_budget_ms` is how long the task is expected to
# take, which nothing enforces: status.sh reads it to mark a task OVERDUE, so a
# hung agent stops looking identical to a thinking one.
MAX_READY_TIMEOUT_MS=300000
DEFAULT_READY_TIMEOUT_MS=60000
DEFAULT_WORK_BUDGET_MS=900000

# Briefs live outside every repo and worktree, so writing one cannot dirty a
# tree that status.sh checks, and the path stays valid from any worktree.
BRIEF_DIR="${HERDR_SWARM_BRIEF_DIR:-$HOME/.herdr/briefs}"

# The agents are native Windows binaries under Git Bash, and they read an MSYS
# path like /c/Users/... as C:\Users\... relative to their own root, so a file
# handed over that way is invisible to them. Give them the form their OS agrees
# with; Git Bash reads C:/... back fine, so one form serves both.
to_native() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

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
  # Bytes, not the prompt itself: the trace is meant to be readable and to stay
  # safe to paste, and a full brief in the log would be neither.
  trace "$name" "prompt.submit" "${#text} bytes"
  for attempt in 1 2; do
    before=$(agent_seq "$name")
    resp=$(herdr agent prompt "$name" "$text" 2>&1)
    type=$(jq -r '.result.type // empty' <<<"$resp" 2>/dev/null || true)
    if [[ "$type" != "agent_prompted" ]]; then
      trace "$name" "prompt.submit" "attempt $attempt rejected by herdr: $resp"
      echo "WARN: [$name] herdr rejected the prompt: $resp" >&2
    else
      # Two independent signals that it landed: the change counter moved, or the
      # agent left idle. On a busy agent the counter can lag past our window,
      # so relying on it alone caused needless resends.
      for _ in $(seq 1 15); do
        if [[ "$(agent_seq "$name")" != "$before" ]]; then
          trace "$name" "prompt.landed" "state_change_seq moved (attempt $attempt)"
          return 0
        fi
        case "$(agent_state "$name")" in
          working|blocked)
            trace "$name" "prompt.landed" "agent left idle (attempt $attempt)"
            return 0
            ;;
        esac
        sleep 1
      done
      trace "$name" "prompt.stalled" "herdr accepted it, agent did not react in 15s (attempt $attempt)"
      echo "WARN: [$name] prompt accepted but the agent did not react (attempt $attempt)." >&2
    fi
    sleep 2
  done
  trace "$name" "prompt.lost" "both attempts failed"
  return 1
}

# Close an agent's TUI and wait until herdr no longer knows it.
# herdr has no `agent stop`, so the only way out of an agy session is the
# interrupt the TUI itself listens for. Two details are load-bearing: the key
# name is "ctrl+c" ("ctrl-c" comes back as "unsupported key"), and both presses
# must go in one send-keys call. Sent as two calls with a sleep between them the
# second is mostly swallowed and the pane stays open (measured on 12 panes: 12
# -> 11 -> 10 over several rounds). Returns non-zero if the agent is still there
# after $2 seconds.
agent_close() {
  local name="$1" tries="${2:-15}"
  [[ "$(agent_state "$name")" == "unreachable" ]] && return 0
  herdr agent send-keys "$name" "ctrl+c" "ctrl+c" >/dev/null 2>&1 || true
  for _ in $(seq 1 "$tries"); do
    [[ "$(agent_state "$name")" == "unreachable" ]] && return 0
    sleep 1
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

# The commit a task's branch is measured against. launch.sh pins base_sha at
# worktree-creation time, which is the only reliable answer: inside the task's
# own worktree HEAD *is* the task branch, so resolving the base from there gives
# back the branch tip and every diff comes out empty. Returns non-zero when no
# usable base exists, rather than printing a ref the caller cannot diff against.
resolve_base_ref() {
  local entry="$1" worktree="$2" base_ref base name="-"
  if trace_enabled; then name=$(jq -r '.name // "-"' <<<"$entry"); fi
  base_ref=$(jq -r '.base_sha // ""' <<<"$entry")
  if [[ -z "$base_ref" ]]; then
    # State written before base_sha existed, or an unresolvable base ref.
    base=$(jq -r '.base // ""' <<<"$entry")
    base_ref="$base"
    if [[ -z "$base_ref" || "$base_ref" == "HEAD" ]]; then
      base_ref=$(git -C "$worktree" rev-list --max-parents=0 HEAD 2>/dev/null | tail -1)
    fi
  fi
  if [[ -z "$base_ref" ]]; then
    trace "$name" "base.resolve" "no usable base in state"
    return 1
  fi
  if ! git -C "$worktree" rev-parse --verify --quiet "${base_ref}^{commit}" >/dev/null; then
    trace "$name" "base.resolve" "'$base_ref' is not a commit in $worktree"
    return 1
  fi
  trace "$name" "base.resolve" "${base_ref:0:12}"
  printf '%s' "$base_ref"
}

# The flag that turns off every confirmation for an agent kind. Lives here
# because both launch.sh (interactive agents) and critique.sh (one-shot print
# mode) need the same answer.
autoflag_for_kind() {
  case "$1" in
    gemini) echo "--yolo" ;;
    agy)    echo "--dangerously-skip-permissions" ;;
    codex)  echo "--dangerously-bypass-approvals-and-sandbox" ;;
    *)      echo "ERROR: unsupported kind '$1' (expected 'gemini', 'agy' or 'codex')" >&2; return 1 ;;
  esac
}

# --- Antigravity quota, account switching, and the codex fallback -----------
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
# Codex is the last resort, not the first: a task only falls back to it once
# both accounts are empty for its pool, or when switching is switched off.
# HERDR_SWARM_NO_FALLBACK=1 turns that off too, and then nothing is launched.

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

# Is the swarm allowed to change accounts at all? The opt-out has to gate the
# swap itself, not just the lookup: account_live falling back to "a" when
# switching is off would otherwise still let a swap through.
account_switching_enabled() { [[ "${HERDR_SWARM_NO_SWITCHING:-0}" != "1" ]]; }

# Make account $1 live. Exit codes come straight from agy-account.ps1:
# 0 done, 3 agents are running so accounts would mix, 4 vault entry empty,
# 5 no record of which account is live.
account_switch() {
  local acct="${1:-}" out rc=0
  account_switching_enabled || return 6
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
  local acct="${1:-a}" cache="$AGY_USAGE_CACHE_PREFIX.${1:-a}" live rc=0
  if [[ -s "$cache" ]]; then cat "$cache"; return 0; fi
  # With no state file the live account is unknown, and the rest of the code
  # assumes "a" in that case. Assume it here too: without this, /usage answers
  # for whoever is signed in and the numbers get filed under the account that
  # was asked about, so a report can claim account B is empty when there is no
  # account B at all.
  live=$(account_live) || live="a"
  [[ "$live" == "$acct" ]] || return 1
  if ! command -v agy >/dev/null 2>&1; then
    trace "-" "quota.read" "no agy on PATH"
    return 1
  fi
  MSYS_NO_PATHCONV=1 timeout 120 agy -p "/usage" 2>/dev/null > "$cache" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    trace "-" "quota.read" "account $acct: agy -p /usage -> rc=$rc"
    rm -f "$cache"
    return 1
  fi
  # A reply with no percentages is agy answering in prose, which is what a
  # mangled slash command looks like. Worth distinguishing in the log.
  if ! grep -qE '[0-9]+%' "$cache"; then
    trace "-" "quota.read" "account $acct: agy -p /usage -> rc=0 but no percentages in the reply"
    rm -f "$cache"
    return 1
  fi
  # Guarded with `if` rather than `&&`: a bare `cond && cmd` statement is the
  # last command in the function when the trace is off, so `set -e` in the
  # caller would take the whole script down on the false branch.
  if trace_enabled; then
    trace "-" "quota.read" \
      "account $acct: agy -p /usage -> rc=0 ($(grep -oE '[0-9]+%' "$cache" | tr '\n' ' '))"
  fi
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
#   4  a switch is needed but HERDR_SWARM_NO_SWITCHING=1 forbids it
agy_pick_account() {
  local model="${1:-}" live other rc=0 src=0
  live=$(account_live) || live="a"

  agy_exhausted "$model" "$live" || rc=$?
  case "$rc" in
    1) echo "$live"; return 0 ;;
    2) echo "$live"; return 2 ;;
  esac

  account_switching_enabled || return 4

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

# Model and effort the fallback runs on.
CODEX_FALLBACK_MODEL="${HERDR_SWARM_CODEX_MODEL:-gpt-5.6-luna}"
CODEX_FALLBACK_EFFORT="${HERDR_SWARM_CODEX_EFFORT:-max}"

# Extra arguments for every codex the swarm starts. User plugins such as caveman
# inject SessionStart hooks that change how the model writes, which is fine in a
# person's own session and wrong in a worker whose result file and commit
# messages another model has to parse. Per-plugin `-c plugins."x".enabled=false`
# overrides were measured to leave the rendered prompt unchanged, so this turns
# the plugin system off for the run instead. It does not touch
# ~/.codex/config.toml, and it does not stop ~/.codex/AGENTS.md from loading.
# HERDR_SWARM_CODEX_PLUGINS=1 keeps plugins on.
codex_swarm_args() {
  [[ "${HERDR_SWARM_CODEX_PLUGINS:-0}" == "1" ]] || printf '%s\n' --disable plugins
}

# --- Egress verification gate -----------------------------------------------
#
# The review step is the only thing between an auto-approving agent and the
# user's branch, and it costs Claude a full read of every diff. Most of what it
# would catch is mechanical: a task that broke the build or failed its own tests
# should never reach that read. verify.sh runs a deterministic check inside the
# worktree first, so Claude only spends attention on diffs that already pass.
#
# The check command comes from, in order: the task's own `verify` field, then a
# cheap auto-detection from the worktree's project files. A repo with no
# recognisable test command yields nothing, and the gate reports "skipped"
# rather than failing, so an unknown stack never blocks review outright.

# Path where verify.sh caches a task's result, read back by status.sh.
verify_file_for() {
  printf '%s/%s.verify.json' "${HERDR_SWARM_STATE_DIR:-.herdr-swarm}" "$1"
}

# Guess a test/build command from the files in a worktree. Prints nothing when
# it recognises no stack, which the caller treats as "skip", not "fail".
detect_verify_cmd() {
  local wt="$1"
  if [[ -f "$wt/package.json" ]]; then
    # Only claim a test command if the project actually defines one.
    if jq -e '.scripts.test // empty' "$wt/package.json" >/dev/null 2>&1; then
      if   [[ -f "$wt/pnpm-lock.yaml" ]]; then echo "pnpm test"
      elif [[ -f "$wt/yarn.lock" ]];      then echo "yarn test"
      else echo "npm test --silent"; fi
      return
    fi
  fi
  if [[ -f "$wt/pyproject.toml" || -f "$wt/pytest.ini" || -f "$wt/setup.cfg" || -d "$wt/tests" ]]; then
    echo "pytest -q"; return
  fi
  if [[ -f "$wt/Cargo.toml" ]];  then echo "cargo test --quiet"; return; fi
  if [[ -f "$wt/go.mod" ]];      then echo "go test ./..."; return; fi
  if [[ -f "$wt/Makefile" ]] && grep -qE '^test:' "$wt/Makefile" 2>/dev/null; then
    echo "make test"; return
  fi
}

# The verify command for a task: its explicit `verify` field, else detection.
# --- Verify soundness --------------------------------------------------------
#
# A green verify means nothing unless the code it exercised came from the task's
# own worktree. An editable install pins imports to a fixed path, so a suite run
# inside a worktree can import the package from the main checkout and pass on a
# diff it never touched. That happened: one project was saved by a `pythonpath`
# line in its config, by accident rather than design.
#
# Sets SOUNDNESS to one of:
#   sound    the module under test resolved inside the worktree
#   unsound  it resolved somewhere else, and SOUNDNESS_DETAIL says where
#   unknown  this project's resolution could not be established at all
# and SOUNDNESS_DETAIL to a sentence naming what was found.
#
# `unknown` is deliberately common. The mechanism below covers Python, which is
# the only ecosystem where the trap has actually been observed; everywhere else
# the honest answer is that nothing was established, and the caller must not
# turn that into a pass. Widening it means adding a positive check per
# ecosystem, never assuming soundness because a language looks safe.
check_verify_soundness() {  # <worktree>
  local worktree="$1"
  SOUNDNESS="unknown"
  SOUNDNESS_DETAIL=""

  local pyproject="$worktree/pyproject.toml"
  if [[ ! -f "$pyproject" ]]; then
    SOUNDNESS_DETAIL="no pyproject.toml in the worktree, and only Python resolution can be checked so far"
    return 0
  fi
  if ! command -v python >/dev/null 2>&1; then
    SOUNDNESS_DETAIL="no python on PATH to ask where the package resolves from"
    return 0
  fi

  # The distribution name, turned into the module name the way packaging does.
# `sed ... | head -1` looked equivalent and was not: head closes the pipe once it
  # has its line, sed takes SIGPIPE, and under `set -o pipefail` the bare
  # assignment goes non-zero, so `set -e` kills verify.sh after the tests ran and
  # before any result is cached. Measured: exit 141, no result file.
  local module names=()
  mapfile -t names < <(sed -n -e "s/^[[:space:]]*name[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
                              -e "s/^[[:space:]]*name[[:space:]]*=[[:space:]]*'\([^']*\)'.*/\1/p" "$pyproject")
  module="${names[0]:-}"
  module=${module//-/_}
  module=${module//./_}
  if [[ -z "$module" ]]; then
    SOUNDNESS_DETAIL="pyproject.toml declares no project name, so there is no module to resolve"
    return 0
  fi

  # find_spec rather than import: it answers the same question without running
  # the package's import side effects inside the gate.
  #
  # Run from anywhere except the worktree. `python -c` puts its working directory
  # first on sys.path, so probing inside the worktree finds the worktree's own
  # package whatever the installed distribution points at - measured: with an
  # install pinned to another checkout, the same probe answered "worktree" from
  # the worktree and "other checkout" from outside it. Probing in the worktree
  # therefore fails towards `sound`, which is the one answer this check exists to
  # be unable to give falsely.
  local origin probe_rc=0
  origin=$(cd / && python -c \
    "import importlib.util as u
s = u.find_spec('$module')
print(s.origin if s and s.origin else '')" 2>/dev/null) || probe_rc=$?
  origin=${origin%$'\r'}
  if (( probe_rc != 0 )); then
    SOUNDNESS_DETAIL="python exited $probe_rc while resolving module '$module', so nothing was established"
    return 0
  fi
  if [[ -z "$origin" ]]; then
    # A flat-layout project with no install lands here: the suite may well import
    # correctly from its own directory, but nothing about that is established
    # from outside it, and a guess in either direction would be a claim.
    SOUNDNESS_DETAIL="module '$module' could not be resolved from outside the worktree, so where the tests imported it from is unknown"
    return 0
  fi

  # python is a native binary here and answers with a native path, while the
  # worktree is an MSYS one. Compare both in the same form, case-insensitively,
  # because Windows paths differ in case without differing.
  local wt_native="$worktree"
  command -v cygpath >/dev/null 2>&1 && wt_native=$(cygpath -m "$worktree" 2>/dev/null || echo "$worktree")
  origin=${origin//\\//}
  wt_native=${wt_native//\\//}
  wt_native=${wt_native%/}
  if [[ "${origin,,}" == "${wt_native,,}/"* ]]; then
    SOUNDNESS="sound"
    SOUNDNESS_DETAIL="module '$module' resolved to $origin, inside the worktree"
  else
    SOUNDNESS="unsound"
    SOUNDNESS_DETAIL="module '$module' resolved to $origin, which is outside the worktree $wt_native"
  fi
  return 0
}

resolve_verify_cmd() {
  local from_task="$1" worktree="$2"
  if [[ -n "$from_task" && "$from_task" != "null" ]]; then
    printf '%s' "$from_task"; return
  fi
  [[ -n "$worktree" && -d "$worktree" ]] && detect_verify_cmd "$worktree"
}

# --- Machine critique, the judgement half of the gate ------------------------
#
# verify.sh answers "does it still build and pass tests". It cannot answer "is
# this the change that was asked for", and that is the question that actually
# costs the orchestrator a full diff read. critique.sh puts a cheap model on it
# first, running one-shot print mode on the Antigravity Gemini pool, so a diff
# that ignored half the task or quietly deleted a test gets bounced back to its
# author without spending any of the orchestrator's attention.
#
# This advises, it never approves. A `pass` here means one cheap model found
# nothing, which is weaker evidence than a test run, so it narrows what needs
# reading rather than replacing the read.

# Model the critique runs on. Deliberately a flash tier: the job is spotting
# obvious divergence from the brief, not out-reasoning the agent that wrote it.
CRITIQUE_MODEL="${HERDR_SWARM_CRITIQUE_MODEL:-gemini-3.8-flash-high}"
CRITIQUE_EFFORT="${HERDR_SWARM_CRITIQUE_EFFORT:-medium}"
CRITIQUE_TIMEOUT="${HERDR_SWARM_CRITIQUE_TIMEOUT:-600}"

# A model reviewing its own output shares its own blind spots, so a task that
# was written by CRITIQUE_MODEL is reviewed by this one instead. It stays on the
# Gemini pool so the swap costs no Claude/GPT quota.
CRITIQUE_ALT_MODEL="${HERDR_SWARM_CRITIQUE_ALT_MODEL:-gemini-3.1-pro-high}"

# The reviewer model for a task written by $1. Prints CRITIQUE_MODEL unless that
# is the worker's own model, in which case it prints CRITIQUE_ALT_MODEL.
critique_model_for() {
  if [[ -n "$1" && "$1" == "$CRITIQUE_MODEL" ]]; then
    printf '%s' "$CRITIQUE_ALT_MODEL"
  else
    printf '%s' "$CRITIQUE_MODEL"
  fi
}

# Diffs are pasted into the brief, and a giant one both blows the prompt budget
# and buries the signal. Past this many lines the brief is truncated and the
# reviewer is told to read the repo itself, which it has open anyway.
CRITIQUE_DIFF_LINES="${HERDR_SWARM_CRITIQUE_DIFF_LINES:-1500}"

# Path where critique.sh caches a task's verdict, read back by status.sh.
critique_file_for() {
  printf '%s/%s.critique.json' "${HERDR_SWARM_STATE_DIR:-.herdr-swarm}" "$1"
}

# Which binary runs the critique. Prefers agy on the Gemini pool, drops to codex
# when that pool is empty, and to classic gemini when agy is not installed.
# Prints nothing when no usable binary exists.
critique_kind_for() {
  local model="$1"
  if [[ -n "${HERDR_SWARM_CRITIQUE_KIND:-}" ]]; then
    printf '%s' "$HERDR_SWARM_CRITIQUE_KIND"; return
  fi
  if command -v agy >/dev/null 2>&1; then
    # agy_exhausted returns 2 when the quota cannot be read; only a definite 0%
    # should push the critique onto another pool.
    # Only the live account's quota can be read, so ask about that one.
    if ! agy_exhausted "$model" "$(account_live || echo a)"; then printf 'agy'; return; fi
  fi
  command -v codex  >/dev/null 2>&1 && { printf 'codex';  return; }
  command -v gemini >/dev/null 2>&1 && { printf 'gemini'; return; }
}

# --- Trim review, on demand ---------------------------------------------------
#
# A separate, optional pass after review.sh: a cheap model reads the diff only
# for overengineering (speculative abstraction, unused options, needless layers,
# dead code) and suggests cuts. It is advice for the orchestrator, never a gate.
# It does not judge correctness, never blocks, and never edits the worktree.
# Running YAGNI as an always-on filter makes agents cut corners that matter, so
# it lives here, after the correctness review, and only when someone asks.

TRIM_MODEL="${HERDR_SWARM_TRIM_MODEL:-$CRITIQUE_MODEL}"
TRIM_TIMEOUT="${HERDR_SWARM_TRIM_TIMEOUT:-$CRITIQUE_TIMEOUT}"

# Path where trim.sh caches a task's suggestions, read back by review.sh.
trim_file_for() {
  printf '%s/%s.trim.json' "${HERDR_SWARM_STATE_DIR:-.herdr-swarm}" "$1"
}

# Pull the first complete JSON object out of a model's reply. Models wrap JSON
# in prose or ``` fences however firmly the prompt forbids it, so treat that as
# the normal case rather than as a failure. Fences carry no braces, so scanning
# from the first { to the last } steps over them. Exits non-zero when the reply
# has no brace pair at all; the caller still has to validate what comes out.
extract_json() {
  awk '
    { buf = buf $0 "\n" }
    END {
      s = index(buf, "{")
      if (s == 0) exit 1
      for (i = length(buf); i > s; i--) {
        if (substr(buf, i, 1) == "}") { e = i; break }
      }
      if (e == 0) exit 1
      printf "%s", substr(buf, s, e - s + 1)
    }
  '
}
