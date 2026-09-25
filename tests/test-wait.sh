#!/usr/bin/env bash
# Dry run of scripts/wait.sh against fake herdr and throwaway worktrees.
# Run: bash tests/test-wait.sh
set -uo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/harness.sh"
harness_fake herdr

WT="$T/worktree"; mkdir -p "$WT"
git -C "$WT" init -q -b main
git -C "$WT" config core.autocrlf false
git -C "$WT" config user.email t@example.com
git -C "$WT" config user.name Test
printf 'base\n' > "$WT/file.txt"
git -C "$WT" add -A && git -C "$WT" commit -qm init
BASE_SHA=$(git -C "$WT" rev-parse HEAD)

WT2="$T/worktree2"; mkdir -p "$WT2"
git -C "$WT2" init -q -b main
git -C "$WT2" config core.autocrlf false
git -C "$WT2" config user.email t@example.com
git -C "$WT2" config user.name Test
printf 'base2\n' > "$WT2/file2.txt"
git -C "$WT2" add -A && git -C "$WT2" commit -qm init

RUN="$T/run"; mkdir -p "$RUN"
export HERDR_SWARM_STATE_DIR="$RUN/.herdr-swarm"; mkdir -p "$HERDR_SWARM_STATE_DIR"

reset_worktree() {
  git -C "$WT" reset --hard -q "$BASE_SHA"
  git -C "$WT" clean -qfd
}

