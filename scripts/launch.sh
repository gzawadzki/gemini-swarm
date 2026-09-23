#!/usr/bin/env bash
# Launch one or more pi/gemini/codex sub-agents through herdr, each on its own
# git worktree + branch, per a tasks.json config.
# Usage: launch.sh [--trace] [--allow-unsandboxed] <tasks.json>
set -euo pipefail

# lib.sh is sourced before the positional arguments are read, because it owns
# the flag parsing that has to run first.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TRACE_SRC="launch"
strip_launch_flags "$@"; set -- ${ARGV[@]+"${ARGV[@]}"}
trace_banner

TASKS_FILE="${1:?Usage: launch.sh [--trace] [--allow-unsandboxed] <tasks.json>}"
STATE_DIR="${HERDR_SWARM_STATE_DIR:-.herdr-swarm}"
STATE_FILE="$STATE_DIR/state.json"

if [[ "${HERDR_ENV:-}" != "1" ]]; then
  echo "ERROR: HERDR_ENV != 1, so this is not a herdr-managed pane. Refusing to launch agents." >&2
  exit 1
fi

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required." >&2; exit 1; }
command -v herdr >/dev/null 2>&1 || { echo "ERROR: herdr not found on PATH." >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "ERROR: git is required." >&2; exit 1; }
[[ -f "$TASKS_FILE" ]] || { echo "ERROR: $TASKS_FILE not found." >&2; exit 1; }

if ! worker_unsandboxed_allowed; then
  trace "-" "worker.security" "refused: unattended workers require explicit unsandboxed opt-in"
  echo "ERROR: Unattended worker execution is unsandboxed on this platform." >&2
  echo "Workers have unrestricted access to host files, network, and secrets." >&2
  echo "Git worktrees and tool approval flags do not provide OS-level isolation." >&2
  echo "Refusing to launch unattended workers without explicit operator opt-in." >&2
  echo "To launch workers unsandboxed for this run, pass --allow-unsandboxed or set HERDR_SWARM_ALLOW_UNSANDBOXED=1." >&2
  exit 1
fi

echo "swarm security: unsandboxed worker execution explicitly enabled for this run"
trace "-" "worker.security" "unsandboxed execution explicitly enabled by operator"

mkdir -p "$STATE_DIR" "$BRIEF_DIR"
entries_file="$STATE_DIR/.entries.jsonl"
: > "$entries_file"

# Which version of this skill is about to run. The installed path is a junction
# to the working repo, so an uncommitted half-rewrite executes live and a run that
# behaves oddly needs to be attributable to a tree state. This reports, it does
# not block: during a rebuild the tree is dirty continuously, and blocking would
# break the edit-and-try loop that the junction exists to allow.
skill_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
skill_head="unknown"
skill_dirty=0
skill_dirty_files="[]"
if git -C "$skill_root" rev-parse --git-dir >/dev/null 2>&1; then
  skill_head=$(git -C "$skill_root" rev-parse --short HEAD 2>/dev/null || echo "unknown")
  skill_dirty_files=$(git -C "$skill_root" status --porcelain 2>/dev/null | jq -R -s -c '[splits("\r?\n") | select(length > 0)]' || echo "[]")
  skill_dirty=$(jq 'length' <<<"$skill_dirty_files")
  if (( skill_dirty > 0 )); then
    echo "swarm skill: $skill_head plus $skill_dirty uncommitted file(s) - this run is NOT a committed state"
    git -C "$skill_root" status --porcelain 2>/dev/null | sed 's/^/             /'
  else
    echo "swarm skill: $skill_head (clean)"
  fi
  trace "-" "skill.state" "$skill_head dirty=$skill_dirty root=$skill_root"
fi

