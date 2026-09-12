#!/usr/bin/env bash
# Shared scaffolding for the test files: the fake binaries, the assertion helpers,
# and the throwaway environment they run in.
#
# Source it, do not execute it:
#
#   source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
#   harness_fake herdr agy pwsh
#   ... scenarios ...
#   harness_summary
#
# The fakes are installers rather than one global set, because `agy` does two
# unrelated jobs across the suite: it answers the quota table for the launch path
# and it plays the reviewer for the critique path. A test file installs the
# binaries it actually needs, so no script ever sees a binary on PATH that its
# scenarios were not written against.
#
# Nothing here touches the real herdr, the real credential vault, the operator's
# repositories or the real brief directory.

# --- throwaway environment --------------------------------------------------

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
BIN="$T/bin"; mkdir -p "$BIN"

# The credential vault and the live-account marker the account layer reads.
export LOCALAPPDATA="$T/appdata"; mkdir -p "$LOCALAPPDATA/herdr-swarm"
printf 'a' > "$LOCALAPPDATA/herdr-swarm/live-account"

# Where the fakes record what they were asked to do. Assertions read these rather
# than a script's stdout: a script prints "sending prompt" whether or not the
# prompt reached the agent, which is how two fixes were once reverted under a
# green suite.
export HERDR_CALL_LOG="$T/herdr-calls.log"
export HERDR_PROMPT_FILE="$T/last-prompt.txt"
export CALL_LOG="$T/calls.log"

# Agent lifecycle state, one file per agent, so a scenario can seed it.
export FAKE_AGENTS="$T/agents"; mkdir -p "$FAKE_AGENTS"

# Briefs must never land in the operator's real ~/.herdr/briefs.
export HERDR_SWARM_BRIEF_DIR="$T/briefs"

export PATH="$BIN:$PATH"

# --- assertions -------------------------------------------------------------

pass=0; fail=0

check() { # check <label> <expected> <actual>
  if [[ "$2" == "$3" ]]; then
    printf 'ok    %-52s %s\n' "$1" "$3"; pass=$((pass+1))
  else
    printf 'FAIL  %-52s expected [%s] got [%s]\n' "$1" "$2" "$3"; fail=$((fail+1))
  fi
}

# `--` so a pattern that starts with a dash is a pattern and not a grep flag.
grepok() { # grepok <label> <pattern> <text>
  if grep -q -- "$2" <<<"$3"; then
    printf 'ok    %s\n' "$1"; pass=$((pass+1))
  else
    printf 'FAIL  %s (no match for /%s/)\n' "$1" "$2"; fail=$((fail+1))
  fi
}

nogrep() { # nogrep <label> <pattern> <text>
  if grep -q -- "$2" <<<"$3"; then
    printf 'FAIL  %s (unexpected match for /%s/)\n' "$1" "$2"; fail=$((fail+1))
  else
    printf 'ok    %s\n' "$1"; pass=$((pass+1))
  fi
}

# Print the tally, tear the scratch directory down, and set the exit code. Takes
# no arguments: a test that created real git worktrees has to release them itself
# before calling this, since the scratch directory cannot go while they are held.
harness_summary() {
  echo
  printf '%d passed, %d failed\n' "$pass" "$fail"
  rm -rf "$T"
  [[ "$fail" -eq 0 ]]
}

# --- fake binaries ----------------------------------------------------------

# harness_fake <name>...  installs each named fake into $BIN.
harness_fake() {
  local name
  for name in "$@"; do
    "_harness_fake_$name"
    chmod +x "$BIN/$name"
  done
}

