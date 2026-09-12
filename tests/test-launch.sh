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
  "agent start")
    if [[ "${FAKE_START_RC:-0}" != "0" ]]; then echo '{"error":{"code":"invalid_agent_timeout"}}'; exit "$FAKE_START_RC"; fi
    echo '{"result":{"type":"agent_started"}}' ;;
  "agent get")    echo '{"result":{"agent":{"agent_status":"working","interactive_ready":true,"state_change_seq":7}}}' ;;
  # herdr agent prompt <name> <text>, so the text is $4 after the two subcommand
  # words. Recorded verbatim: the point of this fake is to assert on what the real
  # herdr would have received, not on what launch.sh printed to stdout.
  "agent prompt") printf '%s' "$4" > "$HERDR_PROMPT_FILE"; echo '{"result":{"type":"agent_prompted"}}' ;;
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
export HERDR_PROMPT_FILE="$T/last-prompt.txt"
# Briefs must not land in the real ~/.herdr/briefs while testing.
export HERDR_SWARM_BRIEF_DIR="$T/briefs"
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
  "branch":"agent/t1","prompt":"do the thing","args":[],
  "ready_timeout_ms":1000,"work_budget_ms":900000}]}
JSON
  ( cd "$dir" && : > "$HERDR_CALL_LOG" && bash "$REPO/scripts/launch.sh" tasks.json 2>&1 )
}

echo "== 1. live account has quota: launches on a =="
printf 'a' > "$LOCALAPPDATA/herdr-swarm/live-account"; new_run_dir
out=$(run_launch)
# The installed skill is a junction to the working repo, so a run has to say which
# tree state produced it. Reported, never blocked.
grepok "reports the skill's commit"        "swarm skill: [0-9a-f]"           "$out"
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
# The prompt that reaches herdr must be a short pointer at the brief file. A long
# multi-line brief sent inline comes back agent_prompted and arrives empty, and
# the old test could not tell the difference: it only checked stdout for the words
# "sending prompt", which are printed either way.
grepok "prompt is a pointer at the brief"  "Read the file .*briefs/t1.md"    "$(cat "$HERDR_PROMPT_FILE")"
check  "prompt is a single line" "0" "$(wc -l < "$HERDR_PROMPT_FILE" | tr -d ' ')"
check  "prompt does not carry the brief" "0" "$(grep -c 'Result file' "$HERDR_PROMPT_FILE")"
grepok "brief file holds the task text"    "do the thing"                    "$(cat "$T/briefs/t1.md")"
grepok "brief file holds the result contract" "Result file (required, last action)" "$(cat "$T/briefs/t1.md")"
grepok "brief names the result path"       "t1.result.json"                  "$(cat "$T/briefs/t1.md")"
grepok "herdr got the ready timeout"       "\-\-timeout 1000"               "$(cat "$HERDR_CALL_LOG")"
check  "state records the work budget" "900000" "$(jq -r '.[0].work_budget_ms' "$LAST_STATE_DIR/state.json")"
check  "state records the brief file" "true" "$(jq -r '.[0].brief_file | endswith("t1.md")' "$LAST_STATE_DIR/state.json")"
check  "state records a launch time" "true" "$(jq -r '.[0].started_at > 0' "$LAST_STATE_DIR/state.json")"
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
echo "== 4. no second account, fallback off: nothing starts =="
printf 'a' > "$LOCALAPPDATA/herdr-swarm/live-account"; new_run_dir
out=$(HERDR_SWARM_NO_FALLBACK=1 FAKE_GEM_5H_A=0 FAKE_VAULT_B=empty run_launch)
grepok "reports that no account has quota" "no Antigravity account has quota left for Gemini Models" "$out"
grepok "says it is not launching"          "Not launching"                                          "$out"
check  "no agent was started" "" "$(grep 'agent start' "$HERDR_CALL_LOG" || true)"
check  "state.json is empty" "0" "$(jq 'length' "$LAST_STATE_DIR/state.json")"

echo
echo "== 5. switching disabled, fallback off: nothing starts =="
printf 'a' > "$LOCALAPPDATA/herdr-swarm/live-account"; new_run_dir
out=$(HERDR_SWARM_NO_FALLBACK=1 HERDR_SWARM_NO_SWITCHING=1 FAKE_GEM_5H_A=0 FAKE_VAULT_B=full run_launch)
grepok "stops instead of switching"       "HERDR_SWARM_NO_SWITCHING=1 forbids switching" "$out"
check  "live account untouched" "a" "$(cat "$LOCALAPPDATA/herdr-swarm/live-account")"
check  "no agent was started" "" "$(grep 'agent start' "$HERDR_CALL_LOG" || true)"