# Run-level facts, written before the first agent exists so they survive a launch
# that dies halfway. The config is embedded rather than referenced: the file the
# orchestrator wrote is routinely edited or deleted between runs, and reading it
# back at cleanup time would answer with whatever the next run put there. The run
# id is this instant, and it names the archive cleanup.sh writes later.
run_id=$(date -u +%Y%m%dT%H%M%SZ)
jq -n --arg run_id "$run_id" --arg tasks_file "$TASKS_FILE" \
      --arg skill_commit "$skill_head" --argjson skill_dirty "${skill_dirty:-0}" \
      --argjson skill_dirty_files "${skill_dirty_files:-[]}" \
      --arg skill_root "$skill_root" --argjson started_at "$(date +%s)" \
      --arg worker_isolation "unsandboxed" \
      --argjson allow_unsandboxed true \
      --argjson config "$(cat "$TASKS_FILE")" \
  '{run_id: $run_id, started_at: $started_at, tasks_file: $tasks_file,
    skill_commit: $skill_commit, skill_dirty: $skill_dirty,
    skill_dirty_files: $skill_dirty_files, skill_root: $skill_root,
    worker_isolation: $worker_isolation, allow_unsandboxed: $allow_unsandboxed,
    config: $config}' > "$(run_meta_file)"
trace "-" "run.meta" "$run_id skill=$skill_head dirty=${skill_dirty:-0} isolation=unsandboxed"

