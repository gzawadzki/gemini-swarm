#!/usr/bin/env bash
# Dry run of scripts/status.sh and the scope report it shares with review.sh.
# Run: bash tests/test-status.sh
#
# Both views read one shared reader, so they are tested against the same
# fixtures here: the point of the reader is that the two cannot disagree, and
# separate fixtures would let them drift while both files stayed green.
set -uo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/harness.sh"
harness_fake herdr

WT="$T/worktree"; mkdir -p "$WT"
git -C "$WT" init -q -b main
git -C "$WT" config user.email t@example.com
git -C "$WT" config user.name Test
printf 'one\n' > "$WT/declared.txt"
git -C "$WT" add -A && git -C "$WT" commit -qm init
BASE_SHA=$(git -C "$WT" rev-parse HEAD)

RUN="$T/run"; mkdir -p "$RUN"
export HERDR_SWARM_STATE_DIR="$RUN/.herdr-swarm"; mkdir -p "$HERDR_SWARM_STATE_DIR"

# A task that is review-ready, so the scope report is what varies between
# scenarios rather than the task's lifecycle.
write_state() { # files-json
  jq -n --arg wt "$WT" --arg sha "$BASE_SHA" --argjson files "$1" \
        --arg sf "$HERDR_SWARM_STATE_DIR/t1.result.json" --argjson now "$(date +%s)" \
    '[{name:"t1", kind:"agy", branch:"main", base:$sha, base_sha:$sha,
       worktree_path:$wt, status_file:$sf, files:$files, pitfalls:["a trap"],
       work_budget_ms:900000, started_at:$now}]' > "$HERDR_SWARM_STATE_DIR/state.json"
  printf '{"status":"success","summary":"done","tests_passed":true}' \
    > "$HERDR_SWARM_STATE_DIR/t1.result.json"
  printf 'idle' > "$FAKE_AGENTS/t1.state"
}
status() { ( cd "$RUN" && bash "$REPO/scripts/status.sh" 2>&1 ); }
review() { ( cd "$RUN" && bash "$REPO/scripts/review.sh" t1 2>&1 ); }

reset_worktree() {
  git -C "$WT" checkout -q -B main "$BASE_SHA"
  git -C "$WT" clean -qfd
}

echo "== 1. a task inside its declared files and under the size guideline is silent =="
reset_worktree
printf 'two\n' >> "$WT/declared.txt"
git -C "$WT" commit -qam change
write_state '["declared.txt"]'
out=$(status)
# The report has to mean something when it appears, so a well-behaved task must
# produce no scope noise at all.
nogrep "status says nothing about scope" "SCOPE"        "$out"
nogrep "status says nothing about size"  "line"         "$out"
rout=$(review)
nogrep "review says nothing about scope" "outside the declared" "$rout"

echo
echo "== 2. a file outside the declared list is named in both views =="
reset_worktree
printf 'two\n' >> "$WT/declared.txt"
printf 'new\n' > "$WT/strayed.txt"
git -C "$WT" add -A && git -C "$WT" commit -qm change
write_state '["declared.txt"]'
out=$(status)
grepok "status names the stray"        "strayed.txt"    "$out"
nogrep "status does not name declared files" "declared.txt" "$out"
rout=$(review)
grepok "review names the same stray"   "outside the declared list: strayed.txt" "$rout"
# Advisory only: a stray is a line to read, not a bounce.
nogrep "status does not bounce the task" "then re-prompt the agent" "$out"
grepok "the task is still review-ready" "ready to verify" "$out"

echo
echo "== 3. a directory declared with a trailing slash covers what is under it =="
reset_worktree
mkdir -p "$WT/src"
printf 'a\n' > "$WT/src/a.txt"
printf 'b\n' > "$WT/src/b.txt"
git -C "$WT" add -A && git -C "$WT" commit -qm change
write_state '["src/"]'
out=$(status)
nogrep "nothing under the directory strays" "src/a.txt" "$out"

echo
echo "== 4. an oversized diff is called out after the fact =="
reset_worktree
python -c "
import sys
open(sys.argv[1], 'w').write('\n'.join('line %d' % i for i in range(600)))
" "$WT/declared.txt"
git -C "$WT" commit -qam big
write_state '["declared.txt"]'
out=$(status)
grepok "status reports the size"       "60[0-9] lines changed" "$out"
grepok "status names the guideline"    "400-line guideline"    "$out"
rout=$(review)
grepok "review reports the same size"  "60[0-9] lines changed" "$rout"
# Already written by the time anyone sees it: the value is the next task being
# narrower, not this one being thrown away.
nogrep "size does not block the task"  "do not merge"   "$out"

echo
echo "== 5. the two views agree, field for field =="
reset_worktree
printf 'two\n' >> "$WT/declared.txt"
printf 'new\n' > "$WT/strayed.txt"
git -C "$WT" add -A && git -C "$WT" commit -qm change
write_state '["declared.txt"]'
# One reader, two callers: if these ever disagree the reader has been bypassed.
sout=$(status | grep -o 'outside the declared list: .*' | head -1)
rout=$(review | grep -o 'outside the declared list: .*' | head -1)
check "both views name the same file" "$sout" "$rout"

