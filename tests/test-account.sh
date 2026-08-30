#!/usr/bin/env bash
# Unit tests for the account-selection layer of scripts/lib.sh.
# Run: bash tests/test-account.sh
#
# Exercises it without touching the real credential vault: LOCALAPPDATA is redirected at a scratch dir, the usage
# tables are pre-seeded into the per-run cache, and account_switch is pointed at
# a stub .ps1 that only returns an exit code.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
export LOCALAPPDATA="$T/appdata"
mkdir -p "$LOCALAPPDATA/herdr-swarm"

pass=0; fail=0
check() { # check <label> <expected> <actual>
  if [[ "$2" == "$3" ]]; then
    printf 'ok    %-52s %s\n' "$1" "$3"; pass=$((pass+1))
  else
    printf 'FAIL  %-52s expected [%s] got [%s]\n' "$1" "$2" "$3"; fail=$((fail+1))
  fi
}

# shellcheck source=/dev/null
source "$REPO/scripts/lib.sh"

usage_table() { # <gemini-weekly> <gemini-5h> <claude-weekly> <claude-5h>
  printf 'Gemini Models\tWeekly Limit Remaining\t%s%%\t2026-09-04T00:18:35Z\n' "$1"
  printf 'Gemini Models\tFive Hour Limit Remaining\t%s%%\t2026-08-30T18:31:35Z\n' "$2"
  printf 'Claude and GPT models\tWeekly Limit Remaining\t%s%%\t2026-09-04T07:31:35Z\n' "$3"
  printf 'Claude and GPT models\tFive Hour Limit Remaining\t%s%%\t2026-08-30T20:31:35Z\n' "$4"
}
seed_usage() { usage_table "$2" "$3" "$4" "$5" > "$AGY_USAGE_CACHE_PREFIX.$1"; }
clear_usage() { rm -f "$AGY_USAGE_CACHE_PREFIX".*; }

seed_vault_list() { # <a-state> <b-state>, each "full" or "empty"
  {
    echo "live     gemini:antigravity       sha=DEADBEEF0000 size=504 user=antigravity written=2026-08-30 15:39:47"
    [[ "$1" == "full" ]] \
      && echo "vault a  herdr-swarm:agy-a        sha=AAAAAAAAAAAA size=504 user=antigravity written=2026-08-30 15:00:00" \
      || echo "vault a  herdr-swarm:agy-a        (empty)"
    [[ "$2" == "full" ]] \
      && echo "vault b  herdr-swarm:agy-b        sha=BBBBBBBBBBBB size=504 user=antigravity written=2026-08-30 15:00:00" \
      || echo "vault b  herdr-swarm:agy-b        (empty)"
  } > "$SWARM_ACCOUNT_LIST_CACHE"
}

stub_switch() { # <exit-code>
  cat > "$T/stub.ps1" <<PS
param([string]\$Mode, [string]\$Account, [switch]\$Force)
Write-Output "stub: -Mode \$Mode -Account \$Account"
exit $1
PS
  SWARM_ACCOUNT_SCRIPT="$T/stub.ps1"
  command -v cygpath >/dev/null 2>&1 && SWARM_ACCOUNT_SCRIPT=$(cygpath -w "$SWARM_ACCOUNT_SCRIPT")
}

echo "== model -> quota pool =="
check "gemini-3.1-pro-high"      "Gemini Models"          "$(agy_family_for_model gemini-3.1-pro-high)"
check "claude-opus-4-6-thinking" "Claude and GPT models"  "$(agy_family_for_model claude-opus-4-6-thinking)"
check "gpt-5.6-luna"             "Claude and GPT models"  "$(agy_family_for_model gpt-5.6-luna)"
check "no model set"             "Gemini Models"          "$(agy_family_for_model '')"

echo
echo "== lowest remaining across both windows =="
clear_usage; seed_usage a 80 22 94 82
check "gemini min(80,22)"  "22" "$(agy_family_remaining 'Gemini Models' a)"
check "claude min(94,82)"  "82" "$(agy_family_remaining 'Claude and GPT models' a)"

echo
echo "== exhausted: 0 yes / 1 no / 2 unreadable =="
clear_usage; seed_usage a 80 0 94 82
agy_exhausted gemini-3.1-pro-high a; check "five-hour 0% blocks a gemini task" "0" "$?"
agy_exhausted claude-opus-4-6-thinking a; check "the other pool is unaffected" "1" "$?"
agy_exhausted '' a; check "no model set: either pool empty counts" "0" "$?"
clear_usage; printf 'garbage\n' > "$AGY_USAGE_CACHE_PREFIX.a"
agy_exhausted gemini-3.1-pro-high a; check "unparseable table" "2" "$?"

