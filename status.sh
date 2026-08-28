#!/usr/bin/env bash
# Report status for every task launched via launch.sh.
# Usage: status.sh [state.json]
set -euo pipefail

STATE_DIR="${HERDR_SWARM_STATE_DIR:-.herdr-swarm}"
STATE_FILE="${1:-$STATE_DIR/state.json}"

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required." >&2; exit 1; }
[[ -f "$STATE_FILE" ]] || { echo "ERROR: $STATE_FILE not found — run launch.sh first." >&2; exit 1; }

printf '%-20s %-10s %-10s %-8s %-6s %s\n' "TASK" "HERDR" "RESULT" "TESTS" "CLEAN" "SUMMARY"

n=$(jq 'length' "$STATE_FILE")
for i in $(seq 0 $((n - 1))); do
  entry=$(jq -c ".[$i]" "$STATE_FILE")
  name=$(jq -r '.name' <<<"$entry")
  status_file=$(jq -r '.status_file' <<<"$entry")
  worktree_path=$(jq -r '.worktree_path // empty' <<<"$entry")

  herdr_state=$(herdr agent get "$name" 2>/dev/null | jq -r '.result.agent.status // "unreachable"' || echo "unreachable")

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

  printf '%-20s %-10s %-10s %-8s %-6s %s\n' "$name" "$herdr_state" "$result" "$tests" "$clean" "$summary"
done

echo
echo "Review-ready = HERDR idle/done + RESULT success + CLEAN yes. Run scripts/review.sh <task> for those."
