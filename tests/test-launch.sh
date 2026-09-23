#!/usr/bin/env bash
# End-to-end dry run of scripts/launch.sh.
# Run: bash tests/test-launch.sh
#
# Drives it against fake `herdr` and `pi` binaries, in a throwaway
# git repo. Nothing touches the real credential vault, the real herdr, or the
# user's repos.
set -uo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/harness.sh"
harness_fake herdr pi
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
{"tasks":[{"name":"t1","kind":"pi","model":"gemini-3.1-pro-high","repo":"$SRC",
  "branch":"agent/t1","prompt":"do the thing","args":[],
  "files":["file.txt"],
  "pitfalls":["file.txt is read by two callers; keep the trailing newline"],
  "ready_timeout_ms":1000,"work_budget_ms":900000}]}
JSON
  ( cd "$dir" && : > "$HERDR_CALL_LOG" && bash "$REPO/scripts/launch.sh" tasks.json 2>&1 )
}

run_config() { # reads a tasks.json body on stdin, runs launch.sh against it
  cat > "$LAST_RUN_DIR/tasks.json"
  ( cd "$LAST_RUN_DIR" && : > "$HERDR_CALL_LOG" && bash "$REPO/scripts/launch.sh" tasks.json 2>&1 )
}

echo "== 1. pi launches with the Antigravity provider =="
printf 'a' > "$LOCALAPPDATA/herdr-swarm/live-account"; new_run_dir
out=$(run_launch)
# The installed skill is a junction to the working repo, so a run has to say which
# tree state produced it. Reported, never blocked.
grepok "reports the skill's commit"        "swarm skill: [0-9a-f]"           "$out"
grepok "starts the agent"                 "starting pi agent" "$out"
grepok "sends the prompt"                 "sending prompt"                  "$out"
check  "state.json leaves account to Pi" "" "$(jq -r '.[0].account' "$LAST_STATE_DIR/state.json")"
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
# The pitfalls are the recon the orchestrator did; the agent has to read them as
# requirements, and must not paste them back out as comments. Earlier diffs
# reproduced prompt steps in the source verbatim, numbering and all.
grepok "brief heads the pitfalls as constraints" "^## Constraints"           "$(cat "$T/briefs/t1.md")"
grepok "brief carries the pitfall text"    "keep the trailing newline"       "$(cat "$T/briefs/t1.md")"
grepok "brief forbids restating them"      "comments, docstrings"            "$(cat "$T/briefs/t1.md")"
grepok "brief carries the declared files"  "^- file.txt"                     "$(cat "$T/briefs/t1.md")"
check  "state records the declared files" "file.txt" "$(jq -r '.[0].files | join(",")' "$LAST_STATE_DIR/state.json")"
check  "state records the pitfalls" "1" "$(jq -r '.[0].pitfalls | length' "$LAST_STATE_DIR/state.json")"
grepok "herdr got the ready timeout"       "\-\-timeout 1000"               "$(cat "$HERDR_CALL_LOG")"
check  "state records the work budget" "900000" "$(jq -r '.[0].work_budget_ms' "$LAST_STATE_DIR/state.json")"
check  "state records the brief file" "true" "$(jq -r '.[0].brief_file | endswith("t1.md")' "$LAST_STATE_DIR/state.json")"
check  "state records a launch time" "true" "$(jq -r '.[0].started_at > 0' "$LAST_STATE_DIR/state.json")"
# The run's own record, written before the first agent exists. cleanup.sh reads
# it back to name the archive and to keep the config, which used to be gone by
# the time anyone wanted to know how a task had been defined.
check  "run.json names the run" "true" "$(jq -r '.run_id | test("^[0-9]{8}T[0-9]{6}Z$")' "$LAST_STATE_DIR/run.json")"
check  "run.json embeds the config" "do the thing" "$(jq -r '.config.tasks[0].prompt' "$LAST_STATE_DIR/run.json")"
check  "run.json records the skill commit" "true" "$(jq -r '.skill_commit | test("^[0-9a-f]+$")' "$LAST_STATE_DIR/run.json")"
check  "run.json records whether the tree was dirty" "number" "$(jq -r '.skill_dirty | type' "$LAST_STATE_DIR/run.json")"
check  "run.json records the dirty file list" "array" "$(jq -r '.skill_dirty_files | type' "$LAST_STATE_DIR/run.json")"
grepok "says where the run will be archived" "Run id: [0-9]\{8\}T" "$out"
grepok "agent started through herdr"      "agent start t1"                  "$(cat "$HERDR_CALL_LOG")"

