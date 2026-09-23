#!/usr/bin/env bash
# Dry run of scripts/verify.sh, the deterministic half of the egress gate.
# Run: bash tests/test-verify.sh
#
# The question these scenarios ask is not "did the tests pass" but "did they run
# on this worktree's code". An editable install pins imports to a fixed path, so
# a suite inside a worktree can exercise the code from main and go green on a
# diff it never touched. A gate that can do that is worse than no gate.
set -uo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/harness.sh"
harness_fake python

WT="$T/worktree"; mkdir -p "$WT"
MAIN="$T/main-checkout"; mkdir -p "$MAIN"

RUN="$T/run"; mkdir -p "$RUN"
export HERDR_SWARM_STATE_DIR="$RUN/.herdr-swarm"; mkdir -p "$HERDR_SWARM_STATE_DIR"

# A native python prints a native path; the worktree here is an MSYS one. The
# comparison has to survive that, so the fixtures use the same form the real
# binary would emit.
native() { cygpath -m "$1" 2>/dev/null || echo "$1"; }

write_state() { # verify-cmd
  jq -n --arg wt "$WT" --arg cmd "$1" \
    '[{name:"t1", kind:"pi", branch:"main", worktree_path:$wt, verify:$cmd}]' \
    > "$HERDR_SWARM_STATE_DIR/state.json"
  rm -f "$HERDR_SWARM_STATE_DIR/t1.verify.json"
}
verify() { ( cd "$RUN" && bash "$REPO/scripts/verify.sh" t1 2>&1 ); }
result() { jq -r "$1" "$HERDR_SWARM_STATE_DIR/t1.verify.json"; }

# A python project the check can reason about: a name to import, and a package
# directory for that name to resolve to.
make_python_project() {
  printf '[project]\nname = "demo-pkg"\nversion = "0.1.0"\n' > "$WT/pyproject.toml"
  mkdir -p "$WT/demo_pkg" "$MAIN/demo_pkg"
  : > "$WT/demo_pkg/__init__.py"
  : > "$MAIN/demo_pkg/__init__.py"
}

echo "== 1. tests pass and the code resolved inside the worktree: pass =="
make_python_project
write_state "true"
export FAKE_PY_ORIGIN="$(native "$WT")/demo_pkg/__init__.py"
out=$(verify); rc=$?
check  "exit code"            "0"       "$rc"
check  "status"               "pass"    "$(result .status)"
check  "soundness recorded"   "sound"   "$(result .soundness)"
grepok "says where it resolved" "demo_pkg"  "$out"

echo
echo "== 2. tests pass but the code came from the main checkout: fail =="
make_python_project
write_state "true"
export FAKE_PY_ORIGIN="$(native "$MAIN")/demo_pkg/__init__.py"
out=$(verify); rc=$?
# The suite was green. That is exactly the case this ticket exists for: an
# editable install pinned the import to the main checkout, so the gate tested
# code the agent never wrote.
check  "exit code is a failure" "1"     "$rc"
check  "status"               "fail"    "$(result .status)"
check  "soundness recorded"   "unsound" "$(result .soundness)"
grepok "names the module"     "demo_pkg"                 "$out"
grepok "names where it resolved from" "main-checkout"    "$out"
# An editable-install problem must not read as a broken test suite.
check  "the detail is kept for later" "true" "$(result '.soundness_detail | test("main-checkout")')"

echo
echo "== 3. soundness cannot be established: skipped, never a pass =="
rm -f "$WT/pyproject.toml"
write_state "true"
export FAKE_PY_ORIGIN=""
out=$(verify); rc=$?
check  "exit code"            "0"         "$rc"
# "I could not tell" renders as skipped. A pass here would be the gate claiming
# something it did not check.
check  "status"               "skipped"   "$(result .status)"
check  "soundness recorded"   "unknown"   "$(result .soundness)"

echo
echo "== 4. the escape hatch disables the check, visibly =="
make_python_project
write_state "true"
export FAKE_PY_ORIGIN="$(native "$MAIN")/demo_pkg/__init__.py"
out=$(HERDR_SWARM_NO_SOUNDNESS=1 verify); rc=$?
check  "exit code"            "0"          "$rc"
check  "status"               "pass"       "$(result .status)"
# Disabled has to be distinguishable from checked-and-fine, or the result lies
# by omission.
check  "soundness recorded"   "disabled"   "$(result .soundness)"

echo
echo "== 5. a failing verify command still fails, and is not blamed on soundness =="
make_python_project
write_state "false"
export FAKE_PY_ORIGIN="$(native "$WT")/demo_pkg/__init__.py"
out=$(verify); rc=$?
check  "exit code"            "1"       "$rc"
check  "status"               "fail"    "$(result .status)"
nogrep "does not mention resolution" "resolved outside" "$out"

echo
echo "== 6. no verify command at all: skipped, as before =="
rm -f "$WT/pyproject.toml"
write_state ""
out=$(verify); rc=$?
check  "exit code"            "0"         "$rc"
check  "status"               "skipped"   "$(result .status)"

