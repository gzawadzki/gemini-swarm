#!/usr/bin/env bash
# Dry run of scripts/cleanup.sh against a fake `herdr` and a throwaway git repo
# with real worktrees. Nothing touches the real herdr or the user's repos.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
BIN="$T/bin"; mkdir -p "$BIN"
export FAKE_AGENTS="$T/agents"; mkdir -p "$FAKE_AGENTS"
export HERDR_CALL_LOG="$T/herdr-calls.log"

pass=0; fail=0
check() { if [[ "$2" == "$3" ]]; then printf 'ok    %-46s %s\n' "$1" "$3"; pass=$((pass+1));
          else printf 'FAIL  %-46s expected [%s] got [%s]\n' "$1" "$2" "$3"; fail=$((fail+1)); fi; }
grepok() { if grep -q "$2" <<<"$3"; then printf 'ok    %s\n' "$1"; pass=$((pass+1));
           else printf 'FAIL  %s (no match for /%s/)\n' "$1" "$2"; fail=$((fail+1)); fi; }
nogrep() { if grep -q "$2" <<<"$3"; then printf 'FAIL  %s (unexpected /%s/)\n' "$1" "$2"; fail=$((fail+1));
           else printf 'ok    %s\n' "$1"; pass=$((pass+1)); fi; }

# --- fake herdr -------------------------------------------------------------
# An agent's state is a file; send-keys "removes" it, which is what herdr
# reports once the TUI has exited. The key spelling is checked on purpose: the
# real herdr rejects "ctrl-c", and a single ctrl+c usually does not exit agy.
cat > "$BIN/herdr" <<'EOF'
#!/usr/bin/env bash
echo "herdr $*" >> "$HERDR_CALL_LOG"
case "$1 ${2:-}" in
  "agent get")
    name="$3"
    if [[ -f "$FAKE_AGENTS/$name.gone" ]]; then echo '{"result":{}}'; exit 0; fi
    printf '{"result":{"agent":{"agent_status":"%s"}}}' "$(cat "$FAKE_AGENTS/$name.state" 2>/dev/null || echo done)" ;;
  "agent send-keys")
    name="$3"; shift 3
    if [[ "${1:-}" == "ctrl+c" && "${2:-}" == "ctrl+c" ]]; then
      touch "$FAKE_AGENTS/$name.gone"; echo '{"result":{}}'
    else
      echo '{"error":{"code":"invalid_key","message":"unsupported key ${1:-}"}}'; exit 1
    fi ;;
  "worktree remove")
    if [[ "${FAKE_REMOVE_FAILS:-0}" == "1" ]]; then echo '{"error":{}}'; exit 1; fi
    echo '{"result":{"ok":true}}' ;;
  *) echo '{"result":{}}' ;;