echo
echo "== 2. pi uses the Antigravity provider and separates thinking level =="
new_run_dir
out=$(run_launch)
grepok "starts pi" "agent start t1 --kind pi" "$(cat "$HERDR_CALL_LOG")"
grepok "selects Antigravity" "--provider antigravity" "$(cat "$HERDR_CALL_LOG")"
grepok "normalizes model" "--model gemini-3.1-pro" "$(cat "$HERDR_CALL_LOG")"
grepok "sets thinking" "--thinking high" "$(cat "$HERDR_CALL_LOG")"
grepok "approves local project files" "--approve" "$(cat "$HERDR_CALL_LOG")"
check "pi account stays managed by the provider" "" "$(jq -r '.[0].account' "$LAST_STATE_DIR/state.json")"

echo
echo "== 2b. the Luna route starts Codex at xhigh =="
new_run_dir
out=$(run_config <<JSON
{"tasks":[{"name":"t1","kind":"codex","model":"gpt-6-luna","effort":"xhigh","repo":"$SRC",
  "branch":"agent/t1","prompt":"trace the coupled session failure and fix it","args":[],
  "files":["file.txt"],"pitfalls":["the session check has two callers"],
  "verify":"git status --porcelain"}]}
JSON
)
grepok "starts the Luna worker through herdr" "agent start t1 --kind codex" "$(cat "$HERDR_CALL_LOG")"
grepok "selects Luna 6" "--model gpt-6-luna" "$(cat "$HERDR_CALL_LOG")"
grepok "sets xhigh reasoning" 'model_reasoning_effort="xhigh"' "$(cat "$HERDR_CALL_LOG")"
check "state records the Luna route" "codex:gpt-6-luna:xhigh" "$(jq -r '.[0] | [.kind,.model,.effort] | join(":")' "$LAST_STATE_DIR/state.json")"

echo
echo "== 3. old agy configs are rejected explicitly =="
new_run_dir
out=$(run_config <<JSON
{"tasks":[{"name":"t1","kind":"agy","model":"gemini-3.8-flash-high","repo":"$SRC",
  "branch":"agent/t1","prompt":"do the thing","args":[],
  "files":["file.txt"],"pitfalls":[]}]}
JSON
)
grepok "migration message" "kind 'agy' was replaced by 'pi'" "$out"
check "no agent started" "" "$(grep 'agent start' "$HERDR_CALL_LOG" || true)"
echo "== 5d. a work-budget-sized ready timeout is clamped, not sent =="
printf 'a' > "$LOCALAPPDATA/herdr-swarm/live-account"; new_run_dir
out=$(run_config <<JSON
{"tasks":[{"name":"t1","kind":"pi","model":"gemini-3.8-flash-high","repo":"$SRC",
  "branch":"agent/t1","prompt":"do the thing","args":[],
  "files":["file.txt"],"pitfalls":[],"timeout_ms":1800000}]}
JSON
)
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
grepok "reports the failure"              "pi did not start"               "$out"
grepok "removed the worktree"             "worktree remove"                 "$(cat "$HERDR_CALL_LOG")"
# The branch, not the worktree, is what blocks the retry: `worktree create`
# refuses a branch that already exists.
check  "branch was deleted" "" "$(git -C "$SRC" rev-parse --verify --quiet refs/heads/agent/t1 || true)"
check  "state.json is empty" "0" "$(jq 'length' "$LAST_STATE_DIR/state.json")"

echo
echo "== 5f. a task with no pitfalls is skipped, and the next task still launches =="
printf 'a' > "$LOCALAPPDATA/herdr-swarm/live-account"; new_run_dir
out=$(run_config <<JSON
{"tasks":[
 {"name":"t1","kind":"pi","model":"gemini-3.8-flash-high","repo":"$SRC",
  "branch":"agent/t1","prompt":"do the thing","args":[],"files":["file.txt"]},
 {"name":"t2","kind":"pi","model":"gemini-3.8-flash-high","repo":"$SRC",
  "branch":"agent/t2","prompt":"do the other thing","args":[],
  "files":["file.txt"],"pitfalls":["the loader caches file.txt for the process lifetime"]}]}
JSON
)
# Matched against "missing pitfalls (", not a bare "pitfalls": the rest of the
# message mentions both field names whichever one is absent, so a loose pattern
# passes even when the code names the wrong field.
grepok "names the missing field"          "missing pitfalls ("              "$out"
nogrep "does not blame the field that is there" "missing files ("           "$out"
grepok "says to read the code first"      "[Rr]ead the code"                "$out"
check  "no worktree for the bad task" "" "$(grep -o '\-\-label t1' "$HERDR_CALL_LOG" || true)"
check  "no agent for the bad task" "" "$(grep -o 'agent start t1' "$HERDR_CALL_LOG" || true)"
# A typo in one task must not cost the tasks after it, which is how the
# agent-name and repo checks already behave.
grepok "the next task still launched"     "agent start t2"                  "$(cat "$HERDR_CALL_LOG")"
check  "state.json holds only the good task" "t2" "$(jq -r '.[].name' "$LAST_STATE_DIR/state.json")"

