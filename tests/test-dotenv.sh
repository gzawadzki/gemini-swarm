#!/usr/bin/env bash
# The repo .env is loaded by lib.sh, and only when a variable is not already set.
# Run: bash tests/test-dotenv.sh
set -uo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/harness.sh"

ENVF="$T/sample.env"
cat > "$ENVF" <<'EOF'
# comment
HERDR_SWARM_JEV_AUTO_ACCEPT=1
HERDR_SWARM_JEV_ACCEPT_MAX=0.25
export HERDR_SWARM_JEV_TIMEOUT=15
ALREADY_SET=from-file
EOF

source_lib() {
  (
    unset HERDR_SWARM_DOTENV
    unset HERDR_SWARM_JEV_MODE HERDR_SWARM_JEV_AUTO_ACCEPT
    unset HERDR_SWARM_JEV_ACCEPT_MAX HERDR_SWARM_JEV_TIMEOUT
    export HERDR_SWARM_DOTENV_FILE="$ENVF"
    export ALREADY_SET=from-env
    # shellcheck source=../scripts/lib.sh
    source "$REPO/scripts/lib.sh"
    printf 'mode=%s accept=%s max=%s timeout=%s already=%s\n' \
      "$JEV_MODE" "$JEV_AUTO_ACCEPT" "$JEV_ACCEPT_MAX" "$JEV_TIMEOUT" "$ALREADY_SET"
  )
}

echo "== 1. an unset variable comes from the dotenv file =="
out=$(source_lib)
check "auto-accept turns on" "mode=auto_accept accept=1 max=0.25 timeout=15 already=from-env" "$out"

echo
echo "== 2. HERDR_SWARM_DOTENV=0 ignores the file =="
out=$(
  unset HERDR_SWARM_JEV_MODE HERDR_SWARM_JEV_AUTO_ACCEPT
  export HERDR_SWARM_DOTENV=0
  export HERDR_SWARM_DOTENV_FILE="$ENVF"
  source "$REPO/scripts/lib.sh"
  printf '%s' "$JEV_MODE"
)
check "stays on the auto-accept default" "auto_accept" "$out"

harness_summary
