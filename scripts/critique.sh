#!/usr/bin/env bash
# Have a cheap model review one task's diff before the orchestrator reads it.
#
# This is the judgement half of the egress gate. verify.sh proves the change
# still builds; critique.sh asks whether it is the change that was asked for,
# using the same brief the agent was given as the yardstick. It runs one-shot on
# the Antigravity Gemini pool, so a diff that ignored half the task, deleted a
# test or wandered off into unrelated files is sent back to its author without
# costing the orchestrator a read.
#
# The verdict advises. It never approves: see the note at the bottom of the
# output and the safety notes in SKILL.md.
#
# Usage: critique.sh [--trace] <task-name> [state.json]
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TRACE_SRC="critiq"
strip_trace_flag "$@"; set -- ${ARGV[@]+"${ARGV[@]}"}
trace_banner

NAME="${1:?Usage: critique.sh [--trace] <task-name> [state.json]}"
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
# The recon the orchestrator did before writing the task. Grading against named
# traps is the point: a diff where a translated comment stopped describing the
# code one line below it came back "pass", confidence high, because the reviewer
# had nothing specific to look for.
task_pitfalls=$(jq -c '.pitfalls // []' <<<"$entry")
task_files=$(jq -c '.files // []' <<<"$entry")
n_pitfalls=$(jq 'length' <<<"$task_pitfalls")
worker_model=$(jq -r '.model // empty' <<<"$entry")

[[ -n "$worktree_path" && -d "$worktree_path" ]] || {
  echo "ERROR: worktree path unknown or missing for '$NAME' (got: '$worktree_path')." >&2
  exit 1
}

base_ref=$(resolve_base_ref "$entry" "$worktree_path") || {
  echo "ERROR: cannot work out the base commit for '$NAME'." >&2
  exit 1
}

critique_file=$(critique_file_for "$NAME")
brief_file="${critique_file%.json}.brief.md"
reply_file="${critique_file%.json}.reply.txt"

critique_kind=""
confidence=""
reviewer_model=$(critique_model_for "$worker_model")
[[ "$reviewer_model" == "$CRITIQUE_MODEL" ]] \
  || trace "$NAME" "reviewer.model" "task was written by $worker_model, reviewing on $reviewer_model instead"

# Every exit path leaves a verdict file behind, so status.sh always has an
# answer to show and never re-runs a critique that already happened.
write_verdict() {  # verdict  summary  issues-json  pitfalls-checked-json
  local issues="${3:-[]}"
  jq -e . >/dev/null 2>&1 <<<"$issues" || issues='[]'
  local checked="${4:-[]}"
  jq -e . >/dev/null 2>&1 <<<"$checked" || checked='[]'
  local independent=true
  [[ -n "$worker_model" && "$reviewer_model" == "$worker_model" ]] && independent=false
  jq -n --arg verdict "$1" --arg summary "$2" --argjson issues "$issues" \
        --arg model "$reviewer_model" --arg kind "$critique_kind" \
        --arg worker_model "$worker_model" --argjson independent "$independent" \
        --arg reviewer_verdict "${reviewer_verdict:-}" \
        --argjson pitfalls_checked "$checked" \
        --argjson truncated "${diff_truncated:-false}" \
        --arg confidence "$confidence" --arg ts "$(date -u +%FT%TZ)" \
    '{verdict: $verdict, confidence: $confidence, model: $model, kind: $kind,
      worker_model: $worker_model, independent: $independent,
      reviewer_verdict: $reviewer_verdict,
      pitfalls_checked: $pitfalls_checked, diff_truncated: $truncated,
      issues: $issues, summary: $summary, ran_at: $ts}' > "$critique_file"
  trace "$NAME" "verdict.write" "$1${confidence:+ (confidence: $confidence)} -> $critique_file"
}

# --- Gather what the reviewer needs to judge --------------------------------

diff_stat=$(git -C "$worktree_path" diff --stat "${base_ref}...HEAD" 2>/dev/null || true)
diff_body=$(git -C "$worktree_path" diff "${base_ref}...HEAD" 2>/dev/null || true)
trace "$NAME" "diff.collect" "git diff ${base_ref:0:12}...HEAD -> $(wc -l <<<"$diff_body") lines"

if [[ -z "$diff_body" ]]; then
  echo "=== $NAME: critique SKIPPED ==="
  echo "No diff against ${base_ref:0:12}, so there is nothing to review."
  echo "If you expected changes, the agent committed nothing: scripts/logs.sh $NAME"
  write_verdict "skipped" "no diff against the base commit"
  exit 0
fi

