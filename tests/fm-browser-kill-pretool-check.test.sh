#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# Behavior tests for the browser kill guard (spec huynhtandat223/firstmate#200, E4b).
#
# BK1, BK2: bin/fm-browser-kill-command-policy.mjs decides deny or allow for the
# exact past commands, and bin/fm-browser-kill-pretool-check.sh resolves the
# pids of a lab listener and of browsers, then turns the verdict into the hook
# answer under the log-only switch (config/enforce-browser-kill).
# Every case runs in a lab home under a temp root, never the live home. The
# commands are only handed to the guard as text; the test never runs a kill.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-browser-kill-pretool-check)

POLICY="$ROOT/bin/fm-browser-kill-command-policy.mjs"
LISTENER_PID=""

stop_listener() {
  [ -z "$LISTENER_PID" ] || kill "$LISTENER_PID" 2>/dev/null || true
  LISTENER_PID=""
}
on_exit() {
  stop_listener
  fm_test_cleanup
}
trap on_exit EXIT

# A lab listener on a free loopback port; sets LISTENER_PID and LISTENER_PORT.
start_listener() {
  local out="$TMP_ROOT/listener.out"
  stop_listener
  : > "$out"
  node -e 'const s=require("net").createServer().listen(0,"127.0.0.1",()=>console.log(s.address().port))' > "$out" 2>/dev/null < /dev/null &
  LISTENER_PID=$!
  for _ in $(seq 1 50); do
    [ -s "$out" ] && break
    sleep 0.1
  done
  LISTENER_PORT=$(head -1 "$out")
  [ -n "$LISTENER_PORT" ] || fail "the lab listener did not report a port"
}

# A primary-shaped checkout: plain git repo, AGENTS.md, bin/ with the wrapper,
# the policy, the walker, the shared classifier and the enforce lib.
make_primary() {  # <dir>
  local dir=$1 f
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  mkdir -p "$dir/bin" "$dir/state" "$dir/config"
  for f in fm-browser-kill-pretool-check.sh fm-hook-host-lib.sh fm-browser-kill-command-policy.mjs fm-shell-walk-lib.mjs fm-arm-command-policy.mjs fm-enforce-lib.sh; do
    cp "$ROOT/bin/$f" "$dir/bin/$f"
  done
  chmod +x "$dir/bin/fm-browser-kill-pretool-check.sh" "$dir/bin/fm-browser-kill-command-policy.mjs"
}

policy() {  # <command> [policy args...]: the policy answer's first two fields
  local cmd=$1
  shift
  node "$POLICY" "$@" --command "$cmd" | cut -f1,2
}

test_bk1_browser_kills_are_denied() {
  local cmd out
  out=$(node "$POLICY" --command 'pkill -f chrome-devtools-mcp')
  [ "$(printf '%s' "$out" | cut -f1,2)" = "$(printf 'deny\tkill-browser-name')" ] || fail "BK1 pkill not denied: $out"
  printf '%s' "$out" | grep -q 'CHROME_DEVTOOLS_AXI_SESSION=<name> chrome-devtools-axi stop' || fail "BK1 reason lacks the session-name form: $out"
  [ "$(policy 'kill 4242' --pids 4242)" = "$(printf 'deny\tkill-browser-pid')" ] || fail "BK1 kill of a listed pid not denied"
  for cmd in \
    'pkill chrome' \
    'pkill -9 -f "chrome-devtools-axi"' \
    'killall chrome' \
    'killall -q chromium' \
    'sudo pkill -f chrome' \
    'kill $(pgrep -f chrome-devtools)' \
    'kill -9 $(pgrep chrome)' \
    'kill $(lsof -ti:9222)' \
    'kill -9 `lsof -t -i tcp:9333`' \
    'lsof -ti:9222 | xargs kill' \
    'lsof -ti tcp:9333 | xargs -r kill -9' \
    'ps aux | grep chrome | awk "{print \$2}" | xargs kill' \
    'ss -ltnp | grep 9222 | grep -o "pid=[0-9]*" | cut -d= -f2 | xargs kill' \
    'fuser -k 9222/tcp' \
    'echo go; pkill -f chrome-devtools-mcp' \
    'PID=$(lsof -ti:9222); kill "$PID"' \
    'PID=$(lsof -ti:9333) && kill -9 ${PID}' \
    'P=$(pgrep -f chrome); Q=$P; kill $Q' \
    '{ PID=$(ss -ltnp | grep 9222); }; kill $PID'; do
    [ "$(policy "$cmd" | cut -f1)" = deny ] || fail "must deny: $cmd => $(policy "$cmd")"
  done
  [ "$(policy 'kill $(lsof -ti:7777)' --ports 7777 | cut -f1)" = deny ] || fail "a port from config/browser-ports must be watched"
  [ "$(policy 'kill $(lsof -ti:7777)' | cut -f1)" = allow ] || fail "a port outside 9222, 9333 and the config must not be watched"
  pass "BK1: pkill -f chrome-devtools-mcp, a kill of a listed pid and a kill fed by port 9222 or 9333 are denied, naming the session-name form"
}

