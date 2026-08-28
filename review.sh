#!/usr/bin/env bash
# Show the commit log and diffstat for one task's branch, for review before merge.
# Usage: review.sh <task-name> [state.json]
set -euo pipefail

NAME="${1:?Usage: review.sh <task-name> [state.json]}"
STATE_DIR="${HERDR_SWARM_STATE_DIR:-.herdr-swarm}"
STATE_FILE="${2:-$STATE_DIR/state.json}"

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required." >&2; exit 1; }
[[ -f "$STATE_FILE" ]] || { echo "ERROR: $STATE_FILE not found — run launch.sh first." >&2; exit 1; }

entry=$(jq -c --arg name "$NAME" '.[] | select(.name == $name)' "$STATE_FILE")
[[ -n "$entry" ]] || { echo "ERROR: no task named '$NAME' in $STATE_FILE." >&2; exit 1; }

branch=$(jq -r '.branch' <<<"$entry")
base=$(jq -r '.base' <<<"$entry")
worktree_path=$(jq -r '.worktree_path' <<<"$entry")

[[ -n "$worktree_path" && -d "$worktree_path" ]] || {
  echo "ERROR: worktree path unknown or missing for '$NAME' (got: '$worktree_path')." >&2
  echo "Check .herdr-swarm/state.json and herdr's worktree create output manually." >&2
  exit 1
}

base_ref="$base"
if [[ "$base" == "HEAD" ]]; then
  # HEAD at launch time may have moved on; fall back to merge-base with the branch.
  base_ref=$(git -C "$worktree_path" merge-base HEAD "$branch" 2>/dev/null || echo "HEAD")
fi

echo "=== $NAME ==="
echo "branch:    $branch"
echo "base:      $base (resolved: $base_ref)"
echo "worktree:  $worktree_path"
echo
echo "--- commits ---"
git -C "$worktree_path" log "${base_ref}.." --oneline || echo "(no commits found ahead of base)"
echo
echo "--- diffstat ---"
git -C "$worktree_path" diff "${base_ref}..." --stat || echo "(diff failed — check base ref)"
echo
echo "Read the full diff yourself before deciding:"
echo "  git -C \"$worktree_path\" diff ${base_ref}..."
