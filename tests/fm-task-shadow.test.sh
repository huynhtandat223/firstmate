#!/usr/bin/env bash
# tests/fm-task-shadow.test.sh - the task contract in shadow (spec huynhtandat223/cfw-modules#1675, T3, firstmate#176).
#
# The hook bin/fm-task-shadow.sh is driven with a fake writer that records its arguments, then each state script that
# calls the hook is driven for real (a temp home, a fake tmux) with the same fake writer. A script's case goes red when
# its hook call is removed: the mutation proofs at the end copy bin/, delete that one call and run the case again.
# The real run against Dev 5001 on probe rows is recorded with the delivery, not repeated here.
# shellcheck disable=SC2016 # mutation proofs pass literal source patterns to perl
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-task-shadow)

# ---- the fake writer ----------------------------------------------------------

mk_writer() {  # <dir>: a fake bin/fm-task.sh that records one line per call
  cat > "$1/fake-writer" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_CALLS"
printf 'auth=%s url=%s token=%s\n' "${FM_TASK_AUTH:-}" "${FM_TASK_BASE_URL:-}" "${FM_TASK_TOKEN_FILE:-}" >> "$FAKE_CALLS.env"
[ -z "${FAKE_HANG:-}" ] || sleep "$FAKE_HANG"
if [ -n "${FAKE_FAIL:-}" ]; then
  case "$*" in
    *"$FAKE_FAIL"*)
      if [ -z "${FAKE_FAIL_ONCE:-}" ] || [ ! -e "$FAKE_CALLS.failed" ]; then
        : > "$FAKE_CALLS.failed"
        echo 'refused by the writer' >&2
        exit 5
      fi ;;
  esac
fi
exit 0
SH
  chmod +x "$1/fake-writer"
}

# Sets CASE_DIR HOME_DIR WRITER CALLS for one isolated case.
make_case() {  # <name> <on|off>
  CASE_DIR="$TMP_ROOT/$1"
  HOME_DIR="$CASE_DIR/home"
  mkdir -p "$HOME_DIR/config" "$HOME_DIR/state" "$HOME_DIR/data"
  mk_writer "$CASE_DIR"
  WRITER="$CASE_DIR/fake-writer"
  CALLS="$CASE_DIR/calls.log"
  : > "$CALLS"
  [ "$2" = off ] || : > "$HOME_DIR/config/task-shadow"
}

hook() {  # <hook args...>: run the hook in the case home
  env FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_TASK_SHADOW_WRITER="$WRITER" FAKE_CALLS="$CALLS" "${HOOK:-$ROOT/bin/fm-task-shadow.sh}" "$@"
}

calls() {  # the recorded writer calls without the key, actor and role every call carries
  sed 's/ --key [^ ]* --actor shadow --role system$//' "$CALLS"
}
keys() { sed -n 's/.* --key \([^ ]*\) --actor shadow --role system$/\1/p' "$CALLS"; }

# ---- the hook itself ----------------------------------------------------------

test_flag_absent_writes_nothing() {
  make_case off off
  hook dispatched t1 ship repo claude || fail "the hook failed with the flag absent"
  hook status "$HOME_DIR/config" "$HOME_DIR/state/t1.status" || fail "the status hook failed with the flag absent"
  assert_equals "" "$(cat "$CALLS")" "a writer ran with the flag absent"
  assert_absent "$HOME_DIR/state/task-shadow.log" "the hook logged with the flag absent"
  pass "flag absent: no writer runs and nothing is logged"
}