truncated_note=""
diff_truncated=false
if (( $(wc -l <<<"$diff_body") > CRITIQUE_DIFF_LINES )); then
  diff_truncated=true
  diff_body=$(head -n "$CRITIQUE_DIFF_LINES" <<<"$diff_body")
  truncated_note="
The diff above was cut off at $CRITIQUE_DIFF_LINES lines. Read the rest yourself with
\`git diff ${base_ref}...HEAD\` before judging anything you cannot see."
fi

verify_status="not run"
verify_cmd=""
verify_file=$(verify_file_for "$NAME")
if [[ -f "$verify_file" ]]; then
  verify_status=$(jq -r '.status // "?"' "$verify_file" 2>/dev/null || echo "?")
  verify_cmd=$(jq -r '.cmd // ""' "$verify_file" 2>/dev/null || echo "")
fi

[[ -n "$task_prompt" ]] || task_prompt="(not recorded; this task predates prompts being stored in state.json)"

# Generated from the fields, never hand-written, so a task cannot reach the
# reviewer with its traps left out. An older task carries neither field; those
# sections are then absent rather than empty, because an empty criteria list
# reads as "nothing to check" and that is not what a missing field means.
pitfalls_section=""
if (( n_pitfalls > 0 )); then
  pitfalls_section="## Pitfalls the task declared

The orchestrator found these traps by reading the code before writing the task.
Judge the diff against each one, by number:

$(jq -r 'to_entries[] | "\(.key + 1). \(.value)"' <<<"$task_pitfalls")
"
fi

scope_section=""
if [[ "$(jq 'length' <<<"$task_files")" -gt 0 ]]; then
  scope_section="## The scope the task declared

The task said it would touch these files:

$(jq -r '.[] | "- " + .' <<<"$task_files")

Flag every change outside that list. For each one, say whether it was necessary
work. Straying is not automatically wrong - a new test file or a package import
is legitimate - so report it, do not assume it is a defect.
"
fi

# --- The brief --------------------------------------------------------------
#
# Written to a file rather than passed on the command line. A diff of any size
# blows past the Windows command-line limit, and the earlier fix for the same
# problem in herdr prompt delivery applies here too.

cat > "$brief_file" <<EOF
# Code review brief

You are reviewing a code change written by another AI agent. Be skeptical. The
agent ran with every confirmation disabled and grades its own homework, so its
own claim of success is not evidence.

## The task the agent was given

$task_prompt

## Deterministic check already run

verify: $verify_status${verify_cmd:+ ($verify_cmd)}

## Changed files

$diff_stat

## Diff (${base_ref}...HEAD)

\`\`\`diff
$diff_body
\`\`\`
$truncated_note

Your working directory is the repository under review, checked out on the task's
branch. Read any file you need for context instead of guessing.

$pitfalls_section
$scope_section
## What to judge, in this order

1. **The declared pitfalls**, if the task listed any. For each one, decide
   whether the diff respected it, violated it, or whether it turned out not to
   apply. A violated pitfall is at least a major issue, so it cannot be a pass.
2. **Completeness.** Does the change do everything the task asked? Work that is
   missing, stubbed, or silently narrowed is a blocker.
3. **Scope.** Does it do anything the task did not ask for? Deleted or skipped
   tests, weakened assertions, disabled lint rules, commented-out code, and
   unrelated edits are blockers even when the tests pass.
4. **Correctness.** Logic errors, unhandled cases, call sites not updated,
   wrong types, off-by-one, resource leaks.
5. **Safety.** Hardcoded secrets, injection, dropped authentication or
   authorization checks, destructive filesystem or shell operations.
6. **Tests.** Is there a test that would fail without this change?

Do not comment on style, naming, formatting, or preference. Do not propose
refactors. Report only what is wrong.

## Output

Output exactly one JSON object and nothing else. No prose, no code fence.

{"verdict":"pass|revise|reject","confidence":"low|medium|high","issues":[{"severity":"blocker|major|minor","file":"path/to/file","note":"one sentence"}],"pitfalls_checked":[{"pitfall":1,"status":"respected|violated|not-applicable","note":"one sentence"}],"summary":"one sentence"}

- \`pass\` means no blocker and no major issue. Use an empty issues array.
- \`revise\` means real problems the same agent can fix with a follow-up prompt.
- \`reject\` means the approach is wrong, or the change does something dangerous,
  in a way another prompt to the same agent will not fix.
- Set \`confidence\` to \`low\` when the truncated diff or missing context kept you
  from judging properly. Guessing confidently is worse than saying so.
- \`pitfalls_checked\` has one entry per declared pitfall, in the order they were
  listed, with \`pitfall\` set to that number. It is how the operator tells a
  thorough pass from a shallow one, so do not leave it out and do not include a
  pitfall you did not actually look for. Use an empty array when the task
  declared none.
EOF

# The agent binary is a native Windows build under Git Bash and reads MSYS paths
# against the wrong root, the same trap as the result file in launch.sh.
brief_arg="$brief_file"
trust_path="$worktree_path"
if command -v cygpath >/dev/null 2>&1; then
  brief_arg=$(cygpath -m "$(cd "$(dirname "$brief_file")" && pwd)")/"$(basename "$brief_file")"
  trust_path=$(cygpath -w "$worktree_path")
fi

instruction="Read the code review brief at ${brief_arg} and follow it exactly. Output only the single JSON object it specifies."

# --- Pick a pool and run it -------------------------------------------------

critique_kind=$(critique_kind_for "$reviewer_model")
trace "$NAME" "reviewer.pick" "${critique_kind:-<none>} for model $reviewer_model"
if [[ -z "$critique_kind" ]]; then
  echo "=== $NAME: critique SKIPPED ==="
  echo "No agy, codex or gemini binary on PATH, so nothing can run the review." >&2
  write_verdict "skipped" "no reviewer binary available"
  exit 0
fi

autoflag=$(autoflag_for_kind "$critique_kind") || {
  echo "ERROR: HERDR_SWARM_CRITIQUE_KIND='$critique_kind' is not a supported kind." >&2
  write_verdict "error" "unsupported critique kind '$critique_kind'"
  exit 0
}

cmd=()
reviewer_label="$critique_kind"
case "$critique_kind" in
  agy)
    cmd=(agy -p "$instruction" "$autoflag" --model "$reviewer_model")
    reviewer_label="agy / $reviewer_model"
    ;;
  codex)
    # codex exec is the non-interactive mode. The trust override is the same one
    # launch.sh needs: without it codex asks whether it trusts the directory and
    # waits forever, which the bypass flag does not cover. Plugins are off for
    # the same reason as in launch.sh: the reply has to parse as JSON.
    mapfile -t plugin_args < <(codex_swarm_args)
    cmd=(codex exec "$autoflag" ${plugin_args[@]+"${plugin_args[@]}"}
         --model "$CODEX_FALLBACK_MODEL"
         -c "model_reasoning_effort=\"$CRITIQUE_EFFORT\""
         -c "projects.'${trust_path}'.trust_level=\"trusted\""
         "$instruction")
    reviewer_model="$CODEX_FALLBACK_MODEL"
    reviewer_label="codex / $CODEX_FALLBACK_MODEL"
    ;;
  gemini)
    # Classic gemini CLI has no model menu, so the reviewer model is recorded in
    # the verdict file for the record but not applied here.
    cmd=(gemini -p "$instruction" "$autoflag")
    reviewer_label="gemini / default"
    ;;
esac

echo "=== $NAME: critique ==="
echo "reviewer:  $reviewer_label"
if [[ -n "$worker_model" && "$reviewer_model" == "$worker_model" ]]; then
  # Only reachable when the Gemini pool was empty and the codex fallback task is
  # now being reviewed by codex too. Say so rather than pretend it is independent.
  echo "WARNING:   the reviewer is the same model that wrote this diff ($worker_model)."
  echo "           Weigh a pass accordingly; it is not an independent review."
  trace "$NAME" "reviewer.model" "not independent: reviewer and worker are both $worker_model"
fi
echo "worktree:  $worktree_path"
echo "base:      ${base_ref:0:12}"
echo "brief:     $brief_file"
echo

# MSYS_NO_PATHCONV so a path inside the instruction is not rewritten, same as
# the /usage call in lib.sh.
run_rc=0
trace "$NAME" "reviewer.exec" "in $worktree_path: ${cmd[*]}"
( cd "$worktree_path" && MSYS_NO_PATHCONV=1 timeout "$CRITIQUE_TIMEOUT" "${cmd[@]}" ) \
  > "$reply_file" 2>&1 || run_rc=$?
trace "$NAME" "reviewer.exec" "rc=$run_rc, $(wc -c <"$reply_file") bytes of reply in $reply_file"

if [[ "$run_rc" -ne 0 && ! -s "$reply_file" ]]; then
  echo "CRITIQUE ERROR (exit $run_rc): the reviewer produced no output."
  echo "Output: $reply_file"
  write_verdict "error" "reviewer exited $run_rc with no output"
  echo
  echo "Next: review the diff yourself -> scripts/review.sh $NAME"
  exit 0
fi

# --- Parse the verdict ------------------------------------------------------

parsed=""
if ! parsed=$(extract_json < "$reply_file" 2>/dev/null) || ! jq -e . >/dev/null 2>&1 <<<"$parsed"; then
  trace "$NAME" "verdict.parse" "no valid JSON object in the reply"
  echo "CRITIQUE UNPARSEABLE: the reviewer did not return usable JSON."
  echo "Raw reply: $reply_file"
  write_verdict "unparseable" "reviewer reply was not valid JSON"
  echo
  echo "Next: this tells you nothing either way. Review the diff yourself ->"
  echo "  scripts/review.sh $NAME"
  exit 0
fi

verdict=$(jq -r '.verdict // "unparseable"' <<<"$parsed")
confidence=$(jq -r '.confidence // ""' <<<"$parsed")
summary=$(jq -r '.summary // ""' <<<"$parsed")
issues=$(jq -c '.issues // []' <<<"$parsed")
# The reviewer answers with the number it was given. Resolve it back to the text
# here, so the verdict file says what was checked without needing the task config
# beside it. An out-of-range number keeps whatever the reviewer wrote.
pitfalls_checked=$(jq -c --argjson declared "$task_pitfalls" '
    [ (.pitfalls_checked // [])[]
      | . as $c
      | .pitfall = ( if (.pitfall | type) == "number" and $declared[.pitfall - 1] != null
                     then $declared[.pitfall - 1] else .pitfall end ) ]' <<<"$parsed")

case "$verdict" in
  pass|revise|reject) ;;
  *) verdict="unparseable"; summary="reviewer returned an unknown verdict" ;;
esac

# What the reviewer actually said, kept whatever happens next, so a downgrade is
# auditable rather than a quiet rewrite of someone else's answer.
reviewer_verdict="$verdict"
n_violated=$(jq '[.[] | select(.status == "violated")] | length' <<<"$pitfalls_checked")
if [[ "$verdict" == "pass" ]] && (( n_violated > 0 )); then
  # The brief states that a violated pitfall cannot be a pass, so this reply
  # contradicts itself. Reporting it as a pass is how a defect the agent was
  # warned about reaches the operator looking green.
  verdict="revise"
  summary="reviewer passed the diff while reporting $n_violated declared pitfall(s) as violated, which cannot be a pass; downgraded. ${summary}"
  trace "$NAME" "verdict.downgrade" "pass -> revise, $n_violated violated pitfall(s)"
fi

trace "$NAME" "verdict.parse" "$verdict ($(jq 'length' <<<"$issues") issues, $(jq 'length' <<<"$pitfalls_checked") of $n_pitfalls pitfall(s) examined, confidence ${confidence:-unset})"
write_verdict "$verdict" "$summary" "$issues" "$pitfalls_checked"

echo "VERDICT: $verdict${confidence:+ (confidence: $confidence)}"
# Plain `[[ ... ]] && echo` would exit the script under `set -e` when the summary
# is empty, taking the issue list and the next-step hint down with it.
if [[ -n "$summary" ]]; then echo "$summary"; fi
if [[ "$(jq 'length' <<<"$issues")" -gt 0 ]]; then
  echo
  echo "--- issues ---"
  jq -r '.[] | "  [\(.severity // "?")] \(.file // "?"): \(.note // "")"' <<<"$issues"
fi
# A pass that examined nothing and a pass that checked three named traps are not
# the same answer, so the count is always shown, and a violated pitfall is named
# in full rather than left to the summary.
if (( n_pitfalls > 0 )); then
  echo
  echo "--- pitfalls ($(jq 'length' <<<"$pitfalls_checked") of $n_pitfalls examined) ---"
  jq -r '.[] | "  [\(.status // "?")] \(.pitfall)\(if (.note // "") == "" then "" else " - " + .note end)"' \
    <<<"$pitfalls_checked"
  if [[ "$(jq '[.[] | select(.status == "violated")] | length' <<<"$pitfalls_checked")" -gt 0 ]]; then
    echo
    echo "A declared pitfall was reported as violated. The agent was told about that"
    echo "trap before it started, so treat this as the diff ignoring its brief."
  fi
fi
echo

case "$verdict" in
  pass)
    echo "One cheap model found nothing. That narrows your read; it does not replace it."
    echo "Next: scripts/review.sh $NAME"
    exit 0
    ;;
  revise|reject)
    echo "Next: send the issues back to the agent, e.g."
    echo "  herdr agent prompt $NAME \"critique found: <paste the issues above>. Fix them and commit.\" --wait"
    echo "Cap this at 2 rounds, then take it to the user."
    exit 1
    ;;
  *)
    echo "Next: review the diff yourself -> scripts/review.sh $NAME"
    exit 0
    ;;
esac