echo
echo "== 6. a task with no declared files reports no strays =="
reset_worktree
printf 'new\n' > "$WT/anything.txt"
git -C "$WT" add -A && git -C "$WT" commit -qm change
write_state '[]'
out=$(status)
# Nothing was declared, so nothing can be outside it. Reporting every file as a
# stray would be noise on exactly the tasks that predate the schema.
nogrep "no stray report without a declaration" "anything.txt" "$out"

echo
echo "== 7. reading status runs no gate and spawns no agent =="
reset_worktree
printf 'two\n' >> "$WT/declared.txt"
git -C "$WT" commit -qam change
write_state '["declared.txt"]'
: > "$CALL_LOG"
out=$(status)
check "no reviewer was run" "" "$(cat "$CALL_LOG")"
check "no agent was started" "" "$(grep 'agent start' "$HERDR_CALL_LOG" || true)"
check "no verify result was written" "false" \
  "$(test -f "$HERDR_SWARM_STATE_DIR/t1.verify.json" && echo true || echo false)"

echo
echo "== 8. an unsound verify failure is not sent back to the agent =="
# Pins the advice added with the soundness check: status.sh is the surface the
# operator reaches first, so the wrong next step here costs a bounce.
reset_worktree
printf 'two\n' >> "$WT/declared.txt"
git -C "$WT" commit -qam change
write_state '["declared.txt"]'
jq -n '{status:"fail", cmd:"pytest", soundness:"unsound",
        soundness_detail:"module demo resolved to /main/demo, outside the worktree"}' \
  > "$HERDR_SWARM_STATE_DIR/t1.verify.json"
out=$(status)
grepok "says the failure was resolution" "resolution, not on the tests" "$out"
nogrep "does not blame the agent"        "then re-prompt the agent"     "$out"
jq -n '{status:"fail", cmd:"pytest", soundness:"sound", soundness_detail:"inside"}' \
  > "$HERDR_SWARM_STATE_DIR/t1.verify.json"
out=$(status)
grepok "an ordinary failure still bounces" "re-prompt the agent"        "$out"
rm -f "$HERDR_SWARM_STATE_DIR/t1.verify.json"

echo
echo "== 9. an ordinary diff a little over the guideline is not called out =="
reset_worktree
python -c "
import sys
open(sys.argv[1], 'w').write('\n'.join('line %d' % i for i in range(450)))
" "$WT/declared.txt"
git -C "$WT" commit -qam over
write_state '["declared.txt"]'
out=$(status)
# 450 lines is a well-sized task that ran a little long. Announcing it as too
# wide is the false traffic that teaches an operator to skim past the block.
nogrep "no call-out just above the aim" "lines changed" "$out"
# And well past it, the call-out still fires: asserted either side of the
# threshold, because a fixture far from the boundary cannot tell the two apart.
reset_worktree
python -c "
import sys
open(sys.argv[1], 'w').write('\n'.join('line %d' % i for i in range(800)))
" "$WT/declared.txt"
git -C "$WT" commit -qam wide
write_state '["declared.txt"]'
out=$(status)
grepok "well past the aim is called out" "80[0-9] lines changed" "$out"

echo
echo "== 10. the reader answers directly, not only through the views =="
# The views print prose; these assert the values the shared reader produced, so
# a rewording cannot hide a behaviour change.
reset_worktree
printf 'two\n' >> "$WT/declared.txt"
printf 'x\n' > "$WT/strayed.txt"
git -C "$WT" add -A && git -C "$WT" commit -qm c
# One jq, no process substitution: jq is a native binary and cannot open the
# /dev/fd path bash hands it, so the entry came back empty and the reader was
# asked about a task with no declared files at all.
entry=$(jq -n --arg wt "$WT" --arg sha "$BASE_SHA" \
  '{name:"t1", base_sha:$sha, worktree_path:$wt, files:["declared.txt"]}')
( source "$REPO/scripts/lib.sh"
  scope_report "$entry" "$WT"
  printf '%s|%s|%s\n' "$SCOPE_STRAYS" "$SCOPE_STRAY_COUNT" "$SCOPE_READABLE" ) > "$T/reader.out"
check "the reader names the stray" "strayed.txt|1|yes" "$(cat "$T/reader.out")"

echo
echo "== 11. a renamed file is not reported as a stray =="
reset_worktree
mkdir -p "$WT/sub"
git -C "$WT" mv declared.txt "sub/moved name.txt"
git -C "$WT" commit -qm rename
write_state '["sub/moved name.txt"]'
out=$(status)
# The plain numstat renders a rename as `old => new` in the path field and
# C-quotes any path with a space, so both shapes compared unequal to every
# declared entry and every rename came out a stray.
nogrep "the rename is not a stray" "outside the declared list" "$out"

echo
echo "== 12. a diff that cannot be read reports nothing rather than 'no strays' =="
reset_worktree
printf 'two\n' >> "$WT/declared.txt"
git -C "$WT" commit -qam c
entry=$(jq -n --arg wt "$WT" '{name:"t1", base_sha:"0000000000000000000000000000000000000000", worktree_path:$wt, files:["declared.txt"]}')
( source "$REPO/scripts/lib.sh"
  scope_report "$entry" "$WT"
  printf '%s|%s\n' "${SCOPE_READABLE:-no}" "$SCOPE_LINES" ) > "$T/unreadable.out"
# Silence and "I read it and found nothing" are different answers; the reader
# must not give the second when it could not read the diff.
check "unreadable stays unreadable" "no|0" "$(cat "$T/unreadable.out")"

harness_summary
