#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
pi_bin=$(command -v pi)
if command -v cygpath >/dev/null 2>&1; then
  pi_bin=$(cygpath -m "$pi_bin")
  root=$(cygpath -m "$root")
fi
HERDR_SWARM_PI_BIN="$pi_bin" node --test "$root/tests/test-quota.mjs"