test_bk2_other_commands_are_allowed() {
  local cmd
  for cmd in \
    'CHROME_DEVTOOLS_AXI_SESSION=planner chrome-devtools-axi stop' \
    'chrome-devtools-axi stop' \
    'kill 4243' \
    'kill -TERM 4243 4244' \
    'kill -0 4243' \
    'kill -0 4242' \
    'kill -s 0 4242' \
    'kill 9222' \
    'kill -9 9333' \
    'PID=$(lsof -ti:7777); kill "$PID"' \
    'PID=9222; kill $PID' \
    'PID=$(lsof -ti:9222); PID=4243; kill $PID' \
    '(PID=$(lsof -ti:9222)); kill $PID' \
    'kill $PID' \
    'pkill -f playwright-server' \
    'killall node-fixture' \
    'kill $(pgrep -f my-dev-server)' \
    'lsof -ti:7777 | xargs kill' \
    'ps aux | grep chrome' \
    'grep -rn "pkill chrome" docs' \
    'echo "pkill -f chrome-devtools-mcp is blocked"' \
    'cat > /tmp/note <<EOF
pkill chrome
kill 4242
EOF' \
    "bash -c 'grep -n \"pkill chrome\" notes.md'" \
    'fuser 9222/tcp' \
    'fuser -k 7777/tcp'; do
    [ "$(policy "$cmd" --pids 4242)" = allow ] || fail "must allow: $cmd => $(policy "$cmd" --pids 4242)"
  done
  pass "BK2: closing a session by name, a kill of a pid that is not a browser, and a heredoc or grep that only mentions pkill chrome are allowed"
}

run_check() {  # <dir> <command>: the wrapper in --claude stdin form; sets RC, OUT, ERR
  local dir=$1 cmd=$2
  OUT=$(jq -cn --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}' | FM_HOME="$dir" "$dir/bin/fm-browser-kill-pretool-check.sh" --claude 2>"$dir/err")
  RC=$?
  ERR=$(cat "$dir/err")
}

test_hook_resolves_the_lab_listener_pid() {
  local dir="$TMP_ROOT/hook-block" log
  make_primary "$dir"
  start_listener
  printf '# the Tester browser\n%s\n\n' "$LISTENER_PORT" > "$dir/config/browser-ports"
  log="$dir/state/enforce-browser-kill.log"
  run_check "$dir" "kill $LISTENER_PID"
  [ "$RC" -eq 0 ] && [ -z "$OUT$ERR" ] || fail "log-only default must allow silently, got exit $RC: $ERR"
  grep -q "would-deny	kill-browser-pid	kill $LISTENER_PID" "$log" || fail "log-only default wrote no would-deny line: $(cat "$log" 2>&1)"
  printf 'block\n' > "$dir/config/enforce-browser-kill"
  run_check "$dir" "kill -9 $LISTENER_PID"
  [ "$RC" -eq 2 ] || fail "BK1 block mode must deny the kill of the lab listener, got exit $RC: $ERR"
  [ -z "$OUT" ] || fail "claude deny must leave stdout empty: $OUT"
  printf '%s' "$ERR" | jq -e '.hookSpecificOutput.permissionDecision == "deny" and (.systemMessage | test("CHROME_DEVTOOLS_AXI_SESSION=<name> chrome-devtools-axi stop"))' >/dev/null \
    || fail "deny answer lacks the session-name form: $ERR"
  printf '%s\n' "$ERR" > "$TMP_ROOT/bk1-hook-answer.json"
  run_check "$dir" 'pkill -f chrome-devtools-mcp'
  [ "$RC" -eq 2 ] || fail "BK1 block mode must deny pkill -f chrome-devtools-mcp"
  run_check "$dir" 'CHROME_DEVTOOLS_AXI_SESSION=planner chrome-devtools-axi stop'
  [ "$RC" -eq 0 ] && [ -z "$ERR" ] || fail "BK2 closing a session by name must pass: $ERR"
  sleep 60 > /dev/null 2>&1 &
  local other=$!
  run_check "$dir" "kill $other"
  kill "$other" 2>/dev/null || true
  [ "$RC" -eq 0 ] && [ -z "$ERR" ] || fail "BK2 a kill of a pid that is not a browser must pass: $ERR"
  run_check "$dir" 'grep -n "pkill chrome" docs/notes.md'
  [ "$RC" -eq 0 ] && [ -z "$ERR" ] || fail "BK2 a grep that mentions pkill chrome must pass: $ERR"
  grep -q '	deny	kill-browser-pid	' "$log" || fail "block mode wrote no deny line: $(cat "$log")"
  pass "BK1, BK2: the hook finds the pid of a lab listener on a port in config/browser-ports, logs it until the switch is set, and denies it in block mode; a non-browser pid passes"
}

