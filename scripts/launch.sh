#!/usr/bin/env bash
# Launch one or more gemini/agy sub-agents through herdr, each on its own
# git worktree + branch, per a tasks.json config.
# Usage: launch.sh <tasks.json>
set -euo pipefail

TASKS_FILE="${1:?Usage: launch.sh <tasks.json>}"
STATE_DIR="${HERDR_SWARM_STATE_DIR:-.herdr-swarm}"
STATE_FILE="$STATE_DIR/state.json"

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [[ "${HERDR_ENV:-}" != "1" ]]; then
  echo "ERROR: HERDR_ENV != 1, so this is not a herdr-managed pane. Refusing to launch agents." >&2
  exit 1
fi

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required." >&2; exit 1; }
command -v herdr >/dev/null 2>&1 || { echo "ERROR: herdr not found on PATH." >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "ERROR: git is required." >&2; exit 1; }
[[ -f "$TASKS_FILE" ]] || { echo "ERROR: $TASKS_FILE not found." >&2; exit 1; }

mkdir -p "$STATE_DIR"
entries_file="$STATE_DIR/.entries.jsonl"
: > "$entries_file"

autoflag_for_kind() {
  case "$1" in
    gemini) echo "--yolo" ;;
    agy)    echo "--dangerously-skip-permissions" ;;
    codex)  echo "--dangerously-bypass-approvals-and-sandbox" ;;
    *)      echo "ERROR: unsupported kind '$1' (expected 'gemini', 'agy' or 'codex')" >&2; exit 1 ;;
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
    echo "ERROR: task name '$name' doesn't match herdr's agent-name rule [a-z][a-z0-9_-]{0,31}. Skipping." >&2
    continue
  fi
  [[ -d "$repo" ]] || { echo "ERROR: repo '$repo' for task '$name' does not exist. Skipping." >&2; continue; }
  git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || { echo "ERROR: '$repo' is not a git repo. Skipping task '$name'." >&2; continue; }

  if [[ -n "$model" && "$kind" == "gemini" ]]; then
    echo "WARN: [$name] 'model' is set but kind is 'gemini', which has no model menu. Ignoring it." >&2
    model=""
    effort=""
  fi

  # Antigravity quota runs down per pool and can reach 0% mid-swarm. An agent
  # that cannot make a single call looks exactly like one still thinking, so
  # check the quota first and route the task to codex instead.
  fallback_from=""
  if [[ "$kind" == "agy" && "${HERDR_SWARM_NO_FALLBACK:-0}" != "1" ]]; then
    quota_rc=0
    agy_exhausted "$model" || quota_rc=$?
    case "$quota_rc" in
      0)
        echo "==> [$name] $(agy_family_for_model "$model") is at 0%. Running on codex $CODEX_FALLBACK_MODEL ($CODEX_FALLBACK_EFFORT) instead of agy ${model:-default}."
        fallback_from="agy:${model:-default}"
        kind="codex"
        model="$CODEX_FALLBACK_MODEL"
        effort="$CODEX_FALLBACK_EFFORT"
        ;;
      2)
        echo "WARN: [$name] could not read the agy quota, so the task stays on agy. Check it by hand with: MSYS_NO_PATHCONV=1 agy -p /usage" >&2
        ;;
    esac
  fi

  model_args=()
  case "$kind" in
    agy)
      [[ -n "$model" ]] && model_args+=(--model "$model")
      [[ -n "$effort" ]] && model_args+=(--effort "$effort")
      ;;
    codex)
      # codex takes reasoning depth through config, not a flag. The inner quotes
      # are literal, so the value reaches codex as TOML rather than a bare word.
      [[ -n "$model" ]] && model_args+=(--model "$model")
      [[ -n "$effort" ]] && model_args+=(-c "model_reasoning_effort=\"$effort\"")
      # On a repo it has not seen, codex opens with "Do you trust the contents of
      # this directory?" and waits. --dangerously-bypass-approvals-and-sandbox
      # does not cover it, and herdr reports the agent as blocked during startup,
      # so the prompt is never sent. Trust decisions key off the repo root rather
      # than the worktree, and this override lasts for the run only, leaving
      # ~/.codex/config.toml alone.
      trust_path="$repo"
      command -v cygpath >/dev/null 2>&1 && trust_path=$(cygpath -w "$repo")
      model_args+=(-c "projects.'${trust_path}'.trust_level=\"trusted\"")
      ;;
  esac

  autoflag=$(autoflag_for_kind "$kind")
  # The agent is a native Windows binary under Git Bash, and it does not resolve
  # MSYS paths the way bash does: it reads /tmp as C:\tmp, so a result file it
  # writes there is invisible to status.sh. Hand it a path its own OS agrees with.
  # Git Bash reads the C:/... form back fine, so store that single form.
  status_dir="$(cd "$STATE_DIR" && pwd)"
  if command -v cygpath >/dev/null 2>&1; then
    status_dir=$(cygpath -m "$status_dir")
  fi
  status_file="${status_dir}/${name}.result.json"

  echo "==> [$name] creating worktree for branch '$branch' from $repo"
  base_args=()
  [[ -n "$base" ]] && base_args+=(--base "$base")

  # Pin the base to a commit SHA now, before the agent commits anything. Inside
  # the task's own worktree HEAD is the task branch, so a later `merge-base HEAD
  # <branch>` resolves to the branch tip and review.sh reports an empty diff.
  base_sha=$(git -C "$repo" rev-parse --verify "${base:-HEAD}^{commit}" 2>/dev/null || true)
  [[ -n "$base_sha" ]] || echo "WARN: [$name] could not resolve base '${base:-HEAD}' to a commit; review.sh will have to guess." >&2
  created=$(herdr worktree create --cwd "$repo" --branch "$branch" "${base_args[@]}" --label "$name" --no-focus)

  pane_id=$(jq -r '.result.root_pane.pane_id' <<<"$created")
  workspace_id=$(jq -r '.result.workspace.workspace_id' <<<"$created")
  worktree_path=$(jq -r '.result.workspace.worktree.checkout_path // empty' <<<"$created" | tr '\\' '/')
  [[ -n "$worktree_path" ]] || worktree_path=$(worktree_path_of "$workspace_id")
  if [[ -z "$worktree_path" ]]; then
    echo "WARN: [$name] could not resolve the worktree path. review.sh will have to ask herdr for it." >&2
  fi

  echo "==> [$name] starting $kind agent in pane $pane_id${model:+ (model: $model${effort:+ / $effort})}"
  # One agent failing to start must not abandon the tasks after it, and it must
  # not leave an empty worktree behind either. Tear this one down and carry on.
  if ! herdr agent start "$name" --kind "$kind" --pane "$pane_id" --timeout "$timeout_ms" \
       -- "$autoflag" "${model_args[@]}" "${extra_args[@]}" >/dev/null; then
    echo "ERROR: [$name] $kind did not start. Read the pane with: herdr agent read $name --source recent-unwrapped" >&2
    herdr worktree remove --workspace "$workspace_id" --force >/dev/null 2>&1 \
      || echo "WARN: [$name] could not remove workspace $workspace_id; clean it up by hand." >&2
    continue
  fi

  full_prompt="${prompt}