test_dispatched_creates_assigns_and_starts() {
  make_case dispatched on
  printf '%s\n' '- [ ] t1 - Build the thing https://github.com/o/r/issues/5 (repo: r) (kind: ship) (since 2026-10-25)' '  note' > "$HOME_DIR/data/backlog.md"
  hook dispatched t1 ship r claude || fail "the hook failed"
  assert_equals "$(printf '%s\n' \
    'create t1 --title Build the thing --kind ship --repo r' \
    'assign t1 --to claude' \
    'start t1')" "$(calls)" "dispatched calls"
  assert_equals "$(printf '%s\n' shadow:t1:create shadow:t1:assign shadow:t1:start)" "$(keys)" "dispatched keys"
  assert_contains "$(cat "$HOME_DIR/state/task-shadow.log")" " t1 dispatched create rc=0" "the writer call is logged"
  hook dispatched t1 scout r claude >/dev/null
  assert_equals "$(printf '%s\n' shadow:t1:create shadow:t1:assign shadow:t1:start shadow:t1:create shadow:t1:assign shadow:t1:start)" "$(keys)" "a repeated hook repeats the same keys"
  make_case dispatched-other on
  hook dispatched t2 secondmate-x "" claude || fail "the hook failed"
  assert_equals "$(printf '%s\n' 'create t2 --title t2 --kind other' 'assign t2 --to claude' 'start t2')" "$(calls)" "an unknown kind and no backlog row"
  pass "dispatched: create, assign and start, with stable keys; the title comes from the backlog row"
}

status_line() {  # <line>: the task t1 ends its status file with <line>, then the hook runs
  printf '%s\n' "$1" >> "$HOME_DIR/state/t1.status"
  : > "$CALLS"
  hook status "$HOME_DIR/config" "$HOME_DIR/state/t1.status" || fail "the status hook failed on: $1"
}

test_status_lines_map_to_writer_commands() {
  make_case status on
  status_line 'working [at=1790000000]: setup done'
  assert_equals 'heartbeat t1 --note setup done' "$(calls)" "working"
  status_line 'done [at=1790000001]: PR https://github.com/o/r/pull/7 ready'
  assert_equals 'done t1 --summary PR https://github.com/o/r/pull/7 ready --changed-files - --verification - --residual-risk - --pr-url https://github.com/o/r/pull/7' "$(calls)" "done with a PR"
  status_line 'done: ready in branch'
  assert_equals 'done t1 --summary ready in branch --changed-files - --verification - --residual-risk -' "$(calls)" "done without a PR"
  status_line 'needs-decision [key=pick]: choose a or b'
  assert_equals "ask t1 --question choose a or b --option Decide now --option Decide later --recommendation - --why a needs-decision status line" "$(calls)" "needs-decision"
  status_line 'blocked [at=1790000002]: waiting for the token'
  assert_equals 'block transient t1 --reason waiting for the token --next-actor firstmate' "$(calls)" "blocked"
  status_line 'paused [at=1790000003]: waiting for CI until 2026-10-26T08:00Z'
  assert_equals 'block transient t1 --reason waiting for CI until 2026-10-26T08:00Z --next-actor firstmate --until 2026-10-26T08:00Z' "$(calls)" "paused with until"
  status_line 'failed [at=1790000004]: tests red'
  assert_equals 'block failure t1 --reason tests red --next-actor firstmate' "$(calls)" "failed"
  status_line 'resolved [key=pick]: chose a'
  assert_equals 'unblock t1' "$(calls)" "resolved"
  : > "$CALLS"
  hook status "$HOME_DIR/config" "$HOME_DIR/state/none.status" || fail "the hook failed on a missing status file"
  assert_equals "" "$(cat "$CALLS")" "a missing status file writes nothing"
  pass "status: each worker state becomes the writer command the plan names, with the last complete line only"
}

test_working_after_a_block_unblocks_and_restarts() {
  make_case working-after-block on
  printf '%s\n' 'working [at=1]: back at it' > "$HOME_DIR/state/t1.status"
  FAKE_FAIL=heartbeat FAKE_FAIL_ONCE=1 hook status "$HOME_DIR/config" "$HOME_DIR/state/t1.status" || fail "the hook failed"
  assert_equals "$(printf '%s\n' 'heartbeat t1 --note back at it' 'unblock t1' 'start t1' 'heartbeat t1 --note back at it')" "$(calls)" "working after a refused heartbeat"
  pass "status: a working line the record refuses is retried after unblock and start"
}

