#!/usr/bin/env bash
# Poll until tasks are resolved, failed, or timed out.
# Usage: wait.sh [--timeout SECONDS] [state.json]
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TRACE_SRC="wait"
strip_trace_flag "$@"; set -- ${ARGV[@]+"${ARGV[@]}"}

TIMEOUT=900
STATE_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --timeout)
      [[ $# -ge 2 ]] || { echo "ERROR: --timeout requires an argument." >&2; exit 1; }
      TIMEOUT="$2"
      shift 2
      ;;
    --timeout=*)
      TIMEOUT="${1#*=}"
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "ERROR: unknown option: $1" >&2
      exit 1
      ;;
    *)
      if [[ -z "$STATE_FILE" ]]; then
        STATE_FILE="$1"
      else
        echo "ERROR: unexpected argument: $1" >&2
        exit 1
      fi
      shift
      ;;
  esac
done

if [[ ! "$TIMEOUT" =~ ^[0-9]+$ ]]; then
  echo "ERROR: --timeout must be a non-negative integer." >&2
  exit 1
fi

if [[ -z "$STATE_FILE" ]]; then
  STATE_DIR="${HERDR_SWARM_STATE_DIR:-.herdr-swarm}"
  STATE_FILE="$STATE_DIR/state.json"
fi

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required." >&2; exit 1; }

if [[ ! -f "$STATE_FILE" ]]; then
  echo "ERROR: state file '$STATE_FILE' not found." >&2
  exit 1
fi

if ! jq -e 'type == "array" and length > 0' "$STATE_FILE" >/dev/null 2>&1; then
  echo "ERROR: state file '$STATE_FILE' is not a non-empty JSON array." >&2
  exit 1
fi

POLL_INTERVAL="${HERDR_SWARM_WAIT_INTERVAL:-2}"
start_time=$(date +%s)

while true; do
  [[ -f "$STATE_FILE" ]] || { echo "ERROR: state file '$STATE_FILE' not found." >&2; exit 1; }

  n=$(jq 'length' "$STATE_FILE" 2>/dev/null || echo 0)
  if (( n == 0 )); then
    echo "ERROR: state file '$STATE_FILE' is empty or invalid." >&2
    exit 1
  fi

  ready_count=0

  for i in $(seq 0 $((n - 1))); do
    entry=$(jq -c ".[$i]" "$STATE_FILE")
    name=$(jq -r '.name // empty' <<<"$entry")
    if [[ -z "$name" ]]; then
      echo "ERROR: task at index $i missing name in state file." >&2
      exit 1
    fi
    status_file=$(jq -r '.status_file // empty' <<<"$entry")
    workspace_id=$(jq -r '.workspace_id // empty' <<<"$entry")
    raw_worktree=$(jq -r '.worktree_path // empty' <<<"$entry")
    worktree_path=$(resolve_worktree "$raw_worktree" "$workspace_id" || true)

    herdr_state=$(task_state "$name" || echo "unreachable")

    if [[ "$herdr_state" == "blocked" ]]; then
      trace "$name" "wait.blocked" "agent is blocked"
      echo "ERROR: [$name] agent is blocked." >&2
      exit 4
    fi

    has_result_file=0
    result_status=""
    if [[ -n "$status_file" && -f "$status_file" ]]; then
      has_result_file=1
      if ! jq -e . "$status_file" >/dev/null 2>&1; then
        trace "$name" "wait.unparseable" "result file invalid JSON: $status_file"
        echo "ERROR: [$name] result file is unparseable." >&2
        exit 2
      fi
      result_status=$(jq -r '.status // empty' "$status_file" 2>/dev/null || echo "")
      if [[ "$result_status" != "success" ]]; then
        trace "$name" "wait.failure" "result status is '$result_status'"
        echo "ERROR: [$name] result status is '$result_status'." >&2
        exit 2
      fi
    fi

    if [[ "$herdr_state" == "unreachable" && "$result_status" != "success" ]]; then
      trace "$name" "wait.unreachable" "unreachable without success result"
      echo "ERROR: [$name] agent unreachable without a success result." >&2
      exit 2
    fi

    is_clean=0
    if [[ -n "$worktree_path" && -d "$worktree_path" ]]; then
      git_out=$(git -C "$worktree_path" status --porcelain 2>/dev/null || echo "__GIT_ERROR__")
      if [[ -z "$git_out" ]]; then
        is_clean=1
      fi
    fi

    trace "$name" "wait.poll" "herdr=$herdr_state result=${result_status:-none} clean=$is_clean"

    if [[ "$result_status" == "success" && $is_clean -eq 1 ]]; then
      if [[ "$herdr_state" == "idle" || "$herdr_state" == "done" || "$herdr_state" == "unreachable" ]]; then
        ready_count=$((ready_count + 1))
      fi
    fi
  done

  if (( ready_count == n )); then
    trace "-" "wait.ready" "all $n tasks review-ready"
    exit 0
  fi

  elapsed=$(( $(date +%s) - start_time ))
  if (( elapsed >= TIMEOUT )); then
    trace "-" "wait.timeout" "elapsed=${elapsed}s timeout=${TIMEOUT}s"
    echo "ERROR: timed out waiting for tasks after ${TIMEOUT}s." >&2
    exit 3
  fi

  sleep "$POLL_INTERVAL"
done