test_a_port_outside_the_config_is_not_watched() {
  local dir="$TMP_ROOT/hook-unlisted"
  make_primary "$dir"
  printf 'block\n' > "$dir/config/enforce-browser-kill"
  start_listener
  run_check "$dir" "kill $LISTENER_PID"
  [ "$RC" -eq 0 ] && [ -z "$ERR" ] || fail "a listener on a port nobody named must pass, got exit $RC: $ERR"
  stop_listener
  pass "with config/browser-ports absent, a listener on another port is not a browser pid"
}

test_hook_is_inert_in_a_task_worktree_and_fails_open() {
  local base="$TMP_ROOT/inert-base" wt="$TMP_ROOT/inert-wt"
  make_primary "$base"
  fm_git_worktree "$base" "$wt" fm/browser-kill-test
  : > "$wt/AGENTS.md"
  mkdir -p "$wt/bin" "$wt/config" "$wt/state"
  cp "$base"/bin/* "$wt/bin/"
  printf 'block\n' > "$wt/config/enforce-browser-kill"
  run_check "$wt" 'pkill -f chrome-devtools-mcp'
  [ "$RC" -eq 0 ] && [ -z "$ERR" ] || fail "a task worktree must be inert, got exit $RC: $ERR"
  printf 'not json' | FM_HOME="$base" "$base/bin/fm-browser-kill-pretool-check.sh" --claude 2>/dev/null \
    || fail "malformed stdin must fail open"
  pass "the hook is inert in a task worktree and fails open on malformed input"
}

test_claude_settings_register_the_browser_guard() {
  local dir="$TMP_ROOT/wiring" cmd payload rc
  make_primary "$dir"
  printf 'block\n' > "$dir/config/enforce-browser-kill"
  cmd=$(jq -r '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command | select(contains("fm-browser-kill-pretool-check.sh"))' "$ROOT/.claude/settings.json")
  [ -n "$cmd" ] || fail "PreToolUse Bash has no fm-browser-kill-pretool-check.sh entry in .claude/settings.json"
  payload=$(jq -cn '{tool_name:"Bash",tool_input:{command:"pkill -f chrome-devtools-mcp"}}')
  printf '%s' "$payload" | env -u GROK_AGENT -u GROK_HOOK_EVENT CLAUDE_PROJECT_DIR="$dir" FM_HOME="$dir" bash -c "$cmd" >/dev/null 2>"$dir/err"
  rc=$?
  [ "$rc" -eq 2 ] || fail "the registered settings command did not deny pkill -f chrome-devtools-mcp: $(cat "$dir/err")"
  pass "the command registered in .claude/settings.json runs the guard and denies the BK1 command in block mode"
}

test_bk1_browser_kills_are_denied
test_bk2_other_commands_are_allowed
test_hook_resolves_the_lab_listener_pid
test_a_port_outside_the_config_is_not_watched
test_hook_is_inert_in_a_task_worktree_and_fails_open
test_claude_settings_register_the_browser_guard

echo "# fm-browser-kill-pretool-check.test.sh: all assertions passed"