esac
EOF
chmod +x "$BIN"/*
export PATH="$BIN:$PATH"

# --- throwaway repo with two worktrees --------------------------------------
SRC="$T/repo"; mkdir -p "$SRC"
git -C "$SRC" init -q -b main
git -C "$SRC" config user.email t@example.com
git -C "$SRC" config user.name Test
echo hello > "$SRC/file.txt"
git -C "$SRC" add -A && git -C "$SRC" commit -qm init

# 'merged' is already in main, 'open' is not.
git -C "$SRC" branch agent/merged
git -C "$SRC" worktree add -q "$T/wt-merged" agent/merged
git -C "$SRC" worktree add -q -b agent/open "$T/wt-open" main
echo work > "$T/wt-open/new.txt"
git -C "$T/wt-open" add -A && git -C "$T/wt-open" commit -qm work

RUN="$T/run"; mkdir -p "$RUN/.herdr-swarm"
STATE="$RUN/.herdr-swarm/state.json"

entry() { # name state branch base worktree result?
  printf '{"name":"%s","kind":"agy","repo":"%s","branch":"%s","base":"%s","account":"a",
           "workspace_id":"ws-%s","worktree_path":"%s","status_file":"%s"}' \
    "$1" "$SRC" "$3" "$4" "$1" "$5" "$RUN/.herdr-swarm/$1.result.json"
}

reset_world() {
  rm -f "$FAKE_AGENTS"/* "$HERDR_CALL_LOG" "$RUN/.herdr-swarm"/*.result.json
  : > "$HERDR_CALL_LOG"
  echo done    > "$FAKE_AGENTS/finished.state"
  echo working > "$FAKE_AGENTS/busy.state"
  echo idle    > "$FAKE_AGENTS/silent.state"
  echo '{"status":"success","summary":"s","tests_passed":true}' > "$RUN/.herdr-swarm/finished.result.json"
  { echo '['
    entry finished done  agent/merged main "$T/wt-merged"; echo ','
    entry busy     work  agent/open   main "$T/wt-open"; echo ','
    entry silent   idle  agent/open   main "$T/wt-open"
    echo ']'
  } > "$STATE"
}

run_cleanup() { ( cd "$RUN" && bash "$REPO/scripts/cleanup.sh" "$@" 2>&1 ); }

echo "== 1. default: closes the finished agent, leaves the others =="
reset_world
out=$(run_cleanup); rc=$?
check  "exit code" "0" "$rc"
grepok "closes the finished agent"     "closed finished"     "$out"
grepok "keeps the working agent"       "keep   busy"         "$out"
grepok "keeps the idle-without-result" "keep   silent"       "$out"
grepok "two ctrl+c in one send-keys"   "send-keys finished ctrl+c ctrl+c" "$(cat "$HERDR_CALL_LOG")"
nogrep "no worktree touched"           "worktree remove"     "$(cat "$HERDR_CALL_LOG")"
grepok "points at the account check"   "agy-account.ps1 -Mode list" "$out"

echo
echo "== 2. --all closes working agents too =="
reset_world
out=$(run_cleanup --all)
grepok "closes the working agent" "closed busy"    "$out"
grepok "closes the idle agent"    "closed silent"  "$out"
check  "nothing left running" "" "$(grep 'keep ' <<<"$out" || true)"

echo
echo "== 3. --worktrees removes a merged, clean worktree =="
reset_world
out=$(run_cleanup --worktrees)
grepok "removes the workspace" "removed workspace ws-finished" "$(cat <<<"$out")"
grepok "asked herdr to remove" "worktree remove --workspace ws-finished" "$(cat "$HERDR_CALL_LOG")"

echo
echo "== 4. --worktrees keeps an unmerged branch =="
reset_world
out=$(run_cleanup --all --worktrees)
grepok "keeps the unmerged branch" "branch 'agent/open' is not merged into 'main'" "$out"
grepok "suggests reviewing it"     "scripts/review.sh busy"                        "$out"
check  "only the merged one removed" "1" "$(grep -c 'worktree remove' "$HERDR_CALL_LOG")"

echo
echo "== 5. --worktrees keeps a dirty worktree =="
reset_world
echo scratch > "$T/wt-merged/dirty.txt"
out=$(run_cleanup --worktrees)
grepok "says the worktree is dirty" "worktree is dirty" "$out"
check  "nothing removed" "0" "$(grep -c 'worktree remove' "$HERDR_CALL_LOG")"
rm -f "$T/wt-merged/dirty.txt"

echo
echo "== 6. --force removes it anyway =="
reset_world
echo scratch > "$T/wt-merged/dirty.txt"
out=$(run_cleanup --all --worktrees --force)
check "all three removed" "3" "$(grep -c 'worktree remove' "$HERDR_CALL_LOG")"
rm -f "$T/wt-merged/dirty.txt"

echo
echo "== 7. --dry-run changes nothing =="
reset_world
out=$(run_cleanup --all --worktrees --dry-run)
grepok "says what it would do" "would close finished" "$out"
check  "no keys sent" "" "$(grep 'send-keys' "$HERDR_CALL_LOG" || true)"
check  "no worktree removed" "" "$(grep 'worktree remove' "$HERDR_CALL_LOG" || true)"

echo
echo "== 8. an agent herdr no longer knows is not an error =="
reset_world
touch "$FAKE_AGENTS/finished.gone"
out=$(run_cleanup); rc=$?
check  "exit code" "0" "$rc"
grepok "reports it as gone" "gone   finished" "$out"
check  "no keys sent" "" "$(grep 'send-keys' "$HERDR_CALL_LOG" || true)"

echo
echo "== 9. a pane that will not close is reported and exits non-zero =="
reset_world
cat > "$BIN/herdr" <<'EOF'
#!/usr/bin/env bash
echo "herdr $*" >> "$HERDR_CALL_LOG"
case "$1 ${2:-}" in
  "agent get") printf '{"result":{"agent":{"agent_status":"done"}}}' ;;
  *) echo '{"result":{}}' ;;
esac
EOF
out=$(run_cleanup --worktrees); rc=$?
check  "exit code" "1" "$rc"
grepok "names the stuck agent" "FAILED finished" "$out"
nogrep "its worktree is left alone" "worktree remove" "$(cat "$HERDR_CALL_LOG")"

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
git -C "$SRC" worktree remove --force "$T/wt-merged" >/dev/null 2>&1
git -C "$SRC" worktree remove --force "$T/wt-open" >/dev/null 2>&1
rm -rf "$T"
[[ "$fail" -eq 0 ]]