echo
echo "== reset time: earliest window that actually reads 0% =="
clear_usage; seed_usage a 0 22 94 82
check "weekly 0%, five-hour 22%" "2026-09-04T00:18:35Z" "$(agy_family_reset 'Gemini Models' a)"
clear_usage; seed_usage a 0 0 94 82
check "both 0%: earliest wins"   "2026-08-30T18:31:35Z" "$(agy_family_reset 'Gemini Models' a)"

echo
echo "== live-account state file =="
rm -f "$LOCALAPPDATA/herdr-swarm/live-account"
account_live >/dev/null 2>&1; check "missing state file -> rc 1" "1" "$?"
printf 'b' > "$LOCALAPPDATA/herdr-swarm/live-account"
check "reads the recorded account" "b" "$(account_live)"
printf 'b\r\n' > "$LOCALAPPDATA/herdr-swarm/live-account"
check "tolerates a CRLF state file" "b" "$(account_live)"
HERDR_SWARM_NO_SWITCHING=1 account_live >/dev/null 2>&1
check "HERDR_SWARM_NO_SWITCHING=1 -> rc 1" "1" "$?"
check "other(a)" "b" "$(account_other a)"
check "other(b)" "a" "$(account_other b)"

echo
echo "== vault presence, parsed from -Mode list =="
seed_vault_list empty empty
account_vault_has b; check "vault b empty -> rc 1" "1" "$?"
seed_vault_list empty full
account_vault_has b; check "vault b populated -> rc 0" "0" "$?"
account_vault_has a; check "vault a still empty -> rc 1" "1" "$?"

echo
echo "== agy_pick_account =="
printf 'a' > "$LOCALAPPDATA/herdr-swarm/live-account"

clear_usage; seed_usage a 80 22 94 82; seed_vault_list empty full; stub_switch 0
out=$(agy_pick_account gemini-3.1-pro-high 2>/dev/null); rc=$?
check "live account has room: rc"      "0" "$rc"
check "live account has room: account" "a" "$out"

clear_usage; seed_usage a 80 0 94 82; seed_usage b 80 55 94 82
seed_vault_list empty full; stub_switch 0
out=$(agy_pick_account gemini-3.1-pro-high 2>/dev/null); rc=$?
check "live empty, other has room: rc"      "0" "$rc"
check "live empty, other has room: account" "b" "$out"

clear_usage; seed_usage a 80 0 94 82; seed_usage b 80 0 94 82
seed_vault_list empty full; stub_switch 0
out=$(agy_pick_account gemini-3.1-pro-high 2>/dev/null); rc=$?
check "both accounts empty -> rc 1" "1" "$rc"

clear_usage; seed_usage a 80 0 94 82
seed_vault_list empty empty; stub_switch 0
out=$(agy_pick_account gemini-3.1-pro-high 2>/dev/null); rc=$?
check "live empty, no second account -> rc 1" "1" "$rc"

clear_usage; seed_usage a 80 0 94 82
seed_vault_list empty full; stub_switch 3
out=$(agy_pick_account gemini-3.1-pro-high 2>/dev/null); rc=$?
check "switch refused, agents running -> rc 3" "3" "$rc"

clear_usage; seed_usage a 80 0 94 82
seed_vault_list empty full; stub_switch 5
out=$(agy_pick_account gemini-3.1-pro-high 2>/dev/null); rc=$?
check "switch failed some other way -> rc 1" "1" "$rc"

clear_usage; printf 'garbage\n' > "$AGY_USAGE_CACHE_PREFIX.a"
seed_vault_list empty full; stub_switch 0
out=$(agy_pick_account gemini-3.1-pro-high 2>/dev/null); rc=$?
check "quota unreadable: rc"      "2" "$rc"
check "quota unreadable: account" "a" "$out"

clear_usage; seed_usage a 0 0 94 82; seed_usage b 50 50 94 82
seed_vault_list empty full; stub_switch 0
out=$(agy_pick_account claude-opus-4-6-thinking 2>/dev/null); rc=$?
check "gemini empty but task is claude: rc"      "0" "$rc"
check "gemini empty but task is claude: account" "a" "$out"

echo
echo "== reset note for the stop-and-report message =="
clear_usage; seed_usage a 80 0 94 82; seed_usage b 0 0 94 82
check "both accounts reported" \
  "account A refills at 2026-08-30T18:31:35Z, account B refills at 2026-08-30T18:31:35Z" \
  "$(agy_reset_note gemini-3.1-pro-high)"
clear_usage; seed_usage a 80 22 94 82
check "nothing at 0%" "agy did not report a reset time" "$(agy_reset_note gemini-3.1-pro-high)"

echo
echo "== agy_usage refuses to answer for a non-live account =="
clear_usage
printf 'a' > "$LOCALAPPDATA/herdr-swarm/live-account"
agy_usage b >/dev/null 2>&1; check "asking about the non-live account -> rc 1" "1" "$?"

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
rm -rf "$T"
[[ "$fail" -eq 0 ]]
