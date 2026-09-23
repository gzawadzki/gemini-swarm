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

SWARM_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#
# Off by default. Turned on with --trace on any script, or HERDR_SWARM_TRACE=1
# for a whole session. Every external call the swarm makes gets one line in
# $STATE_DIR/trace.log: what was run, against which task, and what it returned.
#
# This exists because the interesting failures here are not exceptions. A prompt
# that herdr accepts and the agent never sees, or a base ref that resolves to
# the branch tip and makes the diff look empty, can look like success from the
# outside. The trace is where you find out which one happened.
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

# Pull --trace, --no-trace, and worker permission override flags out of arguments.
# Scoped to launch.sh for worker orchestration.
strip_launch_flags() {
  ARGV=()
  local a
  for a in "$@"; do
    case "$a" in
      --trace)    HERDR_SWARM_TRACE=1 ;;
      --no-trace) HERDR_SWARM_TRACE=0 ;;
      --allow-unsandboxed|--dangerously-allow-unsandboxed)
                  HERDR_SWARM_ALLOW_UNSANDBOXED=1 ;;
      *)          ARGV+=("$a") ;;
    esac
  done
  export HERDR_SWARM_TRACE
  export HERDR_SWARM_ALLOW_UNSANDBOXED
}

# Announce the log once per run, so a --trace invocation says where to look
# instead of leaving the user to guess.
trace_banner() {
  trace_enabled || return 0
  echo "trace: $(trace_file)" >&2
}

# --- Worker permissions and sandboxing ---------------------------------------
#
# Workers run unattended in background herdr panes. Neither git worktrees nor
# Pi --approve or --tools provide OS isolation: bash tool execution has full
# ambient privileges over host files, network, and secrets.
#
# An enforceable sandbox requires platform/herdr support. Where no real OS sandbox
# is available, execution runs unsandboxed. launch.sh fails closed unless the
# operator explicitly permits unsandboxed worker execution for that run.

worker_sandbox_available() {
  # Returns 0 only if an enforceable OS sandbox is available.
  # Neither git worktrees nor Pi --tools/--approve are OS isolation.
  return 1
}

worker_unsandboxed_allowed() {
  [[ "${HERDR_SWARM_ALLOW_UNSANDBOXED:-0}" == "1" ]]
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
# herdr has no `agent stop`, so the way out of an interactive session is the
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
    pi)     echo "--approve" ;;
    codex)  echo "--dangerously-bypass-approvals-and-sandbox" ;;
    *)      echo "ERROR: unsupported kind '$1' (expected 'gemini', 'pi' or 'codex')" >&2; return 1 ;;
  esac
}

# Pi's Antigravity provider exposes a public model ID and a separate thinking
# level. Older Antigravity CLI slugs encode that level in the model name.
pi_model_args() {
  local model="${1:-gemini-3.8-flash-high}" thinking="${2:-}"
  case "$model" in
    gemini-*-low|gemini-*-medium|gemini-*-high)
      [[ -n "$thinking" ]] || thinking="${model##*-}"
      model="${model%-*}" ;;
    claude-*-thinking)
      [[ -n "$thinking" ]] || thinking=high
      model="${model%-thinking}" ;;
    gpt-oss-*-medium)
      [[ -n "$thinking" ]] || thinking=medium
      model="${model%-medium}" ;;
  esac
  printf '%s\n' --provider antigravity --model "$model"
  [[ -n "$thinking" ]] && printf '%s\n' --thinking "$thinking"
  return 0
}

# Lifecycle state of a task. Herdr's output scraping is the source of truth.
# $1: task name.
task_state() {
  agent_state "$1"
}

