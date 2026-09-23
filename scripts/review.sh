#!/usr/bin/env bash
# Show the commit log and diffstat for one task's branch, for review before merge.
# Usage: review.sh [--trace] <task-name> [state.json]
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TRACE_SRC="review"
strip_trace_flag "$@"; set -- ${ARGV[@]+"${ARGV[@]}"}
trace_banner

NAME="${1:?Usage: review.sh [--trace] <task-name> [state.json]}"
STATE_DIR="${HERDR_SWARM_STATE_DIR:-.herdr-swarm}"
STATE_FILE="${2:-$STATE_DIR/state.json}"

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required." >&2; exit 1; }
[[ -f "$STATE_FILE" ]] || { echo "ERROR: $STATE_FILE not found. Run launch.sh first." >&2; exit 1; }

entry=$(jq -c --arg name "$NAME" '.[] | select(.name == $name)' "$STATE_FILE")
[[ -n "$entry" ]] || { echo "ERROR: no task named '$NAME' in $STATE_FILE." >&2; exit 1; }

branch=$(jq -r '.branch' <<<"$entry")
base=$(jq -r '.base' <<<"$entry")
kind=$(jq -r '.kind // "?"' <<<"$entry")
model=$(jq -r '.model // ""' <<<"$entry")
effort=$(jq -r '.effort // ""' <<<"$entry")
account=$(jq -r '.account // "a"' <<<"$entry")
fallback_from=$(jq -r '.fallback_from // ""' <<<"$entry")
workspace_id=$(jq -r '.workspace_id // empty' <<<"$entry")
worktree_path=$(resolve_worktree "$(jq -r '.worktree_path // empty' <<<"$entry")" "$workspace_id")

[[ -n "$worktree_path" && -d "$worktree_path" ]] || {
  echo "ERROR: worktree path unknown or missing for '$NAME' (got: '$worktree_path')." >&2
  echo "Ask herdr directly: herdr workspace get $workspace_id | jq .result.workspace.worktree" >&2
  exit 1
}

base_ref=$(resolve_base_ref "$entry" "$worktree_path") || {
  echo "ERROR: cannot work out a usable base commit for '$NAME'." >&2
  echo "State says base='$base', base_sha='$(jq -r '.base_sha // ""' <<<"$entry")'." >&2
  exit 1
}

verify_file=$(verify_file_for "$NAME")
verify_status="not run"
verify_cmd=""
verify_soundness=""
verify_soundness_detail=""
if [[ -f "$verify_file" ]]; then
  verify_status=$(jq -r '.status // "?"' "$verify_file" 2>/dev/null || echo "?")
  verify_cmd=$(jq -r '.cmd // ""' "$verify_file" 2>/dev/null || echo "")
  verify_soundness=$(jq -r '.soundness // ""' "$verify_file" 2>/dev/null || echo "")
  verify_soundness_detail=$(jq -r '.soundness_detail // ""' "$verify_file" 2>/dev/null || echo "")
fi

critique_file=$(critique_file_for "$NAME")
critique_verdict="not run"
critique_summary=""
critique_issues="[]"
critique_model=""
critique_confidence=""
critique_checked="[]"
critique_declared=0
critique_reviewer_verdict=""
critique_auto=false
critique_jev_risk=""
if [[ -f "$critique_file" ]]; then
  critique_verdict=$(jq -r '.verdict // "?"' "$critique_file" 2>/dev/null || echo "?")
  critique_summary=$(jq -r '.summary // ""' "$critique_file" 2>/dev/null || echo "")
  critique_issues=$(jq -c '.issues // []' "$critique_file" 2>/dev/null || echo "[]")
  critique_model=$(jq -r '.model // ""' "$critique_file" 2>/dev/null || echo "")
  critique_confidence=$(jq -r '.confidence // ""' "$critique_file" 2>/dev/null || echo "")
  critique_checked=$(jq -c '.pitfalls_checked // []' "$critique_file" 2>/dev/null || echo "[]")
  critique_declared=$(jq -r '.pitfalls_declared // 0' "$critique_file" 2>/dev/null || echo 0)
  critique_reviewer_verdict=$(jq -r '.reviewer_verdict // ""' "$critique_file" 2>/dev/null || echo "")
  critique_auto=$(jq -r '.auto_accepted // false' "$critique_file" 2>/dev/null || echo false)
  critique_jev_risk=$(jq -r '.jev.risk_max // empty' "$critique_file" 2>/dev/null || echo "")
