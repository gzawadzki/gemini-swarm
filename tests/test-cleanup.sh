#!/usr/bin/env bash
# Dry run of scripts/cleanup.sh against a fake `herdr` and a throwaway git repo
# with real worktrees. Nothing touches the real herdr or the user's repos.
set -uo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/harness.sh"
harness_fake herdr
# An agent this suite has not seeded is one that already finished.
export FAKE_AGENT_STATUS=done

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

# Each scenario is its own run, so the archive one wrote cannot be the archive
# the next one is asserting about. The id is what launch.sh would have stamped.
RUN_SEQ=0
reset_world() {
  rm -f "$FAKE_AGENTS"/* "$HERDR_CALL_LOG" "$RUN/.herdr-swarm"/*.result.json
  : > "$HERDR_CALL_LOG"
  RUN_SEQ=$((RUN_SEQ + 1))
  jq -n --arg id "run-$RUN_SEQ" --arg repo "$SRC" \
    '{run_id: $id, started_at: 1757000000, tasks_file: "tasks.json",
      skill_commit: "abc1234", skill_dirty: 2, skill_root: "/skill",
      config: {tasks: [{name: "finished", kind: "agy", repo: $repo,
                        prompt: "do the thing", files: ["file.txt"], pitfalls: []}]}}' \
    > "$RUN/.herdr-swarm/run.json"
  echo "2026-09-13T00:00:00Z launch  -  run.start  1 task(s)" > "$RUN/.herdr-swarm/trace.log"
  echo '{"status":"pass","cmd":"pytest -q","soundness":"sound"}' > "$RUN/.herdr-swarm/finished.verify.json"
  echo '{"verdict":"pass","confidence":"high","issues":[],"summary":"fine"}' > "$RUN/.herdr-swarm/finished.critique.json"
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
echo "== 10. the run is archived before anything is closed =="
reset_world
out=$(run_cleanup --all --worktrees)
ARCH="$HERDR_SWARM_RUN_DIR/run-$RUN_SEQ"
grepok "prints where the archive went" "archive: .*run-$RUN_SEQ" "$out"
check  "archive directory exists" "yes" "$([[ -d "$ARCH" ]] && echo yes || echo no)"
# How the task was defined. cleanup used to take the config with it, and a
# post-mortem was left working from memory.
check  "keeps the config as launched" "do the thing" "$(jq -r '.tasks[0].prompt' "$ARCH/tasks.json")"
check  "keeps the state file" "3" "$(jq 'length' "$ARCH/state.json")"
# An odd run has to be attributable to the version of the skill that produced it.
check  "records the skill commit" "abc1234" "$(jq -r '.skill_commit' "$ARCH/run.json")"
check  "records that the tree was dirty" "2" "$(jq -r '.skill_dirty' "$ARCH/run.json")"
grepok "keeps the trace" "run.start" "$(cat "$ARCH/trace.log")"
grepok "keeps a status snapshot" "^TASK" "$(cat "$ARCH/status.txt")"
check  "keeps the verify verdict" "pass" "$(jq -r '.status' "$ARCH/finished.verify.json")"
check  "keeps the critique verdict" "pass" "$(jq -r '.verdict' "$ARCH/finished.critique.json")"
# The diff is the thing removing a worktree destroys, so it has to be taken while
# the worktree is still there.
grepok "keeps the diff of an unmerged branch" "new.txt" "$(cat "$ARCH/busy.diff")"

echo
echo "== 11. a cleanup that fails partway still leaves the record =="
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
ARCH="$HERDR_SWARM_RUN_DIR/run-$RUN_SEQ"
check  "cleanup still reports the failure" "1" "$rc"
grepok "the pane is the thing that failed" "FAILED finished" "$out"
check  "the archive survived it" "yes" "$([[ -f "$ARCH/tasks.json" ]] && echo yes || echo no)"
harness_fake herdr

echo
echo "== 12. a second cleanup does not overwrite the first archive =="
reset_world
run_cleanup --all --worktrees >/dev/null
ARCH="$HERDR_SWARM_RUN_DIR/run-$RUN_SEQ"
before=$(cat "$ARCH/busy.diff")
# What the second pass would see: with the worktree gone its diff comes out
# empty, and overwriting a full record with an empty one is the loss this guards.
mv "$T/wt-open" "$T/wt-open.moved"
out=$(run_cleanup --all --worktrees)
mv "$T/wt-open.moved" "$T/wt-open"
grepok "says it kept the first one" "already written" "$out"
check  "the first diff is untouched" "$before" "$(cat "$ARCH/busy.diff")"

echo
echo "== 13. --dry-run writes no archive =="
reset_world
out=$(run_cleanup --all --worktrees --dry-run)
grepok "says where it would have gone" "would archive this run to .*run-$RUN_SEQ" "$out"
check  "nothing on disk" "no" "$([[ -d "$HERDR_SWARM_RUN_DIR/run-$RUN_SEQ" ]] && echo yes || echo no)"

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
git -C "$SRC" worktree remove --force "$T/wt-merged" >/dev/null 2>&1
git -C "$SRC" worktree remove --force "$T/wt-open" >/dev/null 2>&1
rm -rf "$T"
[[ "$fail" -eq 0 ]]