# Model and effort for explicit Codex tasks and reviews.
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
# --- Scope and size ----------------------------------------------------------
#
# What a task's diff touched beyond the files it declared, and how big that diff
# came out. Both are advisory and neither ever blocks: legitimate strays exist (a
# new test file, a package import) and a false bounce costs more than reading the
# line, while an oversized diff is already written by the time anyone sees it, so
# refusing it does not make it smaller. The value is the next task being narrower.
#
# One reader, because status.sh and review.sh both report this and two
# implementations would eventually disagree about the same diff.
#
# Sets:
#   SCOPE_STRAYS    files touched that no declared entry covers, newline separated
#   SCOPE_STRAY_COUNT  how many, so a caller need not count the text
#   SCOPE_LINES     added plus deleted lines across the whole diff
#   SCOPE_OVERSIZE  yes when SCOPE_LINES is above the guideline, else empty
#   SCOPE_READABLE  yes when the diff could be read at all; nothing is reported
#                   when it could not, rather than reporting "no strays"
#
# A declared entry ending in "/" covers everything beneath it; anything else has
# to match the path exactly. Nothing declared means nothing can be outside it,
# which keeps tasks written before the schema silent instead of listing every
# file they touched.
# Two numbers, not one. The aim is what a task should be written to fit; the
# call-out threshold is where a diff is wide enough to say the task was more than
# one slice. Collapsing them makes a 410-line diff - an ordinary well-sized task -
# announce that it was too wide, which is the false traffic that teaches an
# operator to stop reading the report.
#
# HERDR_SWARM_DIFF_LINES moves the aim for a project whose slices are honestly
# wider, and the threshold follows it. Neither value blocks anything at any
# setting: this reports, it never refuses.
SCOPE_SIZE_AIM="${HERDR_SWARM_DIFF_LINES:-400}"
SCOPE_SIZE_LIMIT=$(( SCOPE_SIZE_AIM * 3 / 2 ))

