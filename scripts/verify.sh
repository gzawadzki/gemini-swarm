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

# Every result says what was established about resolution. The paths that never
# ask - no command to run, or a command that failed - say exactly that, because
# an empty field reads like an answer.
SOUNDNESS="not checked"
SOUNDNESS_DETAIL="resolution was not established"

trace "$NAME" "cmd.resolve" \
  "${cmd:-<none>} (source: $([[ -n "$verify_from_task" ]] && echo "tasks.json" || echo "detected from $worktree_path"))"

write_result() {  # status  cmd
  jq -n --arg status "$1" --arg cmd "$2" --arg ts "$(date -u +%FT%TZ)" \
        --arg soundness "${SOUNDNESS:-}" --arg soundness_detail "${SOUNDNESS_DETAIL:-}" \
    '{status: $status, cmd: $cmd, soundness: $soundness,
      soundness_detail: $soundness_detail, ran_at: $ts}' > "$verify_file"
}

if [[ -z "$cmd" ]]; then
  echo "=== $NAME: verify SKIPPED ==="
  echo "No 'verify' field on the task and no known test command in $worktree_path."
  echo "Set a \"verify\" command in tasks.json, or review the diff by hand."
  SOUNDNESS_DETAIL="there was no verify command to run, so nothing was established about which tree would have run it"
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
  # The command passed. Whether it passed on this worktree's code is a separate
  # question, and the one an editable install gets wrong.
  if [[ "${HERDR_SWARM_NO_SOUNDNESS:-0}" == "1" ]]; then
    SOUNDNESS="disabled"
    SOUNDNESS_DETAIL="HERDR_SWARM_NO_SOUNDNESS=1"
    echo "VERIFY PASS ($cmd)"
    echo "Where the code under test resolved from was NOT checked: HERDR_SWARM_NO_SOUNDNESS=1."
    write_result "pass" "$cmd"
    trace "$NAME" "soundness" "disabled by HERDR_SWARM_NO_SOUNDNESS"
    echo "Next: scripts/critique.sh $NAME"
  else
    check_verify_soundness "$worktree_path"
    trace "$NAME" "soundness" "$SOUNDNESS: $SOUNDNESS_DETAIL"
    case "$SOUNDNESS" in
      sound)
        echo "VERIFY PASS ($cmd)"
        echo "Resolution: $SOUNDNESS_DETAIL"
        write_result "pass" "$cmd"
        echo "Next: scripts/critique.sh $NAME"
        ;;
      unsound)
        # The suite was green on code from somewhere else. Reported as a failure
        # rather than a warning: a gate that silently tested the wrong tree is
        # worse than no gate, because it is counted as evidence.
        echo "VERIFY FAIL (resolved outside the worktree): $cmd"
        echo "The verify command itself passed. The code it exercised did not come"
        echo "from this task's worktree:"
        echo "  $SOUNDNESS_DETAIL"
        echo "That is an editable install pinning imports to another checkout, not a"
        echo "broken test suite. Fix the environment, not the diff: reinstall inside"
        echo "the worktree, or set a pythonpath for it, then rerun."
        write_result "fail" "$cmd"
        echo "Full output: $log_file"
        rc=1
        ;;
      *)
        # "I could not tell" must never render as a pass.
        echo "VERIFY SKIPPED (soundness unknown): $cmd"
        echo "The verify command itself passed, but where the code under test resolved"
        echo "from could not be established:"
        echo "  $SOUNDNESS_DETAIL"
        echo "Nothing is proven about which tree was exercised, so this is not a pass."
        echo "Set HERDR_SWARM_NO_SOUNDNESS=1 if the check makes no sense for this project."
        write_result "skipped" "$cmd"
        echo "Next: scripts/critique.sh $NAME"
        ;;
    esac
  fi
else
  echo "VERIFY FAIL (exit $rc): $cmd"
  # Ask where the code resolved from here too. An install pinned to another
  # checkout makes new tests in the worktree fail against old code, and a bare
  # failure sends the agent to fix a diff that was never the problem.
  if [[ "${HERDR_SWARM_NO_SOUNDNESS:-0}" == "1" ]]; then
    SOUNDNESS="disabled"
    SOUNDNESS_DETAIL="HERDR_SWARM_NO_SOUNDNESS=1"
  else
    check_verify_soundness "$worktree_path"
    trace "$NAME" "soundness" "$SOUNDNESS: $SOUNDNESS_DETAIL"
  fi
  write_result "fail" "$cmd"
  echo "Full output: $log_file"
  if [[ "$SOUNDNESS" == "unsound" ]]; then
    echo "Before you bounce this: the code under test did not come from this worktree."
    echo "  $SOUNDNESS_DETAIL"
    echo "Tests failing against another checkout's code is an environment problem, not"
    echo "the agent's diff. Fix the install or the path, then rerun."
  else
    echo "Next: send the failure back to the agent, e.g."
    echo "  herdr agent prompt $NAME \"verify failed: $cmd. Fix it and rerun.\" --wait"
  fi
fi
exit "$rc"