test_the_hook_never_fails_the_script() {
  make_case failing on
  FAKE_FAIL=create hook dispatched t1 ship r claude || fail "the hook exited non-zero when the writer refused"
  assert_contains "$(cat "$HOME_DIR/state/task-shadow.log")" " t1 dispatched create rc=5 refused by the writer" "the refusal is logged"
  assert_contains "$(calls)" "assign t1" "the hook went on after a refused create"
  make_case hanging on
  local started=$SECONDS
  FAKE_HANG=8 FM_TASK_SHADOW_TIMEOUT=1 hook cleaned-up t1 || fail "the hook exited non-zero when the writer hung"
  [ $((SECONDS - started)) -lt 5 ] || fail "the hook waited for a hung writer"
  assert_contains "$(cat "$HOME_DIR/state/task-shadow.log")" " t1 cleaned-up event rc=124" "the timeout is logged"
  make_case missing-writer on
  FM_TASK_SHADOW_WRITER="$CASE_DIR/nothing" hook cleaned-up t1 || fail "the hook exited non-zero when the writer is missing"
  hook >/dev/null 2>&1 || fail "the hook exited non-zero with no event"
  pass "a refusing, hung or missing writer never changes the exit code of the script that called the hook"
}

test_the_flag_file_carries_the_writer_settings() {
  make_case env on
  printf '%s\n' 'FM_TASK_BASE_URL=http://127.0.0.1:5001' 'FM_TASK_AUTH=cookie' 'FM_TASK_TOKEN_FILE=/tmp/tok' 'FM_EVIL=1' 'PATH=/nowhere' > "$HOME_DIR/config/task-shadow"
  hook cleaned-up t1 || fail "the hook failed"
  assert_equals 'auth=cookie url=http://127.0.0.1:5001 token=/tmp/tok' "$(cat "$CALLS.env")" "the writer settings"
  pass "the flag file hands only FM_TASK_BASE_URL, FM_TASK_AUTH and FM_TASK_TOKEN_FILE to the writer"
}

test_events_of_the_other_scripts() {
  make_case events on
  hook cleaned-up t1; hook verified t1
  hook held t1 captain "pick a path"; hook held t1 external "waiting for G"; hook held t1 parked "later"
  hook answered t1 released; hook answered t1 closed
  hook deploy-verify t1 abc123 1 https://github.com/o/r/issues/9
  assert_equals "$(printf '%s\n' \
    'event t1 comment --note cleaned up by bin/fm-teardown.sh' \
    'event t1 comment --note verification record complete (bin/fm-verify-close.sh)' \
    'ask t1 --question pick a path --option Decide now --option Decide later --recommendation - --why a captain hold --next-actor owner' \
    'block external t1 --reason waiting for G --next-actor firstmate' \
    'block transient t1 --reason later --next-actor firstmate' \
    'unblock t1' \
    'approve t1' \
    'event t1 deploy --note deploy 1 at abc123: verify ask sent (https://github.com/o/r/issues/9)')" "$(calls)" "the events of the other scripts"
  make_case events-refused on
  FAKE_FAIL=ask hook held t1 captain "queued row" || fail "the hook failed"
  assert_equals "$(printf '%s\n' \
    'ask t1 --question queued row --option Decide now --option Decide later --recommendation - --why a captain hold --next-actor owner' \
    'event t1 comment --note held (captain): queued row')" "$(calls)" "a refused ask leaves a comment"
  make_case events-close on
  FAKE_FAIL=approve FAKE_FAIL_ONCE=1 hook answered t1 closed
  assert_equals "$(printf '%s\n' 'approve t1' 'done t1 --summary closed by the old source --changed-files - --verification - --residual-risk -' 'approve t1')" "$(calls)" "approve of a task the record holds running"
  pass "cleaned-up, verified, held, answered and deploy-verify become the writer commands the header names"
}