echo
echo "== 5g. a task with no files is skipped =="
printf 'a' > "$LOCALAPPDATA/herdr-swarm/live-account"; new_run_dir
out=$(run_config <<JSON
{"tasks":[{"name":"t1","kind":"pi","model":"gemini-3.8-flash-high","repo":"$SRC",
  "branch":"agent/t1","prompt":"do the thing","args":[],"pitfalls":["a trap"]}]}
JSON
)
grepok "names the missing field"          "missing files ("                 "$out"
check  "no agent was started" "" "$(grep 'agent start' "$HERDR_CALL_LOG" || true)"
check  "state.json is empty" "0" "$(jq 'length' "$LAST_STATE_DIR/state.json")"

echo
echo "== 5g2. an empty files array is skipped =="
printf 'a' > "$LOCALAPPDATA/herdr-swarm/live-account"; new_run_dir
out=$(run_config <<JSON
{"tasks":[{"name":"t1","kind":"pi","model":"gemini-3.8-flash-high","repo":"$SRC",
  "branch":"agent/t1","prompt":"do the thing","args":[],
  "files":[],"pitfalls":["a trap"]}]}
JSON
)
grepok "says the list is empty"           "empty 'files' array"             "$out"
check  "no agent was started" "" "$(grep 'agent start' "$HERDR_CALL_LOG" || true)"
check  "state.json is empty" "0" "$(jq 'length' "$LAST_STATE_DIR/state.json")"

echo
echo "== 5g3. a non-string entry is rejected before a worktree exists =="
printf 'a' > "$LOCALAPPDATA/herdr-swarm/live-account"; new_run_dir
out=$(run_config <<JSON
{"tasks":[
 {"name":"t1","kind":"pi","model":"gemini-3.8-flash-high","repo":"$SRC",
  "branch":"agent/t1","prompt":"do the thing","args":[],
  "files":["file.txt"],"pitfalls":[3]},
 {"name":"t2","kind":"pi","model":"gemini-3.8-flash-high","repo":"$SRC",
  "branch":"agent/t2","prompt":"do the other thing","args":[],
  "files":["file.txt"],"pitfalls":["the loader caches file.txt"]}]}
JSON
)
# Rendering the brief runs `jq -r '.pitfalls[] | "- " + .'`, which fails on a
# non-string entry. That happens after `agent start`, and under `set -e` it
# would kill the run holding a live agent and an orphan worktree, taking every
# later task with it. So the entries are type-checked before any of that.
grepok "says which field is malformed"    "entries in pitfalls"             "$out"
nogrep "does not blame the sound field"   "entries in files"                "$out"
check  "no worktree for the bad task" "" "$(grep -o '\-\-label t1' "$HERDR_CALL_LOG" || true)"
grepok "the next task still launched"     "agent start t2"                  "$(cat "$HERDR_CALL_LOG")"
check  "state.json holds only the good task" "t2" "$(jq -r '.[].name' "$LAST_STATE_DIR/state.json")"

echo
echo "== 5h. an empty pitfalls list warns but launches =="
printf 'a' > "$LOCALAPPDATA/herdr-swarm/live-account"; new_run_dir
out=$(run_config <<JSON
{"tasks":[{"name":"t1","kind":"pi","model":"gemini-3.8-flash-high","repo":"$SRC",
  "branch":"agent/t1","prompt":"do the thing","args":[],
  "files":["file.txt"],"pitfalls":[]}]}
JSON
)
# "I read it and found nothing" stays expressible, and stays distinguishable
# from a forgotten field.
grepok "warns about the empty list"       "no pitfalls"                     "$out"
grepok "the task still launched"          "agent start t1"                  "$(cat "$HERDR_CALL_LOG")"
# The anti-restate wording is generated, so it cannot be dropped by a task that
# declared nothing to restate.
grepok "brief still forbids restating"    "comments, docstrings"            "$(cat "$T/briefs/t1.md")"

echo
echo "== 6. refuses to run outside a herdr pane =="
out=$(cd "$T" && HERDR_ENV=0 bash "$REPO/scripts/launch.sh" /dev/null 2>&1); rc=$?
check "exit code" "1" "$rc"
grepok "says why" "not a herdr-managed pane" "$out"

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
rm -rf "$T"
[[ "$fail" -eq 0 ]]
