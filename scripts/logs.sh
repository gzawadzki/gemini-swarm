#!/usr/bin/env bash
# Print recent output for one task's agent.
# Usage: logs.sh [--trace] <task-name> [lines]
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TRACE_SRC="logs"
strip_trace_flag "$@"; set -- ${ARGV[@]+"${ARGV[@]}"}

NAME="${1:?Usage: logs.sh [--trace] <task-name> [lines]}"
LINES="${2:-150}"

command -v herdr >/dev/null 2>&1 || { echo "ERROR: herdr not found on PATH." >&2; exit 1; }

trace_run "$NAME" "herdr.exec" -- herdr agent read "$NAME" --source recent-unwrapped --lines "$LINES"
