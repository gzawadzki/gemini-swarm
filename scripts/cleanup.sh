#!/usr/bin/env bash
# Close the agents a swarm left behind, and optionally remove their worktrees.
# Usage: cleanup.sh [state.json] [--all] [--worktrees] [--force] [--dry-run]
#
# A finished agy agent does not exit. It sits in its pane as an idle process
# still holding the shared OAuth credential, so the next launch that needs the
# other account is refused with "accounts cannot be mixed" - true, but hard to
# read as "your last swarm is still open". Closing agents is therefore part of
# the run, not tidying up afterwards.
#
#   (default)     close agents that reported a result, or that herdr calls done
#   --all         close working and blocked agents too (interrupts their work)
#   --worktrees   also remove the herdr workspace of every agent closed here
#   --force       remove worktrees that are dirty or whose branch is unmerged
#   --dry-run     print what would happen, touch nothing
set -euo pipefail

STATE_DIR="${HERDR_SWARM_STATE_DIR:-.herdr-swarm}"
STATE_FILE=""
all=0; worktrees=0; force=0; dry=0

for arg in "$@"; do
  case "$arg" in
    --all)       all=1 ;;
    --worktrees) worktrees=1 ;;
    --force)     force=1 ;;
    --dry-run)   dry=1 ;;
    -h|--help)   sed -n '2,15p' "${BASH_SOURCE[0]}"; exit 0 ;;
    -*)          echo "ERROR: unknown option '$arg'." >&2; exit 1 ;;
    *)           STATE_FILE="$arg" ;;
  esac
done
STATE_FILE="${STATE_FILE:-$STATE_DIR/state.json}"

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required." >&2; exit 1; }
command -v herdr >/dev/null 2>&1 || { echo "ERROR: herdr not found on PATH." >&2; exit 1; }
[[ -f "$STATE_FILE" ]] || { echo "ERROR: $STATE_FILE not found. Run launch.sh first." >&2; exit 1; }

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# The record comes first, before a single pane is closed or a worktree removed.
# Everything worth keeping about a run - the config, the diffs, the two gate
# verdicts - lives in the worktrees and the state dir that the rest of this
# script is about to take apart, and an agent that will not close must not cost
# the evidence. A failure to archive is reported and then ignored: leaving panes
# open because the record could not be written helps nobody.
if [[ "$dry" == "1" ]]; then
  echo "would archive this run to $(run_archive_dir "$STATE_FILE")"
else
  archive_run "$STATE_FILE" \
    || echo "WARN: could not archive this run; once the worktrees are gone there is no record of it." >&2
fi
echo

# The repo a worktree was cut from. State written before this field existed has
# no 'repo', so ask git: a worktree's common git dir is the origin repo's .git.
repo_of() {
  local from_state="$1" worktree="$2" common
  if [[ -n "$from_state" && "$from_state" != "null" ]]; then printf '%s' "$from_state"; return; fi
  [[ -n "$worktree" && -d "$worktree" ]] || return 0
  common=$(git -C "$worktree" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 0
  printf '%s' "$(dirname "$(printf '%s' "$common" | tr '\\' '/')")"
}

closed=0; kept=0; removed=0; failed=0

n=$(jq 'length' "$STATE_FILE")
for i in $(seq 0 $((n - 1))); do
  entry=$(jq -c ".[$i]" "$STATE_FILE")
  name=$(jq -r '.name' <<<"$entry")
  branch=$(jq -r '.branch // empty' <<<"$entry")
  base=$(jq -r '.base // "HEAD"' <<<"$entry")
  status_file=$(jq -r '.status_file // empty' <<<"$entry")
  workspace_id=$(jq -r '.workspace_id // empty' <<<"$entry")
  worktree=$(resolve_worktree "$(jq -r '.worktree_path // empty' <<<"$entry")" "$workspace_id")
  repo=$(repo_of "$(jq -r '.repo // empty' <<<"$entry")" "$worktree")

  state=$(task_state "$name")
  has_result=0
  [[ -n "$status_file" && -f "$status_file" ]] && has_result=1

  # "Finished" means the agent said so, or herdr saw it finish. An idle agent
  # with no result file is not finished: that is what a dropped prompt looks
  # like, and closing it would throw away a task nobody has looked at.
  finished=0
  [[ "$has_result" == "1" || "$state" == "done" || "$state" == "unreachable" ]] && finished=1

  if [[ "$finished" != "1" && "$all" != "1" ]]; then
    echo "keep   $name  (herdr: $state, no result file yet; --all closes it anyway)"
    kept=$((kept + 1))
    continue
  fi

  if [[ "$state" == "unreachable" ]]; then
    echo "gone   $name  (herdr no longer knows this agent)"
  elif [[ "$dry" == "1" ]]; then
    echo "would close $name  (herdr: $state)"
  elif agent_close "$name"; then
    echo "closed $name  (was: $state)"
    closed=$((closed + 1))
  else
    echo "FAILED $name  did not exit; close its pane by hand" >&2
    failed=$((failed + 1))
    continue
  fi

  [[ "$worktrees" == "1" ]] || continue
  if [[ -z "$workspace_id" || "$workspace_id" == "null" ]]; then
    echo "       no workspace id recorded, leaving the worktree alone" >&2
    continue
  fi

  # Removing a worktree throws away anything not already in the origin repo, so
  # both checks are about not losing work: uncommitted files, and commits on a
  # branch nobody has merged yet.
  if [[ "$force" != "1" && -n "$worktree" && -d "$worktree" ]]; then
    if [[ -n "$(git -C "$worktree" status --porcelain 2>/dev/null)" ]]; then
      echo "       worktree is dirty, keeping it: $worktree"
      continue
    fi
  fi
  if [[ "$force" != "1" && -n "$repo" && -n "$branch" ]]; then
    if ! git -C "$repo" merge-base --is-ancestor "$branch" "$base" 2>/dev/null; then
      echo "       branch '$branch' is not merged into '$base', keeping the worktree. Review it with: scripts/review.sh $name"
      continue
    fi
  fi

  if [[ "$dry" == "1" ]]; then
    echo "       would remove workspace $workspace_id"
  elif herdr worktree remove --workspace "$workspace_id" --force >/dev/null 2>&1; then
    echo "       removed workspace $workspace_id"
    removed=$((removed + 1))
  else
    echo "       could not remove workspace $workspace_id; remove it by hand" >&2
    failed=$((failed + 1))
  fi
done

echo
echo "$closed closed, $kept left running, $removed worktree(s) removed, $failed problem(s)."
[[ "$closed" -gt 0 || "$removed" -gt 0 ]] && \
  echo "Account switching needs every agy process gone. Check with: scripts/agy-account.ps1 -Mode list"
[[ "$failed" -eq 0 ]]
