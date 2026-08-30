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

printf '%-20s %-8s %-10s %-10s %-8s %-6s %s\n' "TASK" "AGENT" "HERDR" "RESULT" "TESTS" "CLEAN" "SUMMARY"

n=$(jq 'length' "$STATE_FILE")
for i in $(seq 0 $((n - 1))); do
  entry=$(jq -c ".[$i]" "$STATE_FILE")
  name=$(jq -r '.name' <<<"$entry")
  kind=$(jq -r '.kind // "?"' <<<"$entry")
  account=$(jq -r '.account // "a"' <<<"$entry")
  status_file=$(jq -r '.status_file' <<<"$entry")
  workspace_id=$(jq -r '.workspace_id // empty' <<<"$entry")
  worktree_path=$(resolve_worktree "$(jq -r '.worktree_path // empty' <<<"$entry")" "$workspace_id")

  # Which Antigravity subscription did the work, since both look identical in
  # the pane and only the credential in use told them apart.
  [[ "$account" != "a" ]] && kind="${kind}@${account^^}"

  herdr_state=$(task_state "$name")

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

  printf '%-20s %-8s %-10s %-10s %-8s %-6s %s\n' "$name" "$kind" "$herdr_state" "$result" "$tests" "$clean" "$summary"
done

echo
echo "Review-ready = HERDR idle/done + RESULT success + CLEAN yes. Run scripts/review.sh <task> for those."
echo "AGENT ending in @B ran on the second Antigravity account, because account A was at 0% when it was launched."
