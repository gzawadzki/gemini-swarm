#!/usr/bin/env bash
# End-to-end dry run of scripts/launch.sh.
# Run: bash tests/test-launch.sh
#
# Drives it against fake `herdr`, `agy` and `pwsh` binaries, in a throwaway
# git repo. Nothing touches the real credential vault, the real herdr, or the
# user's repos.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
BIN="$T/bin"; mkdir -p "$BIN"
export LOCALAPPDATA="$T/appdata"; mkdir -p "$LOCALAPPDATA/herdr-swarm"
printf 'a' > "$LOCALAPPDATA/herdr-swarm/live-account"

pass=0; fail=0
check() { if [[ "$2" == "$3" ]]; then printf 'ok    %-46s %s\n' "$1" "$3"; pass=$((pass+1));
          else printf 'FAIL  %-46s expected [%s] got [%s]\n' "$1" "$2" "$3"; fail=$((fail+1)); fi; }
grepok() { if grep -q "$2" <<<"$3"; then printf 'ok    %s\n' "$1"; pass=$((pass+1));
           else printf 'FAIL  %s (no match for /%s/)\n' "$1" "$2"; fail=$((fail+1)); fi; }

# --- fake binaries ----------------------------------------------------------
cat > "$BIN/herdr" <<'EOF'
#!/usr/bin/env bash
echo "herdr $*" >> "$HERDR_CALL_LOG"
case "$1 ${2:-}" in
  "worktree create")
    printf '{"result":{"root_pane":{"pane_id":"pane-1"},"workspace":{"workspace_id":"ws-1","worktree":{"checkout_path":"%s"}}}}' "$FAKE_WORKTREE" ;;
  "agent start")  echo '{"result":{"type":"agent_started"}}' ;;
  "agent get")    echo '{"result":{"agent":{"agent_status":"working","interactive_ready":true,"state_change_seq":7}}}' ;;
  "agent prompt") echo '{"result":{"type":"agent_prompted"}}' ;;
  "worktree remove") echo '{"result":{"ok":true}}' ;;
  *) echo '{"result":{}}' ;;
esac
EOF

# The quota table. The real agy answers for whoever is signed in, so the fake
# one keys off the live-account file the same way.
cat > "$BIN/agy" <<'EOF'
#!/usr/bin/env bash
live=$(cat "$LOCALAPPDATA/herdr-swarm/live-account" 2>/dev/null || echo a)
if [[ "$live" == "b" ]]; then five="${FAKE_GEM_5H_B:-22}"; else five="${FAKE_GEM_5H_A:-22}"; fi
printf 'Gemini Models	Weekly Limit Remaining	%s%%	2026-09-04T00:18:35Z
' "${FAKE_GEM_WEEK:-80}"
printf 'Gemini Models	Five Hour Limit Remaining	%s%%	2026-08-30T18:31:35Z
' "$five"
printf 'Claude and GPT models	Weekly Limit Remaining	94%%	2026-09-04T07:31:35Z
'
printf 'Claude and GPT models	Five Hour Limit Remaining	82%%	2026-08-30T20:31:35Z
'
EOF

# Stands in for scripts/agy-account.ps1: -Mode list reports the vault, -Mode use
# returns the exit code the scenario is testing and records the new live account.
cat > "$BIN/pwsh" <<'EOF'
#!/usr/bin/env bash
mode=""; account=""
while [[ $# -gt 0 ]]; do
  case "$1" in -Mode) mode="$2"; shift 2 ;; -Account) account="$2"; shift 2 ;; *) shift ;; esac
done
case "$mode" in
  list)
    echo "live     gemini:antigravity       sha=DEADBEEF0000 size=504 user=antigravity written=2026-08-30 15:39:47"
    echo "vault a  herdr-swarm:agy-a        sha=AAAAAAAAAAAA size=504 user=antigravity written=2026-08-30 15:00:00"
    if [[ "${FAKE_VAULT_B:-full}" == "full" ]]; then
      echo "vault b  herdr-swarm:agy-b        sha=BBBBBBBBBBBB size=504 user=antigravity written=2026-08-30 15:00:00"
    else
      echo "vault b  herdr-swarm:agy-b        (empty)"
    fi
    ;;
  use)
    rc="${FAKE_SWITCH_RC:-0}"
    if [[ "$rc" == "0" ]]; then
      printf '%s' "$account" > "$LOCALAPPDATA/herdr-swarm/live-account"
      echo "live credential set to account '$account' (sha=BBBBBBBBBBBB)"
    else
      echo "stub refusing the swap (rc=$rc)" >&2
    fi
    exit "$rc" ;;
