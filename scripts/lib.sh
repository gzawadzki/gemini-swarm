#!/usr/bin/env bash
# Shared helpers for the swarm scripts.
#
# herdr's JSON field names are the fragile part here. They are not documented
# upstream and differ from what you'd guess. Two that bit us:
#   * agent status lives at .result.agent.agent_status, not .status
#   * the worktree checkout lives at .result.workspace.worktree.checkout_path,
#     not .result.workspace.cwd (which is absent)
# Keep those paths in this file only, so a herdr upgrade means one edit.

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

# --- Antigravity quota, and the codex fallback ------------------------------
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

AGY_USAGE_CACHE="${TMPDIR:-/tmp}/herdr-swarm-agy-usage.$$"
trap 'rm -f "$AGY_USAGE_CACHE"' EXIT

# Print the raw /usage table, fetching it at most once per script run.
agy_usage() {
  if [[ -s "$AGY_USAGE_CACHE" ]]; then cat "$AGY_USAGE_CACHE"; return 0; fi
  if ! command -v agy >/dev/null 2>&1; then
    trace "-" "quota.read" "no agy on PATH"
    return 1
  fi
  local rc=0
  MSYS_NO_PATHCONV=1 timeout 120 agy -p "/usage" 2>/dev/null > "$AGY_USAGE_CACHE" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    trace "-" "quota.read" "agy -p /usage -> rc=$rc"
    return 1
  fi
  # A reply with no percentages is agy answering in prose, which is what a
  # mangled slash command looks like. Worth distinguishing in the log.
  if ! grep -qE '[0-9]+%' "$AGY_USAGE_CACHE"; then
    trace "-" "quota.read" "agy -p /usage -> rc=0 but no percentages in the reply"
    return 1
  fi
  # Guarded with `if` rather than `&&`: a bare `cond && cmd` statement is the
  # last command in the function when the trace is off, so `set -e` in the
  # caller would take the whole script down on the false branch.
  if trace_enabled; then
    trace "-" "quota.read" \
      "agy -p /usage -> rc=0 ($(grep -oE '[0-9]+%' "$AGY_USAGE_CACHE" | tr '\n' ' '))"
  fi
  cat "$AGY_USAGE_CACHE"
}

# Which quota pool a model draws from. The two pools run down separately, so a
# claude task keeps working after the gemini pool empties.
agy_family_for_model() {
  case "${1:-}" in
    claude-*|gpt-*) echo "Claude and GPT models" ;;
    *)              echo "Gemini Models" ;;
  esac
}

# Lowest remaining percentage across a family's windows. Weekly and five-hour
# both gate a launch, so the smaller number is the one that matters.
agy_family_remaining() {
  local family="$1" usage
  usage=$(agy_usage) || return 1
  awk -F'\t' -v fam="$family" '
    $1 == fam {
      pct = $3; sub(/%/, "", pct); pct += 0
      if (min == "" || pct < min) min = pct
    }
    END { if (min == "") exit 1; print min }
  ' <<<"$usage"
}

# Is this model out of quota? 0 = yes, 1 = no, 2 = could not tell.
# A task with no model set runs on whatever agy defaults to, which the CLI does
# not report, so treat either pool being empty as a stop.
agy_exhausted() {
  local model="${1:-}" fam rem
  if [[ -z "$model" ]]; then
    for fam in "Gemini Models" "Claude and GPT models"; do
      rem=$(agy_family_remaining "$fam") || return 2
      [[ "$rem" -eq 0 ]] && return 0
    done
    return 1
  fi
  fam=$(agy_family_for_model "$model")
  rem=$(agy_family_remaining "$fam") || return 2
  [[ "$rem" -eq 0 ]]
}

# Model and effort the fallback runs on.
CODEX_FALLBACK_MODEL="${HERDR_SWARM_CODEX_MODEL:-gpt-5.6-luna}"
CODEX_FALLBACK_EFFORT="${HERDR_SWARM_CODEX_EFFORT:-xhigh}"

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
    if ! agy_exhausted "$model"; then printf 'agy'; return; fi
  fi
  command -v codex  >/dev/null 2>&1 && { printf 'codex';  return; }
  command -v gemini >/dev/null 2>&1 && { printf 'gemini'; return; }
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
