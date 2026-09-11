#!/usr/bin/env bash
# Ask a cheap model where one task's diff is overbuilt, and what could be cut.
#
# On demand, after review.sh, never as part of the gate. The critique already
# asked whether the change is correct and in scope; this asks only whether it is
# bigger than the task needed. The answer is a list of suggested cuts for the
# orchestrator to accept or ignore. It never blocks, never judges correctness or
# safety, and never touches the worktree: acting on a cut means prompting the
# agent, and that stays a deliberate decision.
#
# Usage: trim.sh [--trace] <task-name> [state.json]
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TRACE_SRC="trim"
strip_trace_flag "$@"; set -- ${ARGV[@]+"${ARGV[@]}"}
trace_banner

NAME="${1:?Usage: trim.sh [--trace] <task-name> [state.json]}"
STATE_DIR="${HERDR_SWARM_STATE_DIR:-.herdr-swarm}"
STATE_FILE="${2:-$STATE_DIR/state.json}"

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required." >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "ERROR: git is required." >&2; exit 1; }
[[ -f "$STATE_FILE" ]] || { echo "ERROR: $STATE_FILE not found. Run launch.sh first." >&2; exit 1; }

entry=$(jq -c --arg name "$NAME" '.[] | select(.name == $name)' "$STATE_FILE")
[[ -n "$entry" ]] || { echo "ERROR: no task named '$NAME' in $STATE_FILE." >&2; exit 1; }

workspace_id=$(jq -r '.workspace_id // empty' <<<"$entry")
worktree_path=$(resolve_worktree "$(jq -r '.worktree_path // empty' <<<"$entry")" "$workspace_id")
task_prompt=$(jq -r '.prompt // empty' <<<"$entry")
[[ -n "$task_prompt" ]] || task_prompt="(not recorded; this task predates prompts being stored in state.json)"

[[ -n "$worktree_path" && -d "$worktree_path" ]] || {
  echo "ERROR: worktree path unknown or missing for '$NAME' (got: '$worktree_path')." >&2
  exit 1
}
base_ref=$(resolve_base_ref "$entry" "$worktree_path") || {
  echo "ERROR: cannot work out the base commit for '$NAME'." >&2
  exit 1
}

trim_file=$(trim_file_for "$NAME")
brief_file="${trim_file%.json}.brief.md"
reply_file="${trim_file%.json}.reply.txt"
trim_kind=""
model="$TRIM_MODEL"

write_trim() {  # status  summary  cuts-json
  local cuts="${3:-[]}"
  jq -e . >/dev/null 2>&1 <<<"$cuts" || cuts='[]'
  jq -n --arg status "$1" --arg summary "$2" --argjson cuts "$cuts" \
        --arg model "$model" --arg kind "$trim_kind" --arg ts "$(date -u +%FT%TZ)" \
    '{status: $status, model: $model, kind: $kind, cuts: $cuts, summary: $summary, ran_at: $ts}' \
    > "$trim_file"
  trace "$NAME" "trim.write" "$1 ($(jq 'length' <<<"$cuts") cuts) -> $trim_file"
}

critique_verdict="not run"
critique_file=$(critique_file_for "$NAME")
[[ -f "$critique_file" ]] && critique_verdict=$(jq -r '.verdict // "?"' "$critique_file" 2>/dev/null || echo "?")
if [[ "$critique_verdict" == "revise" || "$critique_verdict" == "reject" ]]; then
  echo "NOTE: the critique says $critique_verdict. Fix correctness first; trimming a diff"
  echo "      that is about to change is wasted work."
fi

diff_stat=$(git -C "$worktree_path" diff --stat "${base_ref}...HEAD" 2>/dev/null || true)
diff_body=$(git -C "$worktree_path" diff "${base_ref}...HEAD" 2>/dev/null || true)
trace "$NAME" "diff.collect" "git diff ${base_ref:0:12}...HEAD -> $(wc -l <<<"$diff_body") lines"

if [[ -z "$diff_body" ]]; then
  echo "=== $NAME: trim SKIPPED === no diff against ${base_ref:0:12}."
  write_trim "skipped" "no diff against the base commit"
  exit 0
fi

truncated_note=""
if (( $(wc -l <<<"$diff_body") > CRITIQUE_DIFF_LINES )); then
  diff_body=$(head -n "$CRITIQUE_DIFF_LINES" <<<"$diff_body")
  truncated_note="