Commit your changes as you go, with descriptive commit messages. Do not leave uncommitted changes at the end. Run 'git status' before finishing and commit or discard anything left over.

When you are completely finished, write a JSON file to ${status_file} with the shape {\"status\": \"success\"|\"failure\", \"summary\": \"<short text>\", \"tests_passed\": true|false} as your very last action. Create parent directories if needed."

  # `agent start` returns once the process exists, which is earlier than the TUI
  # accepting input. Prompting in that window loses the prompt without an error:
  # herdr answers agent_prompted, the agent never sees it, and the pane sits idle
  # with an empty input box, looking exactly like a task nobody has reviewed yet.
  echo "==> [$name] waiting for $kind to accept input"
  ready=""
  for _ in $(seq 1 60); do
    if agent_ready "$name"; then ready=1; break; fi
    sleep 1
  done
  [[ -n "$ready" ]] || echo "WARN: [$name] still not interactive after 60s. Sending anyway." >&2

  echo "==> [$name] sending prompt (not waiting, runs in background)"
  submit_prompt "$name" "$full_prompt" || echo "ERROR: [$name] prompt was not picked up; resend it by hand." >&2

  # An unset base is an empty string, not null, so `// "HEAD"` would not catch it.
  jq -n --arg name "$name" --arg kind "$kind" --arg branch "$branch" \
        --arg base "${base:-HEAD}" --arg base_sha "$base_sha" \
        --arg pane_id "$pane_id" --arg workspace_id "$workspace_id" \
        --arg worktree_path "$worktree_path" --arg status_file "$status_file" \
        --arg model "$model" --arg effort "$effort" --arg fallback_from "$fallback_from" \
    '{name: $name, kind: $kind, branch: $branch, base: $base, base_sha: $base_sha,
      model: $model, effort: $effort, fallback_from: $fallback_from,
      pane_id: $pane_id, workspace_id: $workspace_id,
      worktree_path: $worktree_path, status_file: $status_file}' \
    >> "$entries_file"
done

jq -s '.' "$entries_file" > "$STATE_FILE"
rm -f "$entries_file"

echo
echo "Launched. State written to $STATE_FILE"
echo "Check on them with: scripts/status.sh"
