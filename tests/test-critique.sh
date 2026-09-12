#!/usr/bin/env bash
# Dry run of scripts/critique.sh and scripts/trim.sh against fake reviewers.
# Run: bash tests/test-critique.sh
#
# Checks which model reviews a task, that the verdict records whether the review
# was independent, and that codex reviewers start with plugins off.
set -uo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/harness.sh"
harness_fake agy codex
export HERDR_ENV=1

SRC="$T/repo"; mkdir -p "$SRC"
git -C "$SRC" init -q -b main
git -C "$SRC" config user.email t@example.com
git -C "$SRC" config user.name Test
echo hello > "$SRC/file.txt"
git -C "$SRC" add -A && git -C "$SRC" commit -qm init
base_sha=$(git -C "$SRC" rev-parse HEAD)
echo world >> "$SRC/file.txt"
git -C "$SRC" commit -qam change

RUN="$T/run"; mkdir -p "$RUN"
export HERDR_SWARM_STATE_DIR="$RUN/.herdr-swarm"; mkdir -p "$HERDR_SWARM_STATE_DIR"

write_state() { # worker-model [files-json] [pitfalls-json]
  jq -n --arg wt "$SRC" --arg sha "$base_sha" --arg model "$1" --argjson files "${2:-[]}" --argjson pitfalls "${3:-[]}" \
    '[{name:"t1", kind:"agy", model:$model, branch:"main", base:$sha, base_sha:$sha,
       worktree_path:$wt, files:$files, pitfalls:$pitfalls,
       prompt:"append world to file.txt"}]' > "$HERDR_SWARM_STATE_DIR/state.json"
  : > "$CALL_LOG"
  rm -f "$HERDR_SWARM_STATE_DIR"/t1.critique.json "$HERDR_SWARM_STATE_DIR"/t1.trim.json
}
critique() { ( cd "$RUN" && bash "$REPO/scripts/critique.sh" t1 2>&1 ); }
verdict() { jq -r "$1" "$HERDR_SWARM_STATE_DIR/t1.critique.json"; }
brief() { cat "$HERDR_SWARM_STATE_DIR/t1.critique.brief.md"; }

echo "== 1. task written by the critique model: reviewed by the alternate =="
write_state "gemini-3.8-flash-high"
out=$(critique); rc=$?
check  "exit code on pass" "0" "$rc"
grepok "agy ran on the alternate model"  "--model gemini-3.1-pro-high" "$(cat "$CALL_LOG")"
check  "verdict records reviewer"  "gemini-3.1-pro-high"   "$(verdict .model)"
check  "verdict records worker"    "gemini-3.8-flash-high" "$(verdict .worker_model)"
check  "verdict is independent"    "true"                  "$(verdict .independent)"

echo
echo "== 2. task written by another model: default critique model =="
write_state "gemini-3.1-pro-high"
out=$(critique)
grepok "agy ran on the default model"    "--model gemini-3.8-flash-high" "$(cat "$CALL_LOG")"
check  "verdict records reviewer"  "gemini-3.8-flash-high" "$(verdict .model)"
check  "verdict is independent"    "true"                  "$(verdict .independent)"

echo
echo "== 3. codex reviewing a codex task: plugins off, flagged as not independent =="
write_state "gpt-5.6-luna"
out=$(HERDR_SWARM_CRITIQUE_KIND=codex critique)
grepok "codex plugins are switched off"  "--disable plugins" "$(cat "$CALL_LOG")"
grepok "warns about self-review"         "not an independent review" "$out"
check  "verdict is not independent" "false" "$(verdict .independent)"

echo
echo "== 3b. HERDR_SWARM_CODEX_PLUGINS=1 keeps plugins on =="
write_state "gpt-5.6-luna"
out=$(HERDR_SWARM_CODEX_PLUGINS=1 HERDR_SWARM_CRITIQUE_KIND=codex critique)
check  "no --disable plugins" "" "$(grep -- '--disable plugins' "$CALL_LOG" || true)"

echo
echo "== 4. trim: advisory suggestions, always exit 0 =="
write_state "gemini-3.1-pro-high"
out=$( cd "$RUN" && bash "$REPO/scripts/trim.sh" t1 2>&1 ); rc=$?
check  "exit code" "0" "$rc"
grepok "prints the cut"          "drop the config flag" "$out"
check  "trim status"   "trim" "$(jq -r .status "$HERDR_SWARM_STATE_DIR/t1.trim.json")"
check  "one cut"       "1"    "$(jq '.cuts | length' "$HERDR_SWARM_STATE_DIR/t1.trim.json")"
check  "worktree untouched" "" "$(git -C "$SRC" status --porcelain)"
check  "brief stays out of the worktree" "" "$(ls "$SRC" | grep -i brief || true)"

