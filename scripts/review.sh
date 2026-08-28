#!/usr/bin/env bash
# Show the commit log and diffstat for one task's branch, for review before merge.
# Usage: review.sh <task-name> [state.json]
set -euo pipefail

NAME="${1:?Usage: review.sh <task-name> [state.json]}"
STATE_DIR="${HERDR_SWARM_STATE_DIR:-.herdr-swarm}"
STATE_FILE="${2:-$STATE_DIR/state.json}"

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required." >&2; exit 1; }
[[ -f "$STATE_FILE" ]] || { echo "ERROR: $STATE_FILE not found. Run launch.sh first." >&2; exit 1; }

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

entry=$(jq -c --arg name "$NAME" '.[] | select(.name == $name)' "$STATE_FILE")
[[ -n "$entry" ]] || { echo "ERROR: no task named '$NAME' in $STATE_FILE." >&2; exit 1; }

branch=$(jq -r '.branch' <<<"$entry")
base=$(jq -r '.base' <<<"$entry")
kind=$(jq -r '.kind // "?"' <<<"$entry")
model=$(jq -r '.model // ""' <<<"$entry")
effort=$(jq -r '.effort // ""' <<<"$entry")
fallback_from=$(jq -r '.fallback_from // ""' <<<"$entry")
workspace_id=$(jq -r '.workspace_id // empty' <<<"$entry")
worktree_path=$(resolve_worktree "$(jq -r '.worktree_path // empty' <<<"$entry")" "$workspace_id")

[[ -n "$worktree_path" && -d "$worktree_path" ]] || {
  echo "ERROR: worktree path unknown or missing for '$NAME' (got: '$worktree_path')." >&2
  echo "Ask herdr directly: herdr workspace get $workspace_id | jq .result.workspace.worktree" >&2
  exit 1
}

# launch.sh pins the base commit at worktree-creation time, which is the only
# reliable answer: inside this worktree HEAD is the task branch itself, so
# resolving the base from here would just give back the branch tip.
base_sha=$(jq -r '.base_sha // ""' <<<"$entry")
base_ref="$base_sha"
if [[ -z "$base_ref" ]]; then
  # State file from before base_sha existed, or an unresolvable base ref.
  base_ref="$base"
  [[ -z "$base_ref" || "$base_ref" == "HEAD" ]] && base_ref=$(git -C "$worktree_path" rev-list --max-parents=0 HEAD 2>/dev/null | tail -1)
  [[ -n "$base_ref" ]] || { echo "ERROR: cannot work out the base commit for '$NAME'." >&2; exit 1; }
fi
git -C "$worktree_path" rev-parse --verify --quiet "${base_ref}^{commit}" >/dev/null \
  || { echo "ERROR: base '$base_ref' is not a commit in $worktree_path." >&2; exit 1; }

echo "=== $NAME ==="
echo "agent:     $kind${model:+ / $model}${effort:+ / $effort}"
if [[ -n "$fallback_from" ]]; then
  echo "fallback:  ran on codex instead of $fallback_from, because the agy quota pool read 0% at launch"
fi
echo "branch:    $branch"
echo "base:      $base (resolved: ${base_ref:0:12})"
echo "worktree:  $worktree_path"
echo
echo "--- commits ---"
git -C "$worktree_path" log --oneline "${base_ref}..HEAD" || echo "(no commits found ahead of base)"
echo
echo "--- diffstat ---"
git -C "$worktree_path" diff --stat "${base_ref}...HEAD" || echo "(diff failed, check base ref)"
echo
echo "Read the full diff yourself before deciding:"
echo "  git -C \"$worktree_path\" diff ${base_ref}...HEAD"
