#!/usr/bin/env bash
# Send one fix back to the agent that wrote the diff, and record the bounce.
# Usage: bounce.sh <task-name> <message>
#
# Raw `herdr agent prompt` does not count. This script does, so a later
# run-outcome report can see the rework. Two bounces per task, then stop.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TRACE_SRC="bounce"

NAME="${1:?Usage: bounce.sh <task-name> <message>}"
shift
text="$*"
[[ -n "$text" ]] || { echo "ERROR: bounce message is empty." >&2; exit 1; }

STATE_DIR="${HERDR_SWARM_STATE_DIR:-.herdr-swarm}"
STATE_FILE="$STATE_DIR/state.json"

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required." >&2; exit 1; }
command -v herdr >/dev/null 2>&1 || { echo "ERROR: herdr not found on PATH." >&2; exit 1; }
[[ -f "$STATE_FILE" ]] || { echo "ERROR: $STATE_FILE not found. Run launch.sh first." >&2; exit 1; }

entry=$(jq -c --arg name "$NAME" '.[] | select(.name == $name)' "$STATE_FILE")
[[ -n "$entry" ]] || { echo "ERROR: no task named '$NAME' in $STATE_FILE." >&2; exit 1; }

prior=$(rework_count "$NAME")
if (( prior >= 2 )); then
  echo "ERROR: [$NAME] already bounced $prior times. Cap is 2." >&2
  echo "Reroute the remaining work, or report the blocker. Do not send a third fix." >&2
  exit 2
fi

submit_prompt "$NAME" "$text"
record_rework "$NAME" "${#text} bytes"
echo "bounced $NAME (round $((prior + 1)) of 2)"