echo
echo "== 5. the declared pitfalls and scope reach the reviewer =="
write_state "gemini-3.1-pro-high" \
  '["file.txt","other.txt"]' \
  '["file.txt is read by two callers","the loader caches it for the process lifetime"]'
out=$(FAKE_PITFALLS_CHECKED='[{"pitfall":1,"status":"respected","note":"both callers updated"},{"pitfall":2,"status":"respected","note":"cache untouched"}]' critique)
# The brief is the artefact the reviewer actually reads, so assert on it rather
# than on what the script printed while building it.
grepok "brief lists pitfall 1"        "1. file.txt is read by two callers"  "$(brief)"
grepok "brief lists pitfall 2"        "2. the loader caches it"             "$(brief)"
grepok "brief calls them criteria"    "[Jj]udge the diff against each"      "$(brief)"
grepok "brief states the scope"       "^- file.txt$"                        "$(brief)"
grepok "brief asks about strays"      "outside that list"                   "$(brief)"
grepok "brief asks if a stray was needed" "whether it was necessary"        "$(brief)"
grepok "schema asks for pitfalls_checked" "pitfalls_checked"                "$(brief)"
check  "verdict records both pitfalls examined" "2" "$(verdict '.pitfalls_checked | length')"
# The index the reviewer answers with is resolved back to the pitfall text, so a
# later reader does not need the task config to know what was checked.
check  "verdict keeps the pitfall text" "file.txt is read by two callers" "$(verdict '.pitfalls_checked[0].pitfall')"
check  "verdict records the status"   "respected" "$(verdict '.pitfalls_checked[0].status')"
# The gate filters, it never approves: that wording survives a pass.
grepok "pass still does not approve"  "does not replace it"                 "$out"

echo
echo "== 5b. a pitfall the diff ignored is named in the verdict =="
write_state "gemini-3.1-pro-high" '["file.txt"]' '["keep the trailing newline"]'
out=$(FAKE_PITFALLS_CHECKED='[{"pitfall":1,"status":"violated","note":"final newline dropped"}]' critique)
check  "verdict names the violated pitfall" "keep the trailing newline" "$(verdict '.pitfalls_checked[0].pitfall')"
check  "verdict records it as violated" "violated" "$(verdict '.pitfalls_checked[0].status')"

echo
echo "== 5c. a task with no declared pitfalls still reviews =="
write_state "gemini-3.1-pro-high" '["file.txt"]' '[]'
out=$(critique); rc=$?
check  "exit code" "0" "$rc"
nogrep "no empty criteria section"    "[Jj]udge the diff against each"      "$(brief)"
check  "verdict has an empty list" "0" "$(verdict '.pitfalls_checked | length')"

echo
echo "== 5d. a truncated diff is recorded as truncated =="
write_state "gemini-3.1-pro-high" '["file.txt"]' '["a trap"]'
out=$(HERDR_SWARM_CRITIQUE_DIFF_LINES=3 critique)
grepok "brief says it was cut off"    "cut off at 3 lines"                  "$(brief)"
check  "verdict records the truncation" "true" "$(verdict '.diff_truncated')"
write_state "gemini-3.1-pro-high" '["file.txt"]' '["a trap"]'
out=$(critique)
check  "an untruncated diff says so"  "false" "$(verdict '.diff_truncated')"

echo
echo "== 5e. a pass that violated a pitfall is not reported as a pass =="
write_state "gemini-3.1-pro-high" '["file.txt"]' '["keep the trailing newline"]'
out=$(FAKE_PITFALLS_CHECKED='[{"pitfall":1,"status":"violated","note":"dropped"}]' critique); rc=$?
# The reviewer said "pass" while reporting a trap it was told about as violated.
# That reply contradicts itself, and the brief told it a violation cannot be a
# pass. Taking the word at face value is how a known defect reaches the operator
# looking green in status.sh.
check  "verdict is downgraded"        "revise"  "$(verdict .verdict)"
check  "the reviewer's own word is kept" "pass" "$(verdict .reviewer_verdict)"
check  "exit code says revise"        "1"       "$rc"

