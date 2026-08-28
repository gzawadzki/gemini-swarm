#!/usr/bin/env bash
# Launch one or more gemini/agy sub-agents through herdr, each on its own
# git worktree + branch, per a tasks.json config.
# Usage: launch.sh <tasks.json>
set -euo pipefail

TASKS_FILE="${1:?Usage: launch.sh <tasks.json>}"
STATE_DIR="${HERDR_SWARM_STATE_DIR:-.herdr-swarm}"
STATE_FILE="$STATE_DIR/state.json"
# Briefs and result files live OUTSIDE every repo/worktree, so agents never
# dirty a tree by writing them, and so the paths stay valid across worktrees.
BRIEF_DIR="${HERDR_SWARM_BRIEF_DIR:-$HOME/.herdr/briefs}"
# herdr rejects agent start timeouts above this, so oversized values in a
# tasks.json get clamped rather than failing the launch.
MAX_TIMEOUT_MS=300000

if [[ "${HERDR_ENV:-}" != "1" ]]; then
  echo "ERROR: HERDR_ENV != 1 — not running inside a herdr-managed pane. Refusing to launch agents." >&2
  exit 1
fi

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required." >&2; exit 1; }
command -v herdr >/dev/null 2>&1 || { echo "ERROR: herdr not found on PATH." >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "ERROR: git is required." >&2; exit 1; }
[[ -f "$TASKS_FILE" ]] || { echo "ERROR: $TASKS_FILE not found." >&2; exit 1; }

mkdir -p "$STATE_DIR" "$BRIEF_DIR"
entries_file="$STATE_DIR/.entries.jsonl"
: > "$entries_file"

# The agent runs as a native Windows process when on Windows, so hand it
# C:/Users/... rather than an MSYS /c/Users/... path it can't open.
to_native() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

autoflag_for_kind() {
  case "$1" in
    gemini) echo "--yolo" ;;
    agy)    echo "--dangerously-skip-permissions" ;;
    *)      echo "ERROR: unsupported kind '$1' (expected 'gemini' or 'agy')" >&2; exit 1 ;;
  esac
}

n_tasks=$(jq '.tasks | length' "$TASKS_FILE")
echo "Launching $n_tasks task(s) from $TASKS_FILE"