test_backlog_verbs() {
  make_case backlog on
  hook backlog "done" t1; hook backlog reopen t1; hook backlog hold t1 external "waiting"; hook backlog hold t1 captain "a question"; hook backlog unhold t1
  assert_equals "$(printf '%s\n' \
    'approve t1' \
    'event t1 comment --note backlog row reopened' \
    'block external t1 --reason waiting --next-actor firstmate' \
    'unblock t1')" "$(calls)" "backlog verbs (a captain hold is left to fm-captain-hold)"
  pass "backlog verbs: done, reopen, hold and unhold; a captain hold is left to bin/fm-captain-hold.sh"
}

test_flag_absent_writes_nothing
test_dispatched_creates_assigns_and_starts
test_status_lines_map_to_writer_commands
test_working_after_a_block_unblocks_and_restarts
test_the_hook_never_fails_the_script
test_the_flag_file_carries_the_writer_settings
test_events_of_the_other_scripts
test_backlog_verbs

# ---- mutation proofs: remove one rule of the hook, the case guarding it goes red ------------------------------

MHOOK="$TMP_ROOT/mhook.sh"
mutate_hook() {  # <label> <case function> <exact source text> <replacement>
  cp "$ROOT/bin/fm-task-shadow.sh" "$MHOOK"
  S="$3" R="$4" perl -0pi -e 's/\Q$ENV{S}\E/$ENV{R}/' "$MHOOK"
  cmp -s "$ROOT/bin/fm-task-shadow.sh" "$MHOOK" && fail "mutation '$1' changed nothing"
  bash -n "$MHOOK" 2>/dev/null || fail "mutation '$1' is not valid shell"
  if ( HOOK="$MHOOK"; "$2" ) >/dev/null 2>&1; then
    fail "removing the rule '$1' left $2 green"
  fi
  pass "rule '$1' is needed: $2 goes red without it"
}

mutate_hook 'the flag file switches the hook on' test_flag_absent_writes_nothing '[ -e "$FLAG" ] || exit 0' ':'
mutate_hook 'every call carries a stable key' test_dispatched_creates_assigns_and_starts '--key "shadow:$TASK:$suffix" ' ''
mutate_hook 'the title comes from the backlog row' test_dispatched_creates_assigns_and_starts 'row=${row#*" - "}' 'row=$TASK'
mutate_hook 'only the last status line is read' test_status_lines_map_to_writer_commands "tail -n 1)" "tail -n 2 | head -n 1)"
mutate_hook 'a done line carries its PR' test_status_lines_map_to_writer_commands '--pr-url "$url")' ')'
mutate_hook 'a refused working line is retried after unblock and start' test_working_after_a_block_unblocks_and_restarts '|| { w "status-$key-unblock" unblock "$TASK" &&' '|| { false &&'
mutate_hook 'a hung writer is cut off' test_the_hook_never_fails_the_script 'run=(timeout "$TIMEOUT" "${run[@]}")' ':'
mutate_hook 'the hook always exits 0' test_the_hook_never_fails_the_script $'esac\nexit 0' $'esac\nexit $?'
mutate_hook 'the flag file hands the writer its settings' test_the_flag_file_carries_the_writer_settings 'export "${line?}"' ':'
mutate_hook 'the flag file hands over only the writer settings' test_the_flag_file_carries_the_writer_settings 'FM_TASK_BASE_URL=*|FM_TASK_AUTH=*|FM_TASK_TOKEN_FILE=*' '*=*'
mutate_hook 'a captain hold is an ask for the owner' test_events_of_the_other_scripts '--why '"'"'a captain hold'"'"' --next-actor owner' '--why '"'"'a captain hold'"'"''
mutate_hook 'a refused hold leaves a comment' test_events_of_the_other_scripts '|| w "hold-$key-comment" event' '|| : event'
mutate_hook 'a close goes through done when the record holds the task running' test_events_of_the_other_scripts 'w "$1-done" "done" "$TASK" --summary "closed by the old source" --changed-files - --verification - --residual-risk - || return 1' 'return 1'
mutate_hook 'a captain hold in the backlog is left to fm-captain-hold' test_backlog_verbs '[ "${3:-}" = captain ] || ' ''
pass 'every rule of the hook has a red mutation proof'
