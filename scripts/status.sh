#!/usr/bin/env bash
# Report status for every task launched via launch.sh.
# Usage: status.sh [state.json]
set -euo pipefail

STATE_DIR="${HERDR_SWARM_STATE_DIR:-.herdr-swarm}"
STATE_FILE="${1:-$STATE_DIR/state.json}"

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required." >&2; exit 1; }
[[ -f "$STATE_FILE" ]] || { echo "ERROR: $STATE_FILE not found. Run launch.sh first." >&2; exit 1; }

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

printf '%-20s %-8s %-10s %-10s %-8s %-6s %-8s %s\n' \
  "TASK" "AGENT" "HERDR" "RESULT" "TESTS" "CLEAN" "VERIFY" "SUMMARY"

# NEXT block: one prescriptive command per task, so a status read collapses into
# the next action instead of another round of Claude figuring out what to do.
next_lines=()

n=$(jq 'length' "$STATE_FILE")
for i in $(seq 0 $((n - 1))); do
  entry=$(jq -c ".[$i]" "$STATE_FILE")
  name=$(jq -r '.name' <<<"$entry")
  kind=$(jq -r '.kind // "?"' <<<"$entry")
  fallback_from=$(jq -r '.fallback_from // ""' <<<"$entry")
  status_file=$(jq -r '.status_file' <<<"$entry")
  workspace_id=$(jq -r '.workspace_id // empty' <<<"$entry")
  worktree_path=$(resolve_worktree "$(jq -r '.worktree_path // empty' <<<"$entry")" "$workspace_id")

  # A trailing * marks a task that ran on codex because its agy quota pool read
  # 0%, so the model that did the work is not the one tasks.json asked for.
  [[ -n "$fallback_from" ]] && kind="${kind}*"

  herdr_state=$(agent_state "$name")

  if [[ -f "$status_file" ]]; then
    result=$(jq -r '.status // "unknown"' "$status_file" 2>/dev/null || echo "unparseable")
    tests=$(jq -r '.tests_passed // "n/a"' "$status_file" 2>/dev/null || echo "n/a")
    summary=$(jq -r '.summary // ""' "$status_file" 2>/dev/null || echo "")
  else
    result="pending"
    tests="n/a"
    summary="(no result file yet)"
  fi

  if [[ -n "$worktree_path" && -d "$worktree_path" ]]; then
    if [[ -z "$(git -C "$worktree_path" status --porcelain 2>/dev/null)" ]]; then
      clean="yes"
    else
      clean="DIRTY"
    fi
  else
    clean="n/a"
  fi

  # VERIFY is whatever verify.sh last cached; "-" means it has not run yet. This
  # stays a zero-cost read: status.sh never runs the check itself.
  verify_file=$(verify_file_for "$name")
  if [[ -f "$verify_file" ]]; then
    verify=$(jq -r '.status // "?"' "$verify_file" 2>/dev/null || echo "?")
  else
    verify="-"
  fi

  printf '%-20s %-8s %-10s %-10s %-8s %-6s %-8s %s\n' \
    "$name" "$kind" "$herdr_state" "$result" "$tests" "$clean" "$verify" "$summary"

  # Decide the single next command for this task.
  if [[ "$herdr_state" == "blocked" ]]; then
    next_lines+=("$name: blocked, needs a human -> scripts/logs.sh $name")
  elif [[ "$herdr_state" == "unreachable" ]]; then
    next_lines+=("$name: herdr can't see this agent -> herdr agent list (do not relaunch blindly)")
  elif [[ "$result" == "failure" ]]; then
    next_lines+=("$name: agent reported failure -> scripts/logs.sh $name")
  elif [[ "$herdr_state" != "idle" && "$herdr_state" != "done" ]]; then
    next_lines+=("$name: still running -> scripts/logs.sh $name")
  elif [[ "$result" != "success" || "$clean" != "yes" ]]; then
    next_lines+=("$name: not review-ready (result=$result clean=$clean) -> scripts/logs.sh $name")
  elif [[ "$verify" == "-" ]]; then
    next_lines+=("$name: ready to verify -> scripts/verify.sh $name")
  elif [[ "$verify" == "fail" ]]; then
    next_lines+=("$name: verify failed -> scripts/logs.sh $name, then re-prompt the agent")
  else
    # pass or skipped: as ready for review as it gets.
    next_lines+=("$name: verify $verify -> scripts/review.sh $name")
  fi
done

echo
echo "NEXT:"
for line in "${next_lines[@]}"; do echo "  $line"; done
echo
echo "Review-ready = HERDR idle/done + RESULT success + CLEAN yes + VERIFY pass/skipped."
echo "AGENT ending in * ran on codex because the agy quota pool was empty at launch."