for i in $(seq 0 $((n_tasks - 1))); do
  task=$(jq -c ".tasks[$i]" "$TASKS_FILE")
  name=$(jq -r '.name' <<<"$task")
  kind=$(jq -r '.kind' <<<"$task")
  repo=$(jq -r '.repo' <<<"$task")
  branch=$(jq -r '.branch // ("agent/" + .name)' <<<"$task")
  base=$(jq -r '.base // empty' <<<"$task")
  prompt=$(jq -r '.prompt' <<<"$task")
  model=$(jq -r '.model // empty' <<<"$task")
  effort=$(jq -r '.effort // empty' <<<"$task")
  timeout_ms=$(jq -r '.timeout_ms // 30000' <<<"$task")
  mapfile -t extra_args < <(jq -r '.args // [] | .[]' <<<"$task")

  if ! [[ "$name" =~ ^[a-z][a-z0-9_-]{0,31}$ ]]; then
    echo "ERROR: task name '$name' doesn't match herdr's agent-name rule [a-z][a-z0-9_-]{0,31} — skipping." >&2
    continue
  fi
  [[ -d "$repo" ]] || { echo "ERROR: repo '$repo' for task '$name' doesn't exist — skipping." >&2; continue; }
  git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || { echo "ERROR: '$repo' is not a git repo — skipping task '$name'." >&2; continue; }

  if (( timeout_ms > MAX_TIMEOUT_MS )); then
    echo "WARN: [$name] timeout_ms=$timeout_ms exceeds herdr's ceiling of ${MAX_TIMEOUT_MS} — clamping." >&2
    timeout_ms=$MAX_TIMEOUT_MS
  fi

  if [[ -n "$model" && "$kind" != "agy" ]]; then
    echo "WARN: [$name] 'model' is set but kind is '$kind' (only 'agy' supports --model) — ignoring." >&2
    model=""
    effort=""
  fi
  model_args=()
  [[ -n "$model" ]] && model_args+=(--model "$model")
  [[ -n "$effort" ]] && model_args+=(--effort "$effort")

  autoflag=$(autoflag_for_kind "$kind")
  brief_file="$BRIEF_DIR/${name}.md"
  status_file="$BRIEF_DIR/${name}.result.json"
  brief_native=$(to_native "$brief_file")
  status_native=$(to_native "$status_file")

  echo "==> [$name] creating worktree for branch '$branch' from $repo"
  base_args=()
  [[ -n "$base" ]] && base_args+=(--base "$base")
  created=$(herdr worktree create --cwd "$repo" --branch "$branch" "${base_args[@]}" --label "$name" --no-focus)

  # NOTE: worktree create's exact JSON shape isn't fully documented upstream;
  # this assumes it mirrors `workspace create`'s .result.workspace / .result.root_pane.
  # If this breaks, run the command manually with `| jq .` once and fix the paths below.
  pane_id=$(jq -r '.result.root_pane.pane_id' <<<"$created")
  workspace_id=$(jq -r '.result.workspace.workspace_id' <<<"$created")
  worktree_path=$(jq -r '.result.workspace.cwd // empty' <<<"$created")
  if [[ -z "$worktree_path" ]]; then
    worktree_path=$(herdr workspace get "$workspace_id" | jq -r '.result.workspace.cwd // .result.workspace.root_pane.cwd // empty')
  fi

  echo "==> [$name] starting $kind agent in pane $pane_id${model:+ (model: $model${effort:+ / $effort})}"
  herdr agent start "$name" --kind "$kind" --pane "$pane_id" --timeout "$timeout_ms" \
    -- "$autoflag" "${model_args[@]}" "${extra_args[@]}" >/dev/null

  # Everything the agent needs goes into a file. `herdr agent prompt` only
  # reliably delivers a short single line — a long multi-line brief pasted
  # straight into the input box comes back agent_prompted but arrives empty.
  cat > "$brief_file" <<BRIEF
# Task: $name

$prompt

## Ground rules

- Work only inside this worktree (branch \`$branch\`). Don't touch other
  repositories or the user's other checkouts.
- Commit your changes as you go, with descriptive commit messages.
- Do not leave uncommitted changes at the end — run \`git status\` before
  finishing and commit or discard anything left over.

## Result file (required, last action)

When you are completely finished, write a JSON file to:

    $status_native

with exactly this shape:

    {"status": "success", "summary": "<short text>", "tests_passed": true}

\`status\` is \`"success"\` or \`"failure"\`, \`tests_passed\` is \`true\` or
\`false\`. Create parent directories if needed. Write it as your very last
action, after the tree is clean.
BRIEF

  echo "==> [$name] sending prompt (not waiting — runs in background)"
  herdr agent prompt "$name" "Read the file $brief_native and carry out the task it describes in this worktree." >/dev/null

  jq -n --arg name "$name" --arg kind "$kind" --arg branch "$branch" --arg base "$base" \
        --arg pane_id "$pane_id" --arg workspace_id "$workspace_id" \
        --arg worktree_path "$worktree_path" --arg status_file "$status_file" \
        --arg brief_file "$brief_file" \
    '{name: $name, kind: $kind, branch: $branch, base: ($base // "HEAD"),
      pane_id: $pane_id, workspace_id: $workspace_id,
      worktree_path: $worktree_path, brief_file: $brief_file, status_file: $status_file}' \
    >> "$entries_file"
done

jq -s '.' "$entries_file" > "$STATE_FILE"
rm -f "$entries_file"

echo
echo "Launched. State written to $STATE_FILE"
echo "Briefs and result files: $BRIEF_DIR"
echo "Check on them with: scripts/status.sh"
