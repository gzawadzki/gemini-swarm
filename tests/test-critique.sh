#!/usr/bin/env bash
# Dry run of scripts/critique.sh and scripts/trim.sh against fake reviewers.
# Run: bash tests/test-critique.sh
#
# Checks which model reviews a task, that the verdict records whether the review
# was independent, and that codex reviewers start with plugins off.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
BIN="$T/bin"; mkdir -p "$BIN"
export LOCALAPPDATA="$T/appdata"; mkdir -p "$LOCALAPPDATA/herdr-swarm"
printf 'a' > "$LOCALAPPDATA/herdr-swarm/live-account"

pass=0; fail=0
check() { if [[ "$2" == "$3" ]]; then printf 'ok    %-46s %s\n' "$1" "$3"; pass=$((pass+1));
          else printf 'FAIL  %-46s expected [%s] got [%s]\n' "$1" "$2" "$3"; fail=$((fail+1)); fi; }
grepok() { if grep -q -- "$2" <<<"$3"; then printf 'ok    %s\n' "$1"; pass=$((pass+1));
           else printf 'FAIL  %s (no match for /%s/)\n' "$1" "$2"; fail=$((fail+1)); fi; }

# agy answers /usage with a quota table and anything else with a reply; the
# reply depends on whether it was handed the critique or the trim brief.
cat > "$BIN/agy" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"/usage"* ]]; then
  printf 'Gemini Models\tWeekly Limit Remaining\t80%%\t2026-09-04T00:18:35Z\n'
  printf 'Gemini Models\tFive Hour Limit Remaining\t50%%\t2026-08-30T18:31:35Z\n'
  exit 0
fi
echo "agy $*" >> "$CALL_LOG"
if [[ "$*" == *overengineering* ]]; then
  echo 'Sure. {"cuts":[{"file":"file.txt","what":"drop the config flag","why":"never read","saves":"3"}],"summary":"one flag too many"}'
else
  echo '```json
{"verdict":"pass","confidence":"high","issues":[],"summary":"does what was asked"}
```'
fi
EOF
cat > "$BIN/codex" <<'EOF'
#!/usr/bin/env bash
echo "codex $*" >> "$CALL_LOG"
echo '{"verdict":"pass","confidence":"medium","issues":[],"summary":"fine"}'
EOF
chmod +x "$BIN"/*
export PATH="$BIN:$PATH"
export CALL_LOG="$T/calls.log"
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

write_state() { # worker-model
  jq -n --arg wt "$SRC" --arg sha "$base_sha" --arg model "$1" \
    '[{name:"t1", kind:"agy", model:$model, branch:"main", base:$sha, base_sha:$sha,
       worktree_path:$wt, prompt:"append world to file.txt"}]' > "$HERDR_SWARM_STATE_DIR/state.json"
  : > "$CALL_LOG"
}
critique() { ( cd "$RUN" && bash "$REPO/scripts/critique.sh" t1 2>&1 ); }
verdict() { jq -r "$1" "$HERDR_SWARM_STATE_DIR/t1.critique.json"; }

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
printf '%d passed, %d failed\n' "$pass" "$fail"
rm -rf "$T"
[[ "$fail" -eq 0 ]]