# herdr: records every call, and answers the subcommands the scripts use.
# Behaviour knobs, all opt-in so an unset one keeps the common path:
#   FAKE_WORKTREE       checkout_path reported by `worktree create`
#   FAKE_START_RC       non-zero makes `agent start` fail, as herdr does on a
#                       rejected timeout
#   FAKE_AGENT_STATUS   agent_status for an agent with no seeded state file
#   FAKE_REMOVE_FAILS   1 makes `worktree remove` fail
# An agent's state is a file under $FAKE_AGENTS: <name>.state holds its status and
# <name>.gone means herdr no longer knows it, which is what a closed TUI looks
# like from outside.
_harness_fake_herdr() {
  cat > "$BIN/herdr" <<'FAKE'
#!/usr/bin/env bash
echo "herdr $*" >> "$HERDR_CALL_LOG"
case "$1 ${2:-}" in
  "worktree create")
    printf '{"result":{"root_pane":{"pane_id":"pane-1"},"workspace":{"workspace_id":"ws-1","worktree":{"checkout_path":"%s"}}}}' "${FAKE_WORKTREE:-}" ;;
  "agent start")
    if [[ "${FAKE_START_RC:-0}" != "0" ]]; then
      echo '{"error":{"code":"invalid_agent_timeout"}}'; exit "$FAKE_START_RC"
    fi
    echo '{"result":{"type":"agent_started"}}' ;;
  "agent get")
    name="$3"
    if [[ -f "$FAKE_AGENTS/$name.gone" ]]; then echo '{"result":{}}'; exit 0; fi
    printf '{"result":{"agent":{"agent_status":"%s","interactive_ready":true,"state_change_seq":7}}}' \
      "$(cat "$FAKE_AGENTS/$name.state" 2>/dev/null || echo "${FAKE_AGENT_STATUS:-working}")" ;;
  # herdr agent prompt <name> <text>, so the text is $4. Recorded verbatim: the
  # point is to assert on what the real herdr would have received.
  "agent prompt")
    printf '%s' "$4" > "$HERDR_PROMPT_FILE"
    echo '{"result":{"type":"agent_prompted"}}' ;;
  # The key spelling is checked on purpose: the real herdr rejects "ctrl-c", and
  # a single ctrl+c usually does not exit agy.
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
FAKE
}

# agy: the quota table when asked for /usage, otherwise a reviewer.
# The real agy answers for whoever is signed in, so the fake keys the five-hour
# figure off the same live-account file the account layer swaps.
# Knobs: FAKE_GEM_WEEK, FAKE_GEM_5H_A, FAKE_GEM_5H_B, FAKE_PITFALLS_CHECKED
# (the pitfalls_checked array the reviewer answers with, verbatim JSON).
_harness_fake_agy() {
  cat > "$BIN/agy" <<'FAKE'
#!/usr/bin/env bash
if [[ "$*" == *"/usage"* ]]; then
  live=$(cat "$LOCALAPPDATA/herdr-swarm/live-account" 2>/dev/null || echo a)
  if [[ "$live" == "b" ]]; then five="${FAKE_GEM_5H_B:-22}"; else five="${FAKE_GEM_5H_A:-22}"; fi
  printf 'Gemini Models\tWeekly Limit Remaining\t%s%%\t2026-09-04T00:18:35Z\n' "${FAKE_GEM_WEEK:-80}"
  printf 'Gemini Models\tFive Hour Limit Remaining\t%s%%\t2026-08-30T18:31:35Z\n' "$five"
  printf 'Claude and GPT models\tWeekly Limit Remaining\t94%%\t2026-09-04T07:31:35Z\n'
  printf 'Claude and GPT models\tFive Hour Limit Remaining\t82%%\t2026-08-30T20:31:35Z\n'
  exit 0
fi
echo "agy $*" >> "$CALL_LOG"
# Which brief it was handed decides which answer it gives back: the trim review
# asks about overengineering, the critique asks for a verdict. The fenced block is
# deliberate — real models wrap JSON in one, and the parser has to cope.
if [[ "$*" == *overengineering* ]]; then
  echo 'Sure. {"cuts":[{"file":"file.txt","what":"drop the config flag","why":"never read","saves":"3"}],"summary":"one flag too many"}'
else
  checked="${FAKE_PITFALLS_CHECKED:-[]}"
  echo '```json
{"verdict":"pass","confidence":"high","issues":[],"pitfalls_checked":'"$checked"',"summary":"does what was asked"}
```'
fi
FAKE
}

# python: stands in for the interpreter the soundness check interrogates. It
# answers with $FAKE_PY_ORIGIN, which is where the module under test resolved
# from - inside the worktree on a sound run, in the main checkout on the
# editable-install trap this check exists to catch. An empty value is a module
# that could not be resolved at all.
_harness_fake_python() {
  cat > "$BIN/python" <<'FAKE'
#!/usr/bin/env bash
echo "python $*" >> "$CALL_LOG"
printf '%s
' "${FAKE_PY_ORIGIN:-}"
FAKE
}

_harness_fake_codex() {
  cat > "$BIN/codex" <<'FAKE'
#!/usr/bin/env bash
echo "codex $*" >> "$CALL_LOG"
echo '{"verdict":"pass","confidence":"medium","issues":[],"summary":"fine"}'
FAKE
}

# pwsh stands in for the account script: -Mode list reports the vault, -Mode use
# returns the exit code the scenario is testing and records the new live account.
# Knobs: FAKE_VAULT_B (full|empty), FAKE_SWITCH_RC.
_harness_fake_pwsh() {
  cat > "$BIN/pwsh" <<'FAKE'
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
FAKE
}