clean_state() {
  rm -f "$HERDR_SWARM_STATE_DIR"/* "$FAKE_AGENTS"/*
}

write_single_state() {
  local name="${1:-t1}"
  jq -n --arg name "$name" --arg wt "$WT" --arg sf "$HERDR_SWARM_STATE_DIR/$name.result.json" \
    '[{name:$name, kind:"pi", branch:"main", worktree_path:$wt, status_file:$sf}]' \
    > "$HERDR_SWARM_STATE_DIR/state.json"
}

run_wait() {
  ( cd "$RUN" && HERDR_SWARM_WAIT_INTERVAL=0 bash "$REPO/scripts/wait.sh" "$@" 2>&1 )
}

echo "== 1. ready task with idle agent exits 0 =="
clean_state; reset_worktree
write_single_state
printf 'idle' > "$FAKE_AGENTS/t1.state"
printf '{"status":"success","summary":"done","tests_passed":true}' > "$HERDR_SWARM_STATE_DIR/t1.result.json"
out=$(run_wait); rc=$?
check "exit code is 0" "0" "$rc"

echo
echo "== 2. ready task with done agent exits 0 =="
clean_state; reset_worktree
write_single_state
printf 'done' > "$FAKE_AGENTS/t1.state"
printf '{"status":"success","summary":"done","tests_passed":true}' > "$HERDR_SWARM_STATE_DIR/t1.result.json"
out=$(run_wait); rc=$?
check "exit code is 0" "0" "$rc"

echo
echo "== 3. unreachable agent with success result and clean worktree exits 0 =="
clean_state; reset_worktree
write_single_state
touch "$FAKE_AGENTS/t1.gone"
printf '{"status":"success","summary":"done","tests_passed":true}' > "$HERDR_SWARM_STATE_DIR/t1.result.json"
out=$(run_wait); rc=$?
check "exit code is 0" "0" "$rc"

echo
echo "== 4. multiple ready tasks exit 0 =="
clean_state; reset_worktree
jq -n --arg wt1 "$WT" --arg sf1 "$HERDR_SWARM_STATE_DIR/t1.result.json" \
      --arg wt2 "$WT2" --arg sf2 "$HERDR_SWARM_STATE_DIR/t2.result.json" \
  '[{name:"t1", kind:"pi", branch:"main", worktree_path:$wt1, status_file:$sf1},
    {name:"t2", kind:"pi", branch:"main", worktree_path:$wt2, status_file:$sf2}]' \
  > "$HERDR_SWARM_STATE_DIR/state.json"
printf 'idle' > "$FAKE_AGENTS/t1.state"
printf 'done' > "$FAKE_AGENTS/t2.state"
printf '{"status":"success","summary":"done","tests_passed":true}' > "$HERDR_SWARM_STATE_DIR/t1.result.json"
printf '{"status":"success","summary":"done","tests_passed":true}' > "$HERDR_SWARM_STATE_DIR/t2.result.json"
out=$(run_wait); rc=$?
check "exit code is 0" "0" "$rc"

echo
echo "== 5. already-ready task with timeout 0 exits 0 =="
clean_state; reset_worktree
write_single_state
printf 'idle' > "$FAKE_AGENTS/t1.state"
printf '{"status":"success","summary":"done","tests_passed":true}' > "$HERDR_SWARM_STATE_DIR/t1.result.json"
out=$(run_wait --timeout 0); rc=$?
check "exit code is 0 with timeout 0" "0" "$rc"

echo
echo "== 6. failure result exits 2 =="
clean_state; reset_worktree
write_single_state
printf 'idle' > "$FAKE_AGENTS/t1.state"
printf '{"status":"failure","summary":"failed","tests_passed":false}' > "$HERDR_SWARM_STATE_DIR/t1.result.json"
out=$(run_wait); rc=$?
check "exit code is 2" "2" "$rc"

echo
echo "== 7. unparseable result file exits 2 =="
clean_state; reset_worktree
write_single_state
printf 'idle' > "$FAKE_AGENTS/t1.state"
printf '{not valid json' > "$HERDR_SWARM_STATE_DIR/t1.result.json"
out=$(run_wait); rc=$?
check "exit code is 2" "2" "$rc"

echo
echo "== 8. unreachable agent without result file exits 2 =="
clean_state; reset_worktree
write_single_state
touch "$FAKE_AGENTS/t1.gone"
out=$(run_wait); rc=$?
check "exit code is 2" "2" "$rc"

echo
echo "== 9. unreachable agent with failure result exits 2 =="
clean_state; reset_worktree
write_single_state
touch "$FAKE_AGENTS/t1.gone"
printf '{"status":"failure","summary":"err","tests_passed":false}' > "$HERDR_SWARM_STATE_DIR/t1.result.json"
out=$(run_wait); rc=$?
check "exit code is 2" "2" "$rc"

echo
echo "== 10. blocked agent exits 4 immediately =="
clean_state; reset_worktree
write_single_state
printf 'blocked' > "$FAKE_AGENTS/t1.state"
out=$(run_wait --timeout 900); rc=$?
check "exit code is 4" "4" "$rc"

echo
echo "== 11. pending task times out with exit 3 =="
clean_state; reset_worktree
write_single_state
printf 'working' > "$FAKE_AGENTS/t1.state"
out=$(run_wait --timeout 0); rc=$?
check "exit code is 3 on timeout" "3" "$rc"

echo
echo "== 12. idle agent without result file times out with exit 3 =="
clean_state; reset_worktree
write_single_state
printf 'idle' > "$FAKE_AGENTS/t1.state"
out=$(run_wait --timeout 0); rc=$?
check "exit code is 3" "3" "$rc"

echo
echo "== 13. success result with dirty worktree times out with exit 3 =="
clean_state; reset_worktree
write_single_state
printf 'idle' > "$FAKE_AGENTS/t1.state"
printf '{"status":"success","summary":"done","tests_passed":true}' > "$HERDR_SWARM_STATE_DIR/t1.result.json"
printf 'dirty\n' >> "$WT/file.txt"
out=$(run_wait --timeout 0); rc=$?
check "exit code is 3 on dirty worktree" "3" "$rc"

echo
echo "== 14. missing state file exits 1 =="
clean_state
out=$(run_wait "$RUN/nonexistent-state.json"); rc=$?
check "exit code is 1 for missing state" "1" "$rc"

echo
echo "== 15. empty task array exits 1 =="
clean_state
printf '[]' > "$HERDR_SWARM_STATE_DIR/state.json"
out=$(run_wait); rc=$?
check "exit code is 1 for empty array" "1" "$rc"

echo
echo "== 16. non-array state file exits 1 =="
clean_state
printf '{"name":"t1"}' > "$HERDR_SWARM_STATE_DIR/state.json"
out=$(run_wait); rc=$?
check "exit code is 1 for non-array state" "1" "$rc"

echo
echo "== 17. invalid argument exits 1 =="
clean_state
out=$(run_wait --timeout abc); rc=$?
check "exit code is 1 for invalid timeout" "1" "$rc"

echo
echo "== 18. one failing task in multi-task run exits 2 =="
clean_state; reset_worktree
jq -n --arg wt1 "$WT" --arg sf1 "$HERDR_SWARM_STATE_DIR/t1.result.json" \
      --arg wt2 "$WT2" --arg sf2 "$HERDR_SWARM_STATE_DIR/t2.result.json" \
  '[{name:"t1", kind:"pi", branch:"main", worktree_path:$wt1, status_file:$sf1},
    {name:"t2", kind:"pi", branch:"main", worktree_path:$wt2, status_file:$sf2}]' \
  > "$HERDR_SWARM_STATE_DIR/state.json"
printf 'idle' > "$FAKE_AGENTS/t1.state"
printf 'idle' > "$FAKE_AGENTS/t2.state"
printf '{"status":"success","summary":"done","tests_passed":true}' > "$HERDR_SWARM_STATE_DIR/t1.result.json"
printf '{"status":"failure","summary":"err","tests_passed":false}' > "$HERDR_SWARM_STATE_DIR/t2.result.json"
out=$(run_wait); rc=$?
check "exit code is 2 when one task fails" "2" "$rc"

echo
echo "== 19. one blocked task in multi-task run exits 4 =="
clean_state; reset_worktree
jq -n --arg wt1 "$WT" --arg sf1 "$HERDR_SWARM_STATE_DIR/t1.result.json" \
      --arg wt2 "$WT2" --arg sf2 "$HERDR_SWARM_STATE_DIR/t2.result.json" \
  '[{name:"t1", kind:"pi", branch:"main", worktree_path:$wt1, status_file:$sf1},
    {name:"t2", kind:"pi", branch:"main", worktree_path:$wt2, status_file:$sf2}]' \
  > "$HERDR_SWARM_STATE_DIR/state.json"
printf 'idle' > "$FAKE_AGENTS/t1.state"
printf 'blocked' > "$FAKE_AGENTS/t2.state"
printf '{"status":"success","summary":"done","tests_passed":true}' > "$HERDR_SWARM_STATE_DIR/t1.result.json"
out=$(run_wait); rc=$?
check "exit code is 4 when one task is blocked" "4" "$rc"

echo
echo "== 20. custom state file path is resolved =="
clean_state; reset_worktree
CUSTOM_STATE="$T/custom-state.json"
jq -n --arg wt "$WT" --arg sf "$HERDR_SWARM_STATE_DIR/t1.result.json" \
  '[{name:"t1", kind:"pi", branch:"main", worktree_path:$wt, status_file:$sf}]' \
  > "$CUSTOM_STATE"
printf 'idle' > "$FAKE_AGENTS/t1.state"
printf '{"status":"success","summary":"done","tests_passed":true}' > "$HERDR_SWARM_STATE_DIR/t1.result.json"
out=$(run_wait --timeout 10 "$CUSTOM_STATE"); rc=$?
check "exit code is 0 for custom state file" "0" "$rc"

echo
echo "== 21. resolves after polling across interval =="
clean_state; reset_worktree
write_single_state
printf 'working' > "$FAKE_AGENTS/t1.state"
(
  sleep 0.1
  printf '{"status":"success","summary":"done","tests_passed":true}' > "$HERDR_SWARM_STATE_DIR/t1.result.json"
  printf 'idle' > "$FAKE_AGENTS/t1.state"
) &
worker_pid=$!
out=$( ( cd "$RUN" && HERDR_SWARM_WAIT_INTERVAL=0.05 bash "$REPO/scripts/wait.sh" --timeout 5 ) ); rc=$?
wait "$worker_pid" 2>/dev/null || true
check "exit code is 0 after polling resolution" "0" "$rc"

harness_summary
