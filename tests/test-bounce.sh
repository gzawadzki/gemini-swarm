#!/usr/bin/env bash
# bounce.sh sends the fix and records prompt.rework even when tracing is off.
# Run: bash tests/test-bounce.sh
set -uo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/harness.sh"
harness_fake herdr

STATE="$T/state"
mkdir -p "$STATE"
export HERDR_SWARM_STATE_DIR="$STATE"
export HERDR_SWARM_TRACE=0
printf '[{"name":"t1","kind":"pi"}]\n' > "$STATE/state.json"
: > "$HERDR_CALL_LOG"

bounce() { bash "$REPO/scripts/bounce.sh" "$@"; }

echo "== 1. a bounce is recorded without --trace =="
out=$(bounce t1 "fix the assertion"); rc=$?
check "exit code" "0" "$rc"
check "prompt text reached herdr" "fix the assertion" "$(cat "$HERDR_PROMPT_FILE")"
check "rework count" "1" "$(grep -c 'prompt.rework' "$STATE/trace.log")"
grep -q 'prompt.rework' "$STATE/trace.log"
check "detail is a length, not the fix" "0" "$(grep -c 'fix the assertion' "$STATE/trace.log")"

echo
echo "== 2. the second bounce is allowed, the third is not sent =="
out=$(bounce t1 "fix the other assertion"); rc=$?
check "second exit" "0" "$rc"
check "two rework events" "2" "$(grep -c 'prompt.rework' "$STATE/trace.log")"
: > "$HERDR_CALL_LOG"
out=$(bounce t1 "third fix" 2>&1); rc=$?
check "third exit" "2" "$rc"
check "third was not sent" "" "$(cat "$HERDR_CALL_LOG")"
grepok "names the cap" "Cap is 2" "$out"

echo
echo "== 3. an unknown task is refused =="
out=$(bounce missing "nope" 2>&1); rc=$?
check "missing task exit" "1" "$rc"
grepok "names the missing task" "no task named" "$out"

harness_summary