n_tasks=$(jq '.tasks | length' "$TASKS_FILE")
echo "Launching $n_tasks task(s) from $TASKS_FILE"
trace "-" "run.start" "$n_tasks task(s) from $TASKS_FILE"

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
  # `timeout_ms` meant two things at once: SKILL.md described waiting for the TUI,
  # the examples used it as the task's time budget, and herdr only ever read the
  # first. Anything budget-sized therefore failed the launch with
  # invalid_agent_timeout. Two fields now; the old name still parses.
  ready_timeout_ms=$(jq -r ".ready_timeout_ms // .timeout_ms // $DEFAULT_READY_TIMEOUT_MS" <<<"$task")
  work_budget_ms=$(jq -r ".work_budget_ms // $DEFAULT_WORK_BUDGET_MS" <<<"$task")
  legacy_timeout=$(jq -r '.timeout_ms // empty' <<<"$task")
  explicit_ready=$(jq -r '.ready_timeout_ms // empty' <<<"$task")
  verify=$(jq -r '.verify // empty' <<<"$task")
  files_type=$(jq -r 'if has("files") then (.files | type) else "missing" end' <<<"$task")
  pitfalls_type=$(jq -r 'if has("pitfalls") then (.pitfalls | type) else "missing" end' <<<"$task")
  mapfile -t extra_args < <(jq -r '.args // [] | .[]' <<<"$task")

  if ! [[ "$name" =~ ^[a-z][a-z0-9_-]{0,31}$ ]]; then
    echo "ERROR: task name '$name' doesn't match herdr's agent-name rule [a-z][a-z0-9_-]{0,31}. Skipping." >&2
    continue
  fi
  [[ -d "$repo" ]] || { echo "ERROR: repo '$repo' for task '$name' does not exist. Skipping." >&2; continue; }
  git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || { echo "ERROR: '$repo' is not a git repo. Skipping task '$name'." >&2; continue; }

  # A task whose code the orchestrator never read is the cause this schema exists
  # to remove: the agent discovers the traps instead, and the discoveries come
  # back as bounced verifies and invented dead code. Filling `pitfalls` honestly
  # is not possible without reading, so requiring the field enforces the reading.
  # See docs/adr/0002-required-files-and-pitfalls.md.
  missing=()
  [[ "$files_type" == "array" ]] || missing+=("files")
  [[ "$pitfalls_type" == "array" ]] || missing+=("pitfalls")
  if (( ${#missing[@]} > 0 )); then
    echo "ERROR: task '$name' is missing ${missing[*]} (each an array). Read the code this task will touch, then declare the files it may change and the traps you found - an empty 'pitfalls' array is how you say you looked and found none. Skipping. See docs/reference/task-definition.md." >&2
    trace "$name" "recon.reject" "missing: ${missing[*]}"
    continue
  fi
  # Both lists are rendered into the brief with `jq -r '.[] | "- " + .'`, which
  # fails on anything that is not a string. That render happens after the agent
  # is started, and under `set -e` a failure there would kill the run holding a
  # live agent and an orphan worktree, taking every later task with it. Check the
  # entries here, where a rejection still costs nothing.
  malformed=$(jq -r '[to_entries[] | select(.key == "files" or .key == "pitfalls")
                      | select(any(.value[]; type != "string" or . == ""))
                      | .key] | join(" and ")' <<<"$task")
  if [[ -n "$malformed" ]]; then
    echo "ERROR: task '$name' has entries in $malformed that are not non-empty strings. Each entry is one path, or one trap written out. Skipping." >&2
    trace "$name" "recon.reject" "malformed entries in $malformed"
    continue
  fi
  n_files=$(jq '.files | length' <<<"$task")
  n_pitfalls=$(jq '.pitfalls | length' <<<"$task")
  if (( n_files == 0 )); then
    echo "ERROR: task '$name' declares an empty 'files' array, so it claims to change nothing. Read the code and name the files this task is expected to touch. Skipping." >&2
    trace "$name" "recon.reject" "files declared empty"
    continue
  fi
  if (( n_pitfalls == 0 )); then
    # Accepted, because "I read it and found no traps" has to stay expressible.
    # Warned about, because it is also what a hurried orchestrator writes.
    echo "WARN: [$name] declares no pitfalls. That reads as 'I read this code and found no traps'; if you have not read it yet, stop and read it." >&2
  fi
  trace "$name" "recon.accept" "$n_files file(s), $n_pitfalls pitfall(s)"

  if [[ -n "$legacy_timeout" && -z "$explicit_ready" ]]; then
    echo "WARN: [$name] 'timeout_ms' is the old name for 'ready_timeout_ms', which is TUI readiness only (max ${MAX_READY_TIMEOUT_MS}). If you meant how long the task may run, use 'work_budget_ms'." >&2
  fi
  if (( ready_timeout_ms > MAX_READY_TIMEOUT_MS )); then
    echo "WARN: [$name] ready_timeout_ms=$ready_timeout_ms is above herdr's ceiling of ${MAX_READY_TIMEOUT_MS}; clamping. Unclamped, herdr rejects the launch with invalid_agent_timeout." >&2
    trace "$name" "timeout.clamp" "$ready_timeout_ms -> $MAX_READY_TIMEOUT_MS"
    ready_timeout_ms=$MAX_READY_TIMEOUT_MS
  fi

  if [[ -n "$model" && "$kind" == "gemini" ]]; then
    echo "WARN: [$name] 'model' is set but kind is 'gemini', which has no model menu. Ignoring it." >&2
    model=""
    effort=""
  fi

  # pi-antigravity manages linked accounts and retries the next one on a hard
  # quota wall. There is no shared agy credential to swap before launch.
  fallback_from=""
  account=""
  if [[ "$kind" == "agy" ]]; then
    echo "ERROR: [$name] kind 'agy' was replaced by 'pi'. Update the task config and relaunch. Skipping." >&2
    continue
  fi
  [[ -n "$fallback_from" ]] || trace "$name" "kind.resolve" "$kind ${model:-default}${effort:+ / $effort} (no fallback)"

  model_args=()
  case "$kind" in
    pi)
      if ! command -v pi >/dev/null 2>&1; then
        echo "ERROR: [$name] pi is not on PATH. Skipping." >&2
        continue
      fi
      model="${model:-gemini-3.8-flash-high}"
      mapfile -t model_args < <(pi_model_args "$model" "$effort")
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
      mapfile -t plugin_args < <(codex_swarm_args)
      model_args+=(${plugin_args[@]+"${plugin_args[@]}"})
      ;;
  esac

  autoflag=$(autoflag_for_kind "$kind") \
    || { echo "ERROR: [$name] unsupported kind, skipping." >&2; continue; }
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
  trace "$name" "base.pin" "${base:-HEAD} -> ${base_sha:-unresolved}"

  trace "$name" "herdr.exec" "worktree create --cwd $repo --branch $branch ${base_args[*]-}"
  created=$(herdr worktree create --cwd "$repo" --branch "$branch" "${base_args[@]}" --label "$name" --no-focus)

  pane_id=$(jq -r '.result.root_pane.pane_id' <<<"$created")
  workspace_id=$(jq -r '.result.workspace.workspace_id' <<<"$created")
  worktree_path=$(jq -r '.result.workspace.worktree.checkout_path // empty' <<<"$created" | tr '\\' '/')
  [[ -n "$worktree_path" ]] || worktree_path=$(worktree_path_of "$workspace_id")
  if [[ -z "$worktree_path" ]]; then
    echo "WARN: [$name] could not resolve the worktree path. review.sh will have to ask herdr for it." >&2
  fi
  trace "$name" "worktree.ready" "pane=$pane_id workspace=$workspace_id path=${worktree_path:-unresolved}"

  # Everything the agent needs goes into a file, and the prompt is a one-line
  # pointer at it. `herdr agent prompt` only reliably delivers a short single
  # line: a long multi-line brief pasted into the input box comes back
  # agent_prompted and arrives empty, which looks exactly like a launched task
  # nobody has reviewed yet. Measured at 6519 bytes, it took two attempts.
  brief_file="$BRIEF_DIR/${name}.md"
  brief_native=$(to_native "$brief_file")
  # Generated from the fields rather than written per task, so the instruction
  # not to restate the constraints cannot be dropped by an orchestrator in a
  # hurry - earlier diffs pasted prompt steps into the source verbatim,
  # numbering and all.
  if (( n_pitfalls > 0 )); then
    pitfall_block=$(jq -r '.pitfalls[] | "- " + .' <<<"$task")
  else
    pitfall_block="- None were found in the code this task touches. That is a
  statement about the traps, not a licence to skip reading what you change."
  fi
  files_block=$(jq -r '.files[] | "- " + .' <<<"$task")
  cat > "$brief_file" <<BRIEF
# Task: $name

$prompt

## Constraints

Traps the orchestrator found by reading this code before writing the task. They
are requirements to satisfy, not background:

$pitfall_block

Do not restate any of this in the source. Constraints and task steps do not
belong in comments, docstrings or test names: satisfy them and leave code that
reads as though they had never been written down. The steps above are
requirements, not a sequence to mirror in the structure of the code.

## Files this task is expected to touch

$files_block

If the work genuinely needs a file outside that list, change it and say so in
your result summary. This is the expected scope, not a lock.

## Ground rules

- Work only inside this worktree (branch $branch). Do not touch other
  repositories or the user's other checkouts.
- Commit your changes as you go, with descriptive commit messages.
- Do not leave uncommitted changes at the end: run 'git status' before
  finishing and commit or discard anything left over.

## Result file (required, last action)

When you are completely finished, write a JSON file to:

    $status_file

with exactly this shape:

    {"status": "success", "summary": "<short text>", "tests_passed": true}

status is "success" or "failure", tests_passed is true or false. Create parent
directories if needed. Write it as your very last action, once the tree is clean.
BRIEF

  # Pi's Antigravity provider handles linked-account rotation within the agent.
  echo "==> [$name] starting $kind agent${account:+ on account $account} in pane $pane_id${model:+ (model: $model${effort:+ / $effort})}"
  # One agent failing to start must not abandon the tasks after it, and it must
  # not leave an empty worktree behind either. Tear this one down and carry on.
  trace "$name" "agent.start" "kind=$kind pane=$pane_id ready_timeout=$ready_timeout_ms budget=$work_budget_ms args: $autoflag ${model_args[*]-} ${extra_args[*]-}"
  if ! herdr agent start "$name" --kind "$kind" --pane "$pane_id" --timeout "$ready_timeout_ms" \
       -- "$autoflag" "${model_args[@]}" "${extra_args[@]}" >/dev/null; then
    trace "$name" "agent.start" "failed, tearing the worktree back down"
    echo "ERROR: [$name] $kind did not start. Read the pane with: herdr agent read $name --source recent-unwrapped" >&2
    herdr worktree remove --workspace "$workspace_id" --force >/dev/null 2>&1 \
      || echo "WARN: [$name] could not remove workspace $workspace_id; clean it up by hand." >&2
    # Removing the worktree leaves the branch behind, and the branch is what
    # blocks the next attempt: `worktree create` refuses a branch that already
    # exists, so a failed launch used to need a manual `git branch -D` before
    # the task could be relaunched.
    if git -C "$repo" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null; then
      if git -C "$repo" branch -D "$branch" >/dev/null 2>&1; then
        trace "$name" "rollback" "deleted branch $branch"
      else
        echo "WARN: [$name] branch '$branch' is left over and will block a relaunch. Remove it by hand: git -C '$repo' branch -D $branch" >&2
      fi
    fi
    continue
  fi
  trace "$name" "agent.start" "started"

  # `agent start` returns once the process exists, which is earlier than the TUI
  # accepting input. Prompting in that window loses the prompt without an error:
  # herdr answers agent_prompted, the agent never sees it, and the pane sits idle
  # with an empty input box, looking exactly like a task nobody has reviewed yet.
  echo "==> [$name] waiting for $kind to accept input"
  ready=""
  waited=0
  for _ in $(seq 1 60); do
    if agent_ready "$name"; then ready=1; break; fi
    waited=$((waited + 1))
    sleep 1
  done
  if [[ -n "$ready" ]]; then
    trace "$name" "agent.ready" "interactive after ${waited}s"
  else
    trace "$name" "agent.ready" "still not interactive after 60s, sending anyway"
    echo "WARN: [$name] still not interactive after 60s. Sending anyway." >&2
  fi

  echo "==> [$name] sending prompt (not waiting, runs in background)"
  submit_prompt "$name" "Read the file $brief_native and carry out the task it describes in this worktree." \
    || echo "ERROR: [$name] prompt was not picked up; resend it by hand. The brief is at $brief_file" >&2

  # An unset base is an empty string, not null, so `// "HEAD"` would not catch it.
  jq -n --arg name "$name" --arg kind "$kind" --arg repo "$repo" --arg branch "$branch" \
        --arg base "${base:-HEAD}" --arg base_sha "$base_sha" \
        --arg pane_id "$pane_id" --arg workspace_id "$workspace_id" \
        --arg worktree_path "$worktree_path" --arg status_file "$status_file" \
        --arg model "$model" --arg effort "$effort" --arg account "$account" \
        --arg fallback_from "$fallback_from" --arg verify "$verify" --arg prompt "$prompt" \
        --arg brief_file "$brief_file" --argjson work_budget_ms "$work_budget_ms" \
        --argjson files "$(jq -c '.files' <<<"$task")" \
        --argjson pitfalls "$(jq -c '.pitfalls' <<<"$task")" \
        --argjson started_at "$(date +%s)" \
    '{name: $name, kind: $kind, repo: $repo, branch: $branch, base: $base, base_sha: $base_sha,
      model: $model, effort: $effort, account: $account, fallback_from: $fallback_from,
      pane_id: $pane_id, workspace_id: $workspace_id,
      worktree_path: $worktree_path, status_file: $status_file, brief_file: $brief_file,
      work_budget_ms: $work_budget_ms, started_at: $started_at, verify: $verify,
      files: $files, pitfalls: $pitfalls, prompt: $prompt}' \
    >> "$entries_file"
  trace "$name" "state.write" "entry recorded"
done

jq -s '.' "$entries_file" > "$STATE_FILE"
rm -f "$entries_file"
trace "-" "run.end" "$(jq 'length' "$STATE_FILE") of $n_tasks task(s) launched, state in $STATE_FILE"

echo
echo "Launched. State written to $STATE_FILE"
echo "Run id: $run_id (cleanup.sh archives this run under $RUN_DIR)"
echo "Briefs: $BRIEF_DIR"
echo "Check on them with: scripts/status.sh"
if trace_enabled; then echo "Trace of this run: $(trace_file)"; fi
