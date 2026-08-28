#!/usr/bin/env bash
# Print recent output for one task's agent.
# Usage: logs.sh <task-name> [lines]
set -euo pipefail

NAME="${1:?Usage: logs.sh <task-name> [lines]}"
LINES="${2:-150}"

command -v herdr >/dev/null 2>&1 || { echo "ERROR: herdr not found on PATH." >&2; exit 1; }

herdr agent read "$NAME" --source recent-unwrapped --lines "$LINES"