esac
EOF
chmod +x "$BIN"/*
export PATH="$BIN:$PATH"
export HERDR_CALL_LOG="$T/herdr-calls.log"
export HERDR_ENV=1

# --- throwaway repo ---------------------------------------------------------
SRC="$T/repo"; mkdir -p "$SRC"
git -C "$SRC" init -q -b main
git -C "$SRC" config user.email t@example.com
git -C "$SRC" config user.name Test
echo hello > "$SRC/file.txt"
git -C "$SRC" add -A && git -C "$SRC" commit -qm init
export FAKE_WORKTREE="$SRC"

new_run_dir() { LAST_RUN_DIR="$T/run.$RANDOM"; LAST_STATE_DIR="$LAST_RUN_DIR/.herdr-swarm"; mkdir -p "$LAST_RUN_DIR"; }

run_launch() { # runs launch.sh in the dir prepared by new_run_dir
  local dir="$LAST_RUN_DIR"
  cat > "$dir/tasks.json" <<JSON
{"tasks":[{"name":"t1","kind":"agy","model":"gemini-3.1-pro-high","repo":"$SRC",
  "branch":"agent/t1","prompt":"do the thing","args":[],"timeout_ms":1000}]}
JSON
  ( cd "$dir" && : > "$HERDR_CALL_LOG" && bash "$REPO/scripts/launch.sh" tasks.json 2>&1 )
}

echo "== 1. live account has quota: launches on a =="
printf 'a' > "$LOCALAPPDATA/herdr-swarm/live-account"; new_run_dir
out=$(run_launch)
grepok "starts the agent"                 "starting agy agent on account a" "$out"
grepok "sends the prompt"                 "sending prompt"                  "$out"
check  "state.json records account a" "a" "$(jq -r '.[0].account' "$LAST_STATE_DIR/state.json")"
check  "state.json records the branch" "agent/t1" "$(jq -r '.[0].branch' "$LAST_STATE_DIR/state.json")"
# cleanup.sh needs the origin repo to tell whether a task branch was merged.
# jq is a native binary, so MSYS rewrites a /tmp/... argument into its Windows
# form on the way in; compare against the same form rather than the POSIX one.
check  "state.json records the repo" "$(cygpath -m "$SRC" 2>/dev/null || echo "$SRC")" "$(jq -r '.[0].repo' "$LAST_STATE_DIR/state.json")"
check  "no dead state_file field" "null" "$(jq -r '.[0].state_file' "$LAST_STATE_DIR/state.json")"
grepok "worktree was created"             "worktree create"                 "$(cat "$HERDR_CALL_LOG")"
grepok "agent started through herdr"      "agent start t1"                  "$(cat "$HERDR_CALL_LOG")"

echo
echo "== 2. live account at 0%, other account has room: switches =="
printf 'a' > "$LOCALAPPDATA/herdr-swarm/live-account"; new_run_dir
out=$(FAKE_GEM_5H_A=0 FAKE_VAULT_B=full FAKE_SWITCH_RC=0 FAKE_GEM_5H_B=55 run_launch)
grepok "reports the switch"               "switched the live credential to account b" "$out"
grepok "starts on account b"              "starting agy agent on account b"           "$out"
check  "state.json records account b" "b" "$(jq -r '.[0].account' "$LAST_STATE_DIR/state.json")"
check  "live-account file moved to b" "b" "$(cat "$LOCALAPPDATA/herdr-swarm/live-account")"

echo
echo "== 3. switch refused because agents are running: nothing starts =="
printf 'a' > "$LOCALAPPDATA/herdr-swarm/live-account"; new_run_dir
out=$(FAKE_GEM_5H_A=0 FAKE_VAULT_B=full FAKE_SWITCH_RC=3 run_launch)
grepok "explains why it stopped"          "cannot be swapped in while agy is still running" "$out"
grepok "points at cleanup.sh"             "run scripts/cleanup.sh, then launch again"       "$out"
grepok "reports the reset time"           "refills at 2026-08-30T18:31:35Z"                 "$out"
check  "no agent was started" "" "$(grep 'agent start' "$HERDR_CALL_LOG" || true)"
check  "no worktree was created" "" "$(grep 'worktree create' "$HERDR_CALL_LOG" || true)"
check  "state.json is empty" "0" "$(jq 'length' "$LAST_STATE_DIR/state.json")"

echo
echo "== 4. no second account in the vault: nothing starts =="
printf 'a' > "$LOCALAPPDATA/herdr-swarm/live-account"; new_run_dir
out=$(FAKE_GEM_5H_A=0 FAKE_VAULT_B=empty run_launch)
grepok "reports that no account has quota" "no Antigravity account has quota left for Gemini Models" "$out"
check  "no agent was started" "" "$(grep 'agent start' "$HERDR_CALL_LOG" || true)"
check  "state.json is empty" "0" "$(jq 'length' "$LAST_STATE_DIR/state.json")"

echo
echo "== 5. switching disabled by the environment =="
printf 'a' > "$LOCALAPPDATA/herdr-swarm/live-account"; new_run_dir
out=$(HERDR_SWARM_NO_SWITCHING=1 FAKE_GEM_5H_A=0 FAKE_VAULT_B=full run_launch)
grepok "stops instead of switching"       "HERDR_SWARM_NO_SWITCHING=1 forbids switching" "$out"
check  "live account untouched" "a" "$(cat "$LOCALAPPDATA/herdr-swarm/live-account")"

echo
echo "== 6. refuses to run outside a herdr pane =="
out=$(cd "$T" && HERDR_ENV=0 bash "$REPO/scripts/launch.sh" /dev/null 2>&1); rc=$?
check "exit code" "1" "$rc"
grepok "says why" "not a herdr-managed pane" "$out"

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
rm -rf "$T"
[[ "$fail" -eq 0 ]]