fi

scope_report "$entry" "$worktree_path"
trace "$NAME" "review.read" "verify=$verify_status critique=$critique_verdict base=${base_ref:0:12} strays=$SCOPE_STRAY_COUNT lines=$SCOPE_LINES"

echo "=== $NAME ==="
echo "agent:     $kind${model:+ / $model}${effort:+ / $effort}"
if [[ -n "$fallback_from" ]]; then
  echo "fallback:  legacy run on codex instead of $fallback_from"
elif [[ -n "$account" && "$account" != "a" ]]; then
  echo "account:   ${account^^} (the other Antigravity subscription; account A was at 0% at launch)"
fi
echo "verify:    $verify_status${verify_cmd:+ ($verify_cmd)}"
if [[ "$verify_status" == "not run" ]]; then
  echo "           run scripts/verify.sh $NAME first; do not merge on an unverified diff you have not read"
elif [[ "$verify_status" == "fail" && "$verify_soundness" == "unsound" ]]; then
  # Sending this back would spend a bounce on an agent that cannot fix it: the
  # tests passed, and the environment is what lied about which tree they ran on.
  echo "           verify FAILED on resolution, not on the tests:"
  echo "           $verify_soundness_detail"
  echo "           fix the environment (install or path inside the worktree), then rerun verify"
elif [[ "$verify_status" == "fail" ]]; then
  echo "           verify FAILED; re-prompt the agent before reviewing further"
elif [[ "$verify_status" == "skipped" && "$verify_soundness" == "unknown" ]]; then
  echo "           the command passed but nothing is proven about which tree ran it:"
  echo "           $verify_soundness_detail"
elif [[ "$verify_soundness" == "disabled" ]]; then
  echo "           resolution was not checked (HERDR_SWARM_NO_SOUNDNESS=1)"
fi
echo "critique:  $critique_verdict${critique_model:+ (${critique_model}${critique_confidence:+, confidence: $critique_confidence})}"
if [[ "$critique_auto" == "true" ]]; then
  echo "approval:  automatic (Jev max risk $critique_jev_risk)"
fi
case "$critique_verdict" in
  "not run") echo "           run scripts/critique.sh $NAME first; it is cheaper than your attention" ;;
  revise|reject) echo "           the reviewer wants changes; the issues below are what to send back" ;;
esac
if [[ -n "$critique_summary" ]]; then echo "           $critique_summary"; fi
if [[ "$(jq 'length' <<<"$critique_issues")" -gt 0 ]]; then
  jq -r '.[] | "           [\(.severity // "?")] \(.file // "?"): \(.note // "")"' <<<"$critique_issues"
fi
if (( critique_declared > 0 )); then
  echo "           pitfalls:  $(jq 'length' <<<"$critique_checked") of $critique_declared declared examined"
  jq -r '.[] | "           [\(.status // "?")] \(.pitfall)\(if (.note // "") == "" then "" else " - " + .note end)"' \
    <<<"$critique_checked"
fi
if [[ -n "$critique_reviewer_verdict" && "$critique_reviewer_verdict" != "$critique_verdict" ]]; then
  echo "           the reviewer said $critique_reviewer_verdict; downgraded to $critique_verdict above"
fi
trim_file=$(trim_file_for "$NAME")
if [[ -f "$trim_file" ]]; then
  echo "trim:      $(jq -r '"\(.status // "?") (\(.cuts // [] | length) suggested cuts, advisory)"' "$trim_file" 2>/dev/null || echo "?")"
  jq -r '.cuts // [] | .[] | "           - \(.file // "?"): \(.what // "")"' "$trim_file" 2>/dev/null || true
fi
scope_out=$(scope_lines "           ")
if [[ -n "$scope_out" ]]; then
  echo "scope:     what this task touched beyond what it declared (advisory, nothing here blocks)"
  echo "$scope_out"
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
if [[ "$critique_auto" == "true" ]]; then
  echo "Jev approved this verified, clean, complete and in-scope diff automatically."
  echo "The branch is ready for the merge handoff; inspect the diff only if you want to:"
else
  echo "Read the full diff yourself before deciding. A verify pass means the tests ran"
  echo "and an ordinary critique pass means one cheap model found nothing; neither is approval:"
fi
echo "  git -C \"$worktree_path\" diff ${base_ref}...HEAD"