echo
echo "== 5b. both accounts empty: runs on codex =="
printf 'a' > "$LOCALAPPDATA/herdr-swarm/live-account"; new_run_dir
out=$(FAKE_GEM_5H_A=0 FAKE_GEM_5H_B=0 FAKE_VAULT_B=full FAKE_SWITCH_RC=0 run_launch)
grepok "announces the fallback"           "Running on codex"                    "$out"
grepok "starts codex, no account"         "starting codex agent in pane"        "$out"
grepok "codex started through herdr"      "agent start t1 --kind codex"         "$(cat "$HERDR_CALL_LOG")"
grepok "codex plugins are switched off"   "\-\-disable plugins"                 "$(cat "$HERDR_CALL_LOG")"
check  "state.json records the fallback" "agy:gemini-3.1-pro-high" "$(jq -r '.[0].fallback_from' "$LAST_STATE_DIR/state.json")"
check  "state.json kind is codex" "codex" "$(jq -r '.[0].kind' "$LAST_STATE_DIR/state.json")"
check  "state.json account is empty" "" "$(jq -r '.[0].account' "$LAST_STATE_DIR/state.json")"

echo
echo "== 5c. switching disabled: runs on codex without touching the account =="
printf 'a' > "$LOCALAPPDATA/herdr-swarm/live-account"; new_run_dir
out=$(HERDR_SWARM_NO_SWITCHING=1 FAKE_GEM_5H_A=0 FAKE_VAULT_B=full run_launch)
grepok "announces the fallback"           "Running on codex"                    "$out"
check  "live account untouched" "a" "$(cat "$LOCALAPPDATA/herdr-swarm/live-account")"

echo
echo "== 5d. a work-budget-sized ready timeout is clamped, not sent =="
printf 'a' > "$LOCALAPPDATA/herdr-swarm/live-account"; new_run_dir
cat > "$LAST_RUN_DIR/tasks.json" <<JSON
{"tasks":[{"name":"t1","kind":"agy","model":"gemini-3.8-flash-high","repo":"$SRC",
  "branch":"agent/t1","prompt":"do the thing","args":[],"timeout_ms":1800000}]}
JSON
out=$( cd "$LAST_RUN_DIR" && : > "$HERDR_CALL_LOG" && bash "$REPO/scripts/launch.sh" tasks.json 2>&1 )
# 1800000 in this field is what herdr answers invalid_agent_timeout to, and it is
# what every example in tasks.example.json used to carry.
grepok "warns about the old field name"   "old name for 'ready_timeout_ms'" "$out"
grepok "says it clamped"                  "clamping"                        "$out"
grepok "herdr got the ceiling, not 1800000" "\-\-timeout 300000"           "$(cat "$HERDR_CALL_LOG")"
check  "nothing oversized reached herdr" "" "$(grep -o '\-\-timeout 1800000' "$HERDR_CALL_LOG" || true)"
check  "the budget falls back to the default" "900000" "$(jq -r '.[0].work_budget_ms' "$LAST_STATE_DIR/state.json")"

echo
echo "== 5e. a failed agent start leaves no branch behind =="
printf 'a' > "$LOCALAPPDATA/herdr-swarm/live-account"; new_run_dir
git -C "$SRC" branch -f agent/t1 main
out=$(FAKE_START_RC=1 run_launch)
grepok "reports the failure"              "agy did not start"               "$out"
grepok "removed the worktree"             "worktree remove"                 "$(cat "$HERDR_CALL_LOG")"
# The branch, not the worktree, is what blocks the retry: `worktree create`
# refuses a branch that already exists.
check  "branch was deleted" "" "$(git -C "$SRC" rev-parse --verify --quiet refs/heads/agent/t1 || true)"
check  "state.json is empty" "0" "$(jq 'length' "$LAST_STATE_DIR/state.json")"

echo
echo "== 6. refuses to run outside a herdr pane =="
out=$(cd "$T" && HERDR_ENV=0 bash "$REPO/scripts/launch.sh" /dev/null 2>&1); rc=$?
check "exit code" "1" "$rc"
grepok "says why" "not a herdr-managed pane" "$out"

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
rm -rf "$T"
[[ "$fail" -eq 0 ]]