scope_report() {  # <entry> <worktree>
  local entry="$1" worktree="$2"
  SCOPE_STRAYS=""
  SCOPE_STRAY_COUNT=0
  SCOPE_LINES=0
  SCOPE_OVERSIZE=""
  SCOPE_READABLE=""

  [[ -n "$worktree" && -d "$worktree" ]] || return 0
  local base_ref
  base_ref=$(resolve_base_ref "$entry" "$worktree") || return 0

  # Through a file rather than a process substitution, for two reasons. `mapfile`
  # reports its own exit status, never the substituted command's, so
  # `mapfile < <(git ...) || return` can never fire: a failed git would yield zero
  # rows and be reported as "nothing outside the declared files", which is the one
  # answer this reader must not invent. And `-z` output carries NUL bytes, which a
  # command substitution cannot hold at all.
  local rows=() row add del path
  local raw; raw=$(mktemp 2>/dev/null) || return 0
  if ! git -C "$worktree" diff --numstat -z "${base_ref}...HEAD" >"$raw" 2>/dev/null; then
    rm -f "$raw"
    return 0
  fi
  # -z because the plain form renders a rename as `old => new` in the path field
  # and C-quotes any path with a space, a tab or a non-ASCII byte: both shapes
  # compare unequal to every declared entry, so every rename came out a stray.
  mapfile -d '' -t rows < "$raw"
  rm -f "$raw"
  SCOPE_READABLE="yes"

  # jq ends every line with CRLF here, and mapfile keeps the CR - the rule at the
  # top of this file, which costs a silent miscompare rather than an error: every
  # declared path would look different from the one git reported and each would be
  # named a stray.
  local declared=() d covered strays=() i
  mapfile -t declared < <(jq -r '.files // [] | .[]' <<<"$entry" 2>/dev/null)
  for i in "${!declared[@]}"; do declared[$i]=${declared[$i]%$'\r'}; done

  local i=0 n_rows=${#rows[@]}
  while (( i < n_rows )); do
    # `i=$(( i + 1 ))`, never `(( i++ ))`: post-increment evaluates to the old
    # value, so the arithmetic command returns 1 when i is 0 and `set -e` kills
    # the caller after the status table has already printed.
    row=${rows[$i]}; i=$(( i + 1 ))
    [[ -n "$row" ]] || continue
    # Each record is <added> TAB <deleted> TAB <path>. A rename leaves the path
    # empty and follows with two more records, the old name then the new one.
    add=${row%%$'\t'*}; row=${row#*$'\t'}
    del=${row%%$'\t'*}; path=${row#*$'\t'}
    if [[ -z "$path" ]]; then
      (( i < n_rows )) && i=$(( i + 1 ))
      if (( i < n_rows )); then path=${rows[$i]}; i=$(( i + 1 )); fi
      [[ -n "$path" ]] || continue
    fi
    # A binary file reports "-" for both counts and contributes no lines.
    [[ "$add" == "-" ]] && add=0
    [[ "$del" == "-" ]] && del=0
    SCOPE_LINES=$(( SCOPE_LINES + add + del ))

    (( ${#declared[@]} > 0 )) || continue
    covered=""
    for d in "${declared[@]}"; do
      [[ -n "$d" ]] || continue
      if [[ "$d" == */ ]]; then
        [[ "$path" == "$d"* ]] && { covered=1; break; }
      else
        [[ "$path" == "$d" ]] && { covered=1; break; }
      fi
    done
    [[ -n "$covered" ]] || strays+=("$path")
  done

  SCOPE_STRAY_COUNT=${#strays[@]}
  (( ${#strays[@]} > 0 )) && SCOPE_STRAYS=$(printf '%s\n' "${strays[@]}")
  (( SCOPE_LINES > SCOPE_SIZE_LIMIT )) && SCOPE_OVERSIZE="yes"
  return 0
}

# The lines both views print, or nothing at all when there is nothing to say.
# Shared so the two cannot word the same finding differently. $1 is the prefix
# each view indents with.
scope_lines() {  # <prefix>
  local prefix="${1:-}"
  [[ -n "$SCOPE_READABLE" ]] || return 0
  if [[ -n "$SCOPE_STRAYS" ]]; then
    # One line per finding. Each view says "advisory" once in its own header:
    # repeating it per task teaches the operator to skim past the block.
    printf '%soutside the declared list: %s\n' "$prefix" "$(tr '\n' ' ' <<<"$SCOPE_STRAYS" | sed 's/ $//')"
  fi
  if [[ -n "$SCOPE_OVERSIZE" ]]; then
    printf '%s%s lines changed, well past the %s-line guideline: the task was wider than one slice\n' \
      "$prefix" "$SCOPE_LINES" "$SCOPE_SIZE_AIM"
  fi
  return 0
}

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
# this the change that was asked for". critique.sh first gives a verified,
# bounded diff to Jev as typed risk questions. A clean answer may approve it;
# everything else falls through to the existing generative reviewer. Neither
# path merges or edits the user's branch.

# Model the critique runs on. Deliberately a flash tier: the job is spotting
# obvious divergence from the brief, not out-reasoning the agent that wrote it.
CRITIQUE_MODEL="${HERDR_SWARM_CRITIQUE_MODEL:-gemini-3.8-flash-high}"
CRITIQUE_EFFORT="${HERDR_SWARM_CRITIQUE_EFFORT:-medium}"
CRITIQUE_TIMEOUT="${HERDR_SWARM_CRITIQUE_TIMEOUT:-600}"

# Jev is the fast path through the judgement gate. A configured API key enables
# it by default; unset the flag to return to the generative-only path. The
# threshold is P(problem), so lower is stricter. Keep the model configurable:
# once a threshold is calibrated against a version, pin that version here.
JEV_AUTO_ACCEPT="${HERDR_SWARM_JEV_AUTO_ACCEPT:-1}"
JEV_ACCEPT_MAX="${HERDR_SWARM_JEV_ACCEPT_MAX:-0.10}"
JEV_MODEL="${HERDR_SWARM_JEV_MODEL:-}"
JEV_TIMEOUT="${HERDR_SWARM_JEV_TIMEOUT:-60}"

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

# Which binary runs the critique. Prefer Pi with the Antigravity provider,
# then Codex and classic Gemini when Pi is not installed.
# Prints nothing when no usable binary exists.
critique_kind_for() {
  local model="$1"
  if [[ -n "${HERDR_SWARM_CRITIQUE_KIND:-}" ]]; then
    printf '%s' "$HERDR_SWARM_CRITIQUE_KIND"; return
  fi
  command -v pi >/dev/null 2>&1 && { printf 'pi'; return; }
  command -v codex  >/dev/null 2>&1 && { printf 'codex';  return; }
  command -v gemini >/dev/null 2>&1 && { printf 'gemini'; return; }
}

# --- Run archive --------------------------------------------------------------
#
# A run's evidence outlives the run. cleanup.sh used to be the end of it: it
# closed the panes and removed the worktrees, and with them went the diffs, the
# gate verdicts and the config that said how each task was defined. Reconstructing
# a run afterwards meant working from memory, which is also why the model-default
# decision had nothing to compare against.
#
# The archive lives beside the briefs, outside every working repository, because
# writing into a worktree flips its CLEAN column to DIRTY and the archive is
# written while the worktrees are still being judged.

RUN_DIR="${HERDR_SWARM_RUN_DIR:-$HOME/.herdr/runs}"

# Run-level facts launch.sh records once and cleanup.sh reads back: the run id,
# the config as launched, and which version of the skill ran it. Kept next to
# state.json rather than inside it, because state.json is a per-task array that
# four scripts iterate and a run-level object does not belong in it.
run_meta_file() {
  printf '%s/run.json' "${HERDR_SWARM_STATE_DIR:-.herdr-swarm}"
}

# The run's identity, which is the moment it launched. State written before
# run.json existed has to be named something, and the earliest task's start is
# the same instant by a different route; a state file with neither falls back to
# now, so an old run still archives rather than refusing.
run_id_for() {  # <state-file>
  local state_file="$1" id started
  id=$(jq -r '.run_id // empty' "$(run_meta_file)" 2>/dev/null || true)
  if [[ -n "$id" ]]; then printf '%s' "$id"; return; fi
  started=$(jq -r '[.[].started_at // empty] | min // empty' "$state_file" 2>/dev/null || true)
  if [[ -n "$started" ]]; then
    date -u -d "@$started" +%Y%m%dT%H%M%SZ 2>/dev/null && return
  fi
  date -u +%Y%m%dT%H%M%SZ
}

run_archive_dir() {  # <state-file>
  printf '%s/%s' "$RUN_DIR" "$(run_id_for "$1")"
}

# Copy the evidence for one run into <dir>. Every step is individually best
# effort: a task whose worktree is already gone still contributes its verdicts,
# and one unreadable diff must not cost the rest of the record.
_archive_collect() {  # <dir> <state-file>
  local dir="$1" state_file="$2" meta n i entry name worktree base_ref
  meta=$(run_meta_file)

  cp "$state_file" "$dir/state.json" 2>/dev/null || true
  if [[ -f "$meta" ]]; then
    cp "$meta" "$dir/run.json" 2>/dev/null || true
    # The config as launched, not as it sits on disk now: the file the
    # orchestrator wrote is routinely edited or deleted between runs.
    jq '.config // {}' "$meta" > "$dir/tasks.json" 2>/dev/null || true
  fi
  # `if`, not `&&`: under the callers' `set -e` a missing trace log would abort
  # the collection here and cost the rest of the record.
  if [[ -f "$(trace_file)" ]]; then cp "$(trace_file)" "$dir/trace.log" 2>/dev/null || true; fi

  # A snapshot, not a live view. status.sh reads git and the cached verdicts and
  # spawns nothing, so this costs no quota; its failure costs no archive.
  "$SWARM_LIB_DIR/status.sh" "$state_file" > "$dir/status.txt" 2>&1 || true

  n=$(jq 'length' "$state_file" 2>/dev/null || echo 0)
  for i in $(seq 0 $((n - 1))); do
    entry=$(jq -c ".[$i]" "$state_file")
    name=$(jq -r '.name' <<<"$entry")
    cp "$(verify_file_for "$name")"   "$dir/$name.verify.json"   2>/dev/null || true
    cp "$(critique_file_for "$name")" "$dir/$name.critique.json" 2>/dev/null || true
    cp "${HERDR_SWARM_STATE_DIR:-.herdr-swarm}/$name.critique.jev-request.json" \
       "$dir/$name.critique.jev-request.json" 2>/dev/null || true
    cp "${HERDR_SWARM_STATE_DIR:-.herdr-swarm}/$name.critique.jev-response.json" \
       "$dir/$name.critique.jev-response.json" 2>/dev/null || true
    worktree=$(resolve_worktree "$(jq -r '.worktree_path // empty' <<<"$entry")" \
                                "$(jq -r '.workspace_id // empty' <<<"$entry")")
    [[ -n "$worktree" && -d "$worktree" ]] || continue
    base_ref=$(resolve_base_ref "$entry" "$worktree") || continue
    git -C "$worktree" diff "${base_ref}...HEAD" > "$dir/$name.diff" 2>/dev/null || true
  done
}

# Write the run's archive and print where it went. Built in a staging directory
# and moved into place, so the run id never names a directory that collection is
# still filling, and a second cleanup - run once the worktrees are gone and the
# diffs with them - finds the first archive there and leaves it alone rather than
# overwriting it with less.
#
# Returns non-zero only when nothing could be written at all. Callers treat that
# as a warning, because losing the record is not a reason to leave panes open.
archive_run() {  # <state-file>
  local state_file="$1" dir staging
  dir=$(run_archive_dir "$state_file")
  if [[ -d "$dir" ]]; then
    echo "archive: already written, keeping the first one: $dir"
    return 0
  fi
  staging="$dir.partial.$$"
  rm -rf "$staging"
  mkdir -p "$staging" || { echo "WARN: could not create $staging; this run leaves no record." >&2; return 1; }
  _archive_collect "$staging" "$state_file"
  if ! mv "$staging" "$dir" 2>/dev/null; then
    # Another cleanup won the race and wrote the same directory first. Its copy
    # is the earlier one, so it is the one with the worktrees still in place.
    rm -rf "$staging"
    echo "archive: already written, keeping the first one: $dir"
    return 0
  fi
  echo "archive: $dir"
  trace "-" "archive.write" "$dir"
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