echo
echo "== 5f. a clean pass keeps its verdict and its wording =="
write_state "gemini-3.1-pro-high" '["file.txt"]' '["keep the trailing newline"]'
out=$(FAKE_PITFALLS_CHECKED='[{"pitfall":1,"status":"respected","note":"kept"}]' critique); rc=$?
check  "verdict is pass"              "pass"    "$(verdict .verdict)"
check  "reviewer verdict matches"     "pass"    "$(verdict .reviewer_verdict)"
check  "exit code"                    "0"       "$rc"
grepok "still refuses to approve"     "does not replace it"                 "$out"


echo "== 5g. a malformed pitfalls_checked still leaves a verdict behind =="
write_state "gemini-3.1-pro-high" '["file.txt"]' '["a trap"]'
out=$(FAKE_PITFALLS_CHECKED='"none"' critique); rc=$?
# Reviewer output is untrusted. Iterating a string kills jq, and a bare
# assignment under set -e would take the run down after the reviewer already
# ran, leaving status.sh with no answer at all.
check  "a verdict file exists"        "true"  "$(test -f "$HERDR_SWARM_STATE_DIR/t1.critique.json" && echo true || echo false)"
check  "the verdict is still readable" "pass" "$(verdict .verdict)"
check  "the bad list reads as empty"  "0"     "$(verdict '.pitfalls_checked | length')"
check  "exit code"                    "0"     "$rc"

echo
echo "== 5h. entries that are not objects do not kill the run =="
write_state "gemini-3.1-pro-high" '["file.txt"]' '["a trap"]'
out=$(FAKE_PITFALLS_CHECKED='[3,"x"]' critique); rc=$?
check  "a verdict file exists"        "true"  "$(test -f "$HERDR_SWARM_STATE_DIR/t1.critique.json" && echo true || echo false)"
check  "junk entries are dropped"     "0"     "$(verdict '.pitfalls_checked | length')"
check  "exit code"                    "0"     "$rc"

echo
echo "== 5i. an out-of-range pitfall number is not relabelled =="
write_state "gemini-3.1-pro-high" '["file.txt"]' '["first trap","second trap"]'
out=$(FAKE_PITFALLS_CHECKED='[{"pitfall":0,"status":"violated","note":"n"},{"pitfall":9,"status":"respected","note":"n"}]' critique)
# jq resolves a negative index from the end, so pitfall 0 silently became the
# text of the last declared pitfall: a violation naming a trap that was not
# violated. Out of range now keeps the number the reviewer wrote.
check  "zero is not the last pitfall"  "0" "$(verdict '.pitfalls_checked[0].pitfall')"
check  "nine stays nine"               "9" "$(verdict '.pitfalls_checked[1].pitfall')"

echo
echo "== 5j. the verdict records how many pitfalls were declared =="
write_state "gemini-3.1-pro-high" '["file.txt"]' '["first trap","second trap","third trap"]'
out=$(FAKE_PITFALLS_CHECKED='[{"pitfall":1,"status":"respected","note":"n"}]' critique)
# One entry out of three declared is a shallow pass. The verdict file has to
# carry the denominator, or a later reader cannot tell that from a thorough one.
check  "declared count is recorded"   "3" "$(verdict '.pitfalls_declared')"
check  "examined count is the entries" "1" "$(verdict '.pitfalls_checked | length')"

echo
echo "== 5k. an unknown verdict keeps the reviewer's own word =="
write_state "gemini-3.1-pro-high" '["file.txt"]' '[]'
cat > "$BIN/agy" <<'FAKE'
#!/usr/bin/env bash
echo "agy $*" >> "$CALL_LOG"
echo '{"verdict":"looks-fine","confidence":"high","issues":[],"summary":"s"}'
FAKE
chmod +x "$BIN/agy"
out=$(critique)
check  "normalised for the pipeline"  "unparseable" "$(verdict .verdict)"
check  "the reviewer's word survives" "looks-fine"  "$(verdict .reviewer_verdict)"
harness_fake agy

echo
echo "== 5l. review.sh shows what the critique examined =="
write_state "gemini-3.1-pro-high" '["file.txt"]' '["keep the trailing newline"]'
out=$(FAKE_PITFALLS_CHECKED='[{"pitfall":1,"status":"violated","note":"dropped"}]' critique)
out=$( cd "$RUN" && bash "$REPO/scripts/review.sh" t1 2>&1 )
# A downgrade the operator never sees is a downgrade that did not happen: this
# and status.sh are the two places they actually look.
grepok "review names the violated pitfall" "keep the trailing newline" "$out"
grepok "review shows the downgrade"        "the reviewer said pass"    "$out"

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
rm -rf "$T"
[[ "$fail" -eq 0 ]]