echo
echo "== 7. a failing command whose code did resolve locally is the agent's problem =="
make_python_project
write_state "false"
export FAKE_PY_ORIGIN="$(native "$WT")/demo_pkg/__init__.py"
out=$(verify) || true
# The tests ran on this worktree's code and still failed, so the diff is what is
# broken. Distinguishing this from scenario 10 is the whole point of asking.
check  "soundness is explicit" "sound" "$(result .soundness)"
grepok "sends it back to the agent" "herdr agent prompt" "$out"

echo
echo "== 8. review.sh tells an unsound gate apart from a broken suite =="
git -C "$WT" init -q -b main 2>/dev/null
git -C "$WT" config user.email t@example.com
git -C "$WT" config user.name Test
git -C "$WT" add -A >/dev/null 2>&1
git -C "$WT" commit -qm init >/dev/null 2>&1
base_sha=$(git -C "$WT" rev-parse HEAD)
jq -n --arg wt "$WT" --arg sha "$base_sha" --arg cmd "true" \
  '[{name:"t1", kind:"pi", branch:"main", base:$sha, base_sha:$sha,
     worktree_path:$wt, verify:$cmd}]' > "$HERDR_SWARM_STATE_DIR/state.json"
rm -f "$HERDR_SWARM_STATE_DIR/t1.verify.json"
export FAKE_PY_ORIGIN="$(native "$MAIN")/demo_pkg/__init__.py"
out=$(verify) || true
check  "verify failed on resolution" "fail" "$(result .status)"
out=$( cd "$RUN" && bash "$REPO/scripts/review.sh" t1 2>&1 )
# "re-prompt the agent" is the wrong instruction here: the agent's diff may be
# fine and the environment is what lied. Sending it back burns a bounce on
# someone who cannot fix it.
grepok "names the resolution problem" "outside the worktree" "$out"
nogrep "does not blame the agent"     "re-prompt the agent"  "$out"

echo
echo "== 9. the probe does not run from the worktree =="
make_python_project
write_state "true"
# An editable install pinned to the main checkout, in a flat-layout project:
# probing from the worktree would answer "worktree" and call it sound, which is
# the one failure mode this ticket forbids.
export FAKE_PY_WORKTREE="$WT"
export FAKE_PY_ORIGIN_CWD="$(native "$WT")/demo_pkg/__init__.py"
export FAKE_PY_ORIGIN="$(native "$MAIN")/demo_pkg/__init__.py"
out=$(verify) || true
check  "not fooled by cwd resolution" "unsound" "$(result .soundness)"
check  "status"                       "fail"    "$(result .status)"
nogrep "probe avoided the worktree"   "python(cwd=$WT)" "$(cat "$CALL_LOG")"
unset FAKE_PY_ORIGIN_CWD FAKE_PY_WORKTREE

echo
echo "== 10. a failing command still gets its resolution established =="
make_python_project
write_state "false"
export FAKE_PY_ORIGIN="$(native "$MAIN")/demo_pkg/__init__.py"
out=$(verify); rc=$?
# The wrong tree makes tests fail as readily as pass: new tests in the worktree
# run against old code from the main checkout. Reporting a bare fail sends the
# agent to fix a diff that was never the problem.
check  "exit code"              "1"       "$rc"
check  "status"                 "fail"    "$(result .status)"
check  "resolution was established" "unsound" "$(result .soundness)"
grepok "review advises the environment" "outside the worktree" \
  "$( cd "$RUN" && bash "$REPO/scripts/review.sh" t1 2>&1 || true )"

echo
echo "== 11. each undeterminable branch is reported, and none of them pass =="
write_state "true"
# no project name in the manifest
printf '[project]\nversion = "0.1.0"\n' > "$WT/pyproject.toml"
out=$(verify) || true
check  "no name -> skipped"     "skipped" "$(result .status)"
check  "no name -> unknown"     "unknown" "$(result .soundness)"
check  "the detail says which"  "true"    "$(result '.soundness_detail | test("no project name")')"
# a name that resolves to nothing
make_python_project
write_state "true"
export FAKE_PY_ORIGIN=""
out=$(verify) || true
check  "unresolvable -> skipped" "skipped" "$(result .status)"
check  "the detail says which"   "true"    "$(result '.soundness_detail | test("could not be resolved")')"
# a manifest that quotes the name the other legal way
printf "[project]\nname = 'demo-pkg'\nversion = '0.1.0'\n" > "$WT/pyproject.toml"
export FAKE_PY_ORIGIN="$(native "$WT")/demo_pkg/__init__.py"
write_state "true"
out=$(verify) || true
check  "single-quoted name is read" "sound" "$(result .soundness)"

echo
echo "== 12. no verify command: the detail does not claim a command failed =="
rm -f "$WT/pyproject.toml"
write_state ""
out=$(verify) || true
check  "status"                 "skipped" "$(result .status)"
# The default sentence was written for the command-failed path; reaching it here
# would cache a false explanation of why nothing was established.
check  "detail fits this path"  "true"    "$(result '.soundness_detail | test("no verify command")')"
check  "nothing was asked here" "not checked" "$(result .soundness)"
nogrep "does not blame a command" "did not pass" "$(result .soundness_detail)"

harness_summary
