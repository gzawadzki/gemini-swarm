#!/usr/bin/env bash
# Run a deterministic check inside one task's worktree before Claude reviews it.
# This is the egress gate: it catches broken builds and failing tests with zero
# Claude tokens, so the human-in-the-loop read only ever sees diffs that pass.
# Usage: verify.sh [--trace] <task-name> [state.json]
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TRACE_SRC="verify"
strip_trace_flag "$@"; set -- ${ARGV[@]+"${ARGV[@]}"}
trace_banner

NAME="${1:?Usage: verify.sh [--trace] <task-name> [state.json]}"
STATE_DIR="${HERDR_SWARM_STATE_DIR:-.herdr-swarm}"
STATE_FILE="${2:-$STATE_DIR/state.json}"

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required." >&2; exit 1; }
[[ -f "$STATE_FILE" ]] || { echo "ERROR: $STATE_FILE not found. Run launch.sh first." >&2; exit 1; }

entry=$(jq -c --arg name "$NAME" '.[] | select(.name == $name)' "$STATE_FILE")
[[ -n "$entry" ]] || { echo "ERROR: no task named '$NAME' in $STATE_FILE." >&2; exit 1; }

workspace_id=$(jq -r '.workspace_id // empty' <<<"$entry")
worktree_path=$(resolve_worktree "$(jq -r '.worktree_path // empty' <<<"$entry")" "$workspace_id")
verify_from_task=$(jq -r '.verify // empty' <<<"$entry")

[[ -n "$worktree_path" && -d "$worktree_path" ]] || {
  echo "ERROR: worktree path unknown or missing for '$NAME' (got: '$worktree_path')." >&2
  exit 1
}

cmd=$(resolve_verify_cmd "$verify_from_task" "$worktree_path")
verify_file=$(verify_file_for "$NAME")
log_file="${verify_file%.json}.log"

trace "$NAME" "cmd.resolve" \
  "${cmd:-<none>} (source: $([[ -n "$verify_from_task" ]] && echo "tasks.json" || echo "detected from $worktree_path"))"

write_result() {  # status  cmd
  jq -n --arg status "$1" --arg cmd "$2" --arg ts "$(date -u +%FT%TZ)" \
    '{status: $status, cmd: $cmd, ran_at: $ts}' > "$verify_file"
}

if [[ -z "$cmd" ]]; then
  echo "=== $NAME: verify SKIPPED ==="
  echo "No 'verify' field on the task and no known test command in $worktree_path."
  echo "Set a \"verify\" command in tasks.json, or review the diff by hand."
  write_result "skipped" ""
  trace "$NAME" "cmd.exec" "skipped, no verify command"
  echo "Nothing was proven here, so the critique is the only gate left:"
  echo "Next: scripts/critique.sh $NAME"
  exit 0
fi

echo "=== $NAME: verify ==="
echo "worktree: $worktree_path"
echo "command:  $cmd"
echo "--- output (tail) ---"

# eval so a task-supplied command may contain flags, pipes or &&. Runs with the
# worktree as cwd, output tee'd to a log the agent can be pointed back at.
rc=0
trace "$NAME" "cmd.exec" "in $worktree_path: $cmd"
( cd "$worktree_path" && eval "$cmd" ) >"$log_file" 2>&1 || rc=$?
tail -n 30 "$log_file"
echo "---------------------"
trace "$NAME" "cmd.exec" "rc=$rc ($([[ "$rc" -eq 0 ]] && echo pass || echo fail)), output in $log_file"

if [[ "$rc" -eq 0 ]]; then
  echo "VERIFY PASS ($cmd)"
  write_result "pass" "$cmd"
  echo "Next: scripts/critique.sh $NAME"
else
  echo "VERIFY FAIL (exit $rc): $cmd"
  write_result "fail" "$cmd"
  echo "Full output: $log_file"
  echo "Next: send the failure back to the agent, e.g."
  echo "  herdr agent prompt $NAME \"verify failed: $cmd. Fix it and rerun.\" --wait"
fi
exit "$rc"