The diff above was cut off at $CRITIQUE_DIFF_LINES lines. Read the rest with
\`git diff ${base_ref}...HEAD\` if you need it."
fi

cat > "$brief_file" <<EOF
# Overengineering brief

Another AI agent wrote the change below. Its correctness, scope and safety have
already been reviewed separately. Your only job is to find where it is bigger or
more elaborate than the task needed, and say what could be cut.

## The task the agent was given

$task_prompt

## Changed files

$diff_stat

## Diff (${base_ref}...HEAD)

\`\`\`diff
$diff_body
\`\`\`
$truncated_note

Your working directory is the repository, checked out on the task's branch. Read
existing code before claiming a helper duplicates something.

## Look for

- Abstractions, interfaces, factories or layers with a single caller.
- Options, flags, parameters or config nobody sets or reads.
- Generalisation for cases the task does not mention.
- Code that re-implements a helper the repository already has.
- Dead code, unused imports, leftover scaffolding.
- Defensive handling of states that cannot occur here.
- New dependencies that a few lines of existing code would replace.

## Do not

- Judge correctness, security, or test coverage. That review already happened.
- Suggest cutting validation of external input, error handling on I/O, or tests.
- Comment on naming, formatting, or style.
- Propose rewrites that make the change larger.

When nothing is worth cutting, say so with an empty list. That is a normal answer.

## Output

Output exactly one JSON object and nothing else. No prose, no code fence.

{"cuts":[{"file":"path/to/file","what":"what to remove or simplify","why":"one sentence","saves":"rough lines saved"}],"summary":"one sentence"}
EOF

brief_arg="$brief_file"
trust_path="$worktree_path"
if command -v cygpath >/dev/null 2>&1; then
  brief_arg=$(cygpath -m "$(cd "$(dirname "$brief_file")" && pwd)")/"$(basename "$brief_file")"
  trust_path=$(cygpath -w "$worktree_path")
fi
instruction="Read the overengineering brief at ${brief_arg} and follow it exactly. Output only the single JSON object it specifies."

trim_kind="${HERDR_SWARM_TRIM_KIND:-$(critique_kind_for "$model")}"
trace "$NAME" "reviewer.pick" "${trim_kind:-<none>} for model $model"
if [[ -z "$trim_kind" ]]; then
  echo "=== $NAME: trim SKIPPED === no agy, codex or gemini binary on PATH." >&2
  write_trim "skipped" "no reviewer binary available"
  exit 0
fi
autoflag=$(autoflag_for_kind "$trim_kind") || {
  echo "ERROR: '$trim_kind' is not a supported kind." >&2
  write_trim "error" "unsupported kind '$trim_kind'"
  exit 0
}

case "$trim_kind" in
  agy)
    cmd=(agy -p "$instruction" "$autoflag" --model "$model") ;;
  codex)
    model="$CODEX_FALLBACK_MODEL"
    mapfile -t plugin_args < <(codex_swarm_args)
    cmd=(codex exec "$autoflag" ${plugin_args[@]+"${plugin_args[@]}"}
         --model "$model"
         -c "model_reasoning_effort=\"$CRITIQUE_EFFORT\""
         -c "projects.'${trust_path}'.trust_level=\"trusted\""
         "$instruction") ;;
  gemini)
    cmd=(gemini -p "$instruction" "$autoflag") ;;
esac

echo "=== $NAME: trim (advisory) ==="
echo "reviewer:  $trim_kind / $model"
echo "brief:     $brief_file"
echo

run_rc=0
trace "$NAME" "reviewer.exec" "in $worktree_path: ${cmd[*]}"
( cd "$worktree_path" && MSYS_NO_PATHCONV=1 timeout "$TRIM_TIMEOUT" "${cmd[@]}" ) \
  > "$reply_file" 2>&1 || run_rc=$?
trace "$NAME" "reviewer.exec" "rc=$run_rc, $(wc -c <"$reply_file") bytes of reply in $reply_file"

parsed=""
if ! parsed=$(extract_json < "$reply_file" 2>/dev/null) || ! jq -e '.cuts | arrays' >/dev/null 2>&1 <<<"$parsed"; then
  echo "TRIM UNPARSEABLE (exit $run_rc): no usable JSON. Raw reply: $reply_file"
  write_trim "unparseable" "reviewer reply was not valid JSON"
  exit 0
fi

cuts=$(jq -c '.cuts' <<<"$parsed")
summary=$(jq -r '.summary // ""' <<<"$parsed")
n=$(jq 'length' <<<"$cuts")
if (( n == 0 )); then status="lean"; else status="trim"; fi
write_trim "$status" "$summary" "$cuts"

echo "RESULT: $status ($n suggested cuts)"
if [[ -n "$summary" ]]; then echo "$summary"; fi
if (( n > 0 )); then
  echo
  jq -r '.[] | "  - \(.file // "?"): \(.what // "")\n      why: \(.why // "")\(if .saves then " (saves \(.saves))" else "" end)"' <<<"$cuts"
  echo
  echo "These are suggestions from a cheap model, not findings. Take the ones you agree"
  echo "with back to the agent, then re-run verify.sh; ignore the rest."
fi
exit 0
