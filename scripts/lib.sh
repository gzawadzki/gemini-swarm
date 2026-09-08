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
  command -v agy >/dev/null 2>&1 || return 1
  MSYS_NO_PATHCONV=1 timeout 120 agy -p "/usage" 2>/dev/null > "$AGY_USAGE_CACHE" || return 1
  grep -qE '[0-9]+%' "$AGY_USAGE_CACHE" || return 1
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
