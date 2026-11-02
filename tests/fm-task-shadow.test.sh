#!/usr/bin/env bash
# tests/fm-task-shadow.test.sh - the task contract in shadow (spec huynhtandat223/cfw-modules#1675, T3, firstmate#176).
#
# The hook bin/fm-task-shadow.sh is driven with a fake writer that records its arguments, then each state script that
# calls the hook is driven for real (a temp home, a fake tmux) with the same fake writer. A script's case goes red when
# its hook call is removed: the mutation proofs at the end copy bin/, delete that one call and run the case again.
# The real run against Dev 5001 on probe rows is recorded with the delivery, not repeated here.
# shellcheck disable=SC2016 # mutation proofs pass literal source patterns to perl
set -u

# shellcheck source=tests/verify-gate-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/verify-gate-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-task-shadow)
vg_install_gh "$TMP_ROOT/gh"

# ---- the fake writer ----------------------------------------------------------

mk_writer() {  # <dir>: a fake bin/fm-task.sh that records one line per call
  cat > "$1/fake-writer" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = show ]; then printf '{"state":"%s","lastSeq":%s}\n' "${FAKE_STATE:-running}" "${FAKE_SEQ:-0}"; exit 0; fi
# a call matching $FAKE_LATE is recorded 1.5 s late, once, as an API that answers late
case "$*" in *"${FAKE_LATE:-@none@}"*) [ -e "$FAKE_CALLS.late" ] || { : > "$FAKE_CALLS.late"; sleep 1.5; } ;; esac
printf '%s\n' "$*" >> "$FAKE_CALLS"
printf 'auth=%s url=%s token=%s\n' "${FM_TASK_AUTH:-}" "${FM_TASK_BASE_URL:-}" "${FM_TASK_TOKEN_FILE:-}" >> "$FAKE_CALLS.env"
[ -z "${FAKE_HANG:-}" ] || sleep "$FAKE_HANG"
if [ -n "${FAKE_FAIL:-}" ]; then
  case "$*" in
    *"$FAKE_FAIL"*)
      if [ -z "${FAKE_FAIL_ONCE:-}" ] || [ ! -e "$FAKE_CALLS.failed" ]; then
        : > "$FAKE_CALLS.failed"
        echo 'refused by the writer' >&2
        exit "${FAKE_FAIL_CODE:-5}"
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
  : > "$CALLS"; : > "$CALLS.env"; rm -f "$CALLS.failed" "$CALLS.late"
  [ "$2" = off ] || : > "$HOME_DIR/config/task-shadow"
}

hook() {  # <hook args...>: run the hook in the case home
  env FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_TASK_SHADOW_WRITER="$WRITER" FAKE_CALLS="$CALLS" "${HOOK:-$ROOT/bin/fm-task-shadow.sh}" "$@"
}

calls() {  # the recorded writer calls without the key, actor and role every call carries, with a spawn generation as G
  sed -E 's/ --key [^ ]* --actor shadow --role system$//; s/ --generation s[0-9]+\.[0-9]+\.[0-9]+/ --generation G/' "$CALLS"
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
  # the hook reads the title through bin/fm-tasks-axi.sh show, so the fixture is a real tasks-axi backlog
  fm_test_tasks_toml "$HOME_DIR/.tasks.toml"
  printf '%s\n' '## In flight' '' '- [ ] t1 - Build the thing https://github.com/o/r/issues/5 (repo: r) (kind: ship) (since 2026-10-25)' '  note' '' '## Queued' '' '## Done' > "$HOME_DIR/data/backlog.md"
  hook dispatched t1 ship r claude || fail "the hook failed"
  assert_equals "$(printf '%s\n' \
    'create t1 --title Build the thing --kind ship --repo r' \
    'assign t1 --to t1' \
    'start t1')" "$(calls)" "dispatched calls"
  assert_equals "$(printf '%s\n' shadow:t1:create shadow:t1:assign shadow:t1:start)" "$(keys)" "dispatched keys"
  assert_contains "$(cat "$HOME_DIR/state/task-shadow.log")" " t1 dispatched create rc=0" "the writer call is logged"
  hook dispatched t1 scout r claude >/dev/null
  assert_equals "$(printf '%s\n' shadow:t1:create shadow:t1:assign shadow:t1:start shadow:t1:create shadow:t1:assign shadow:t1:start)" "$(keys)" "a repeated hook repeats the same keys"
  make_case dispatched-other on
  hook dispatched t2 secondmate-x "" claude || fail "the hook failed"
  assert_equals "$(printf '%s\n' 'create t2 --title t2 --kind other' 'assign t2 --to t2' 'start t2')" "$(calls)" "an unknown kind and no backlog row"
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
  FAKE_STATE=blocked FAKE_FAIL=heartbeat FAKE_FAIL_ONCE=1 hook status "$HOME_DIR/config" "$HOME_DIR/state/t1.status" || fail "the hook failed"
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

test_step_events() {
  make_case steps on
  hook step-start t1 s1.2.3 pi gpt-6 high acct-a; hook step-start t1 s1.2.3 claude opus; hook step-end t1 s1.2.3 cleanup
  assert_equals "$(printf '%s\n' \
    'step t1 start --generation G --harness pi --model gpt-6 --effort high --account acct-a' \
    'step t1 start --generation G --harness claude --model opus' \
    'step t1 end --generation G --reason cleanup')" "$(calls)" "the step events"
  assert_contains "$(cat "$CALLS")" "--key shadow:t1:step-start-s1.2.3 " "a step start is keyed by its spawn generation"
  pass "step-start and step-end become the writer's step calls, keyed by the spawn generation"
}

test_events_of_the_other_scripts() {
  make_case events on
  hook cleaned-up t1; hook verified t1
  hook held t1 captain "pick a path"; hook held t1 external "waiting for G"; hook held t1 parked "later"
  hook held t1 external "fm-hold-v1:$(printf '%s' 'an encoded reason' | base64 -w0)"
  hook answered t1 released; hook answered t1 closed
  hook deploy-verify t1 abc123 1 https://github.com/o/r/issues/9
  assert_equals "$(printf '%s\n' \
    'event t1 comment --note cleaned up by bin/fm-teardown.sh' \
    'event t1 comment --note verification record complete (bin/fm-verify-close.sh)' \
    'ask t1 --question pick a path --option Decide now --option Decide later --recommendation - --why a captain hold --next-actor owner' \
    'block external t1 --reason waiting for G --next-actor firstmate' \
    'block transient t1 --reason later --next-actor firstmate' \
    'block external t1 --reason an encoded reason --next-actor firstmate' \
    'unblock t1' \
    'done t1 --summary closed by the old source --changed-files - --verification - --residual-risk -' \
    'approve t1' \
    'event t1 deploy --note deploy 1 at abc123: verify ask sent (https://github.com/o/r/issues/9)')" "$(calls)" "the events of the other scripts"
  make_case events-refused on
  FAKE_FAIL=ask hook held t1 captain "queued row" || fail "the hook failed"
  assert_equals "$(printf '%s\n' \
    'ask t1 --question queued row --option Decide now --option Decide later --recommendation - --why a captain hold --next-actor owner' \
    'event t1 comment --note held (captain): queued row')" "$(calls)" "a refused ask leaves a comment"
  make_case events-release-twice on
  FAKE_SEQ=5 hook answered t1 released; FAKE_SEQ=5 hook answered t1 released; FAKE_SEQ=9 hook answered t1 released
  assert_equals "$(printf '%s\n' 'unblock t1 --key shadow:t1:answered-released-5' 'unblock t1 --key shadow:t1:answered-released-5' 'unblock t1 --key shadow:t1:answered-released-9')" \
    "$(sed 's/ --actor shadow --role system//' "$CALLS")" "a replayed release keeps its key and a later hold's release writes again"
  make_case events-close on
  hook answered t1 closed
  assert_equals "$(printf '%s\n' 'done t1 --summary closed by the old source --changed-files - --verification - --residual-risk -' 'approve t1')" "$(calls)" "approve of a task the record holds running"
  pass "cleaned-up, verified, held, answered and deploy-verify become the writer commands the header names"
}

# A task begun after T5 ('record: rows' in firstmate's record) is verified on check rows, which deploy-verify writes
# itself: a verification-pending hold leaves such a task as it is while the record holds it in review.
test_rows_task_hold_keeps_review() {
  make_case rows-task on
  mkdir -p "$HOME_DIR/data/t1" "$HOME_DIR/data/t2"
  printf 'surface: user-visible\nissue: %s\nrecord: rows\n' "$VG_ISSUE" > "$HOME_DIR/data/t1/verify.md"
  printf 'surface: user-visible\nissue: %s\n' "$VG_ISSUE" > "$HOME_DIR/data/t2/verify.md"
  FAKE_STATE=review hook held t1 external 'verification pending: A1@1440 is pending'
  FAKE_STATE=review hook held t2 external 'verification pending: A1@1440 is pending'
  assert_equals "$(printf '%s\n' \
    'changes t2 --note old source holds the task' \
    'assign t2 --to t2' \
    'start t2' \
    'done t2 --summary verification pending: A1@1440 is pending --changed-files - --verification old source verification pending --residual-risk - --next-actor tester')" \
    "$(calls)" "a rows task and a task begun before T5"
  pass "a task begun after T5 keeps its review on a verification-pending hold"
}

# ---- the state scripts, driven for real ------------------------------------------

make_fakebin() {  # <dir>
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
window_file="$(dirname "$0")/.spawn-window"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n' ;;
  list-windows) [ ! -s "$window_file" ] || cat "$window_file" ;;
  new-window)
    name=
    previous=
    for arg in "$@"; do
      [ "$previous" = -n ] && name=$arg
      previous=$arg
    done
    printf '%s\n' "$name" > "$window_file"
    ;;
  kill-window) : > "$window_file" ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse no-mistakes
  printf '%s\n' "$fakebin"
}

# Sets CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN TASK WRITER CALLS for one isolated home with the flag on.
make_real_case() {  # <name>
  make_case "$1" on
  PROJ_DIR="$CASE_DIR/sample"
  TASK="$1-t1"
  WT_DIR="$CASE_DIR/wt"
  mkdir -p "$HOME_DIR/data/$TASK" "$HOME_DIR/projects" "$HOME_DIR/user-home"
  printf 'claude\n' > "$HOME_DIR/config/crew-harness"
  printf '%s\n' "$$" > "$HOME_DIR/state/.lock"
  touch "$HOME_DIR/state/.last-watcher-beat"
  fm_git_worktree "$PROJ_DIR" "$WT_DIR" "fm/$TASK"
  cat > "$HOME_DIR/data/$TASK/brief.md" <<EOF
# Task
## Captain's intent
Exercise the task record shadow for $TASK.

## Firstmate spec
Nothing to build.
EOF
  FAKEBIN=$(make_fakebin "$CASE_DIR")
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/view.log"\n' "$CASE_DIR" > "$CASE_DIR/view-writer"
  chmod +x "$CASE_DIR/view-writer"
}

add_row() {  # <task> <title> <kind>: a real backlog row in the case home, so the spawn gate finds its item
  fm_test_tasks_toml "$HOME_DIR/.tasks.toml"
  in_home "$ROOT/bin/fm-tasks-axi.sh" add "$1" "$2" --kind "$3" --repo sample >/dev/null || fail "could not add the backlog row $1"
}

in_home() {  # <command...>: run one real script against the case home, from inside it
  cd "$HOME_DIR" && env -u FM_TRACE_CONTEXT FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    HOME="$HOME_DIR/user-home" CLAUDE_CONFIG_DIR='' \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    FM_TASK_SHADOW_WRITER="$WRITER" FAKE_CALLS="$CALLS" FM_TASK_VIEW_WRITER="$CASE_DIR/view-writer" \
    PATH="$FAKEBIN:$PATH" "$@"
}
SBIN=${SBIN:-$ROOT/bin}  # a mutation proof points this at a copy of bin/

test_spawn_writes_the_record() {
  local out
  make_real_case spawn
  add_row "$TASK" 'Spawn shadow title' ship
  out=$(in_home "$SBIN/fm-spawn.sh" "$TASK" "$PROJ_DIR" --mode local-only --yolo off 2>&1) || fail "spawn failed: $out"
  assert_equals "$(printf '%s\n' "create $TASK --title Spawn shadow title --kind ship --repo sample" "assign $TASK --to $TASK" "start $TASK" "step $TASK start --generation G --harness claude")" "$(calls)" "the record calls of a fresh spawn"
  assert_contains "$(sed -n 4p "$CALLS")" "--generation $(sed -n 's/^spawn_gen=//p' "$HOME_DIR/state/$TASK.meta")" "the step start names the spawn generation of the task record"
  make_real_case spawn-off
  rm -f "$HOME_DIR/config/task-shadow"
  out=$(in_home "$SBIN/fm-spawn.sh" "$TASK" "$PROJ_DIR" --mode local-only --yolo off 2>&1) || fail "spawn failed: $out"
  assert_equals "" "$(cat "$CALLS")" "a spawn with the flag absent writes nothing"
  pass "spawn: a fresh spawn writes create, assign, start and its step start to the record; a home without the flag writes nothing"
}


test_worker_status_command_writes_the_record() {
  local cmd out
  make_real_case status-cmd
  rm -rf "${HOME_DIR:?}/data/$TASK"
  (cd "$HOME_DIR" && in_home "$SBIN/fm-brief.sh" "$TASK" sample --mode no-mistakes >/dev/null) || fail "brief scaffold failed"
  # shellcheck disable=SC2016 # Match literal backticks in the generated brief.
  cmd=$(sed -n '/`echo "{state}/s/.*`\(echo .*\)`.*/\1/p' "$HOME_DIR/data/$TASK/brief.md" | head -1)
  [ -n "$cmd" ] || fail "the brief carries no status command"
  cmd=${cmd//\{state\}/blocked}
  cmd=${cmd//<epoch>/1790000000}
  cmd=${cmd//\{one short line\}/need a token}
  # a worker runs the command in a plain shell with no firstmate environment
  out=$(env -i PATH="$PATH" HOME="$HOME_DIR/user-home" FM_TASK_SHADOW_WRITER="$WRITER" FAKE_CALLS="$CALLS" bash -c "$cmd" 2>&1) || fail "the worker status command failed: $out"
  assert_equals "blocked [at=1790000000]: need a token" "$(cat "$HOME_DIR/state/$TASK.status")" "status log"
  assert_equals "block transient $TASK --reason need a token --next-actor firstmate" "$(calls)" "the record call right after the append"
  rm -f "$HOME_DIR/config/task-shadow"; : > "$CALLS"
  out=$(env -i PATH="$PATH" HOME="$HOME_DIR/user-home" FM_TASK_SHADOW_WRITER="$WRITER" FAKE_CALLS="$CALLS" bash -c "$cmd" 2>&1) || fail "the worker status command failed without the flag: $out"
  assert_equals "" "$(cat "$CALLS")" "a status command with the flag absent writes nothing to the record"
  pass "status command: a worker's status line reaches the record at once, and not at all without the flag"
}

test_teardown_writes_the_record() {
  local out
  make_real_case teardown
  add_row "$TASK" 'Teardown shadow title' ship
  out=$(in_home "$SBIN/fm-spawn.sh" "$TASK" "$PROJ_DIR" --mode local-only --yolo off 2>&1) || fail "spawn failed: $out"
  : > "$CALLS"
  printf 'landed\n' > "$WT_DIR/landed.txt"
  git -C "$WT_DIR" add landed.txt
  git -C "$WT_DIR" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm 'landed'
  out=$(in_home "$SBIN/fm-merge-local.sh" "$TASK" 2>&1) || fail "local merge failed: $out"
  : > "$CALLS"; : > "$CASE_DIR/view.log"
  out=$(in_home "$SBIN/fm-teardown.sh" "$TASK" 2>&1) || fail "teardown failed: $out"
  assert_equals "" "$(cat "$CASE_DIR/view.log")" "the backlog close ran a backlog view sync (retired with the cfw5001 backend)"
  assert_contains "$(calls)" "event $TASK comment --note cleaned up by bin/fm-teardown.sh" "teardown writes its cleanup to the record"
  assert_contains "$(calls)" "step $TASK end --generation G --reason cleanup" "teardown ends the running step of its incarnation"
  case "$(calls)" in *"approve $TASK"*) fail "the backlog close still reached the record through the retired backlog hook" ;; esac
  pass "teardown: the cleanup reaches the record, and the backlog close runs no view sync or backlog hook"
}

test_verify_close_writes_the_record() {
  local out
  make_real_case verify-close
  add_row "$TASK" 'Verify shadow title' ship
  in_home "$ROOT/bin/fm-tasks-axi.sh" hold "$TASK" --reason "$(printf 'fm-hold-v1:%s' "$(printf '%s' 'verification pending: A2 is pending' | base64 -w0)")" --kind external >/dev/null \
    || fail "could not hold the row"
  vg_write_records "$HOME_DIR" "$TASK"
  : > "$CALLS"
  out=$(in_home "$SBIN/fm-verify-close.sh" "$TASK" 2>&1) || fail "verify-close failed: $out"
  assert_contains "$(calls)" "event $TASK comment --note verification record complete (bin/fm-verify-close.sh)" "verify-close writes its close to the record"
  case "$(calls)" in *"approve $TASK"*) fail "the backlog close still reached the record through the retired backlog hook" ;; esac
  pass "verify-close: the verified close reaches the record, with no retired backlog hook"
}

test_captain_hold_writes_the_record() {
  local out
  make_real_case captain-hold
  fm_test_tasks_toml "$HOME_DIR/.tasks.toml"
  printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$HOME_DIR/data/backlog.md"
  out=$(in_home "$SBIN/fm-captain-hold.sh" hold "$TASK" --title 'Pick a path' --reason 'which path do we take?' 2>&1) || fail "captain hold failed: $out"
  assert_equals "ask $TASK --question which path do we take? --option Decide now --option Decide later --recommendation - --why a captain hold --next-actor owner" "$(calls)" "the hold reaches the record"
  assert_equals "$TASK" "$out" "the hold still prints the task id"
  printf 'Take the first path.\n' > "$CASE_DIR/decision.md"
  : > "$CALLS"
  out=$(in_home "$SBIN/fm-captain-hold.sh" answer "$TASK" --decision-file "$CASE_DIR/decision.md" 2>&1) || fail "captain answer failed: $out"
  assert_equals "$(printf '%s\n' "done $TASK --summary closed by the old source --changed-files - --verification - --residual-risk -" "approve $TASK")" "$(calls)" "the answer closes the task in the record"
  make_real_case captain-hold-release
  fm_test_tasks_toml "$HOME_DIR/.tasks.toml"
  printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$HOME_DIR/data/backlog.md"
  in_home "$SBIN/fm-captain-hold.sh" hold "$TASK" --title 'Gate' --reason 'may we proceed?' >/dev/null || fail "captain hold failed"
  printf 'Proceed.\n' > "$CASE_DIR/decision.md"
  : > "$CALLS"
  out=$(in_home "$SBIN/fm-captain-hold.sh" answer "$TASK" --decision-file "$CASE_DIR/decision.md" --release 2>&1) || fail "captain release failed: $out"
  assert_equals "unblock $TASK" "$(calls)" "a released hold unblocks the task in the record"
  pass "captain hold: the hold, the closing answer and the release reach the record"
}

# ---- the watcher's step liveness, driven for real --------------------------------

# A fake tmux and ps: every window named in <dir>/windows has a claude in its foreground, a window not named is gone.
make_live_fakebin() {  # <dir>
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) cat "$FAKE_WINDOWS" ;;
  # a pane that changes on every poll is working, so no stale wake ends the watcher; with $FAKE_SLOW each read takes 4 s
  capture-pane) [ ! -e "${FAKE_SLOW:-/nonexistent}" ] || { : > "$FAKE_SLOW.started"; sleep 4; }; date +%s%N ;;
  display-message) case "$*" in *pane_tty*) printf '/dev/pts/fake\n' ;; *) printf 'claude\n' ;; esac ;;
esac
exit 0
SH
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in *pts/fake*) printf '1 1 1 claude\n' ;; *) exec /bin/ps "$@" ;; esac
SH
  chmod +x "$fakebin/tmux" "$fakebin/ps"
  printf '%s\n' "$fakebin"
}

start_watcher() {  # runs bin/fm-watch.sh in the case home at a 1 s poll and a 1 s step pass; sets WATCHER
  env FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_TASK_SHADOW_WRITER="$WRITER" FAKE_CALLS="$CALLS" FAKE_WINDOWS="$CASE_DIR/windows" FAKE_SLOW="$CASE_DIR/slow" \
    PATH="$FAKEBIN:$PATH" FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL="${CHECK_EVERY:-999999}" FM_HEARTBEAT=999999 FM_TASK_STEP_EVERY=1 \
    "${SBIN:-$ROOT/bin}/fm-watch.sh" > "$CASE_DIR/watch.out" 2>&1 &
  WATCHER=$!
}
stop_watcher() { kill -TERM "$WATCHER" 2>/dev/null || true; wait "$WATCHER" 2>/dev/null || true; }

wait_count() {  # <seconds> <extended regex> <n>: wait until n recorded writer calls match
  local tries=$(($1 * 10))
  while [ "$tries" -gt 0 ]; do
    [ "$(grep -Ec -- "$2" "$CALLS" 2>/dev/null)" -ge "$3" ] && return 0
    sleep 0.1; tries=$((tries - 1))
  done
  return 1
}

wait_calls() {  # <seconds> <extended regex>: wait until a recorded writer call matches
  local tries=$(($1 * 10))
  while [ "$tries" -gt 0 ]; do
    grep -Eq -- "$2" "$CALLS" 2>/dev/null && return 0
    sleep 0.1; tries=$((tries - 1))
  done
  return 1
}

# Tester kdb-d1 D2: a stopped worker's dot stayed alive for minutes, first because the watcher wrote one task's liveness
# per pass, then because the step pass lived inside the watcher, which does not run while firstmate handles a wake.
# bin/fm-task-step-loop.sh is one loop per home beside the watcher: every task's liveness reaches the record within one
# pass with no watcher running, the writer runs only on a change, across restarts.

loop() {  # <mode>: run bin/fm-task-step-loop.sh in the case home at a 1 s interval
  env FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_TASK_SHADOW_WRITER="$WRITER" FAKE_CALLS="$CALLS" FAKE_WINDOWS="$CASE_DIR/windows" \
    PATH="$FAKEBIN:$PATH" FM_TASK_STEP_EVERY=1 "${SBIN:-$ROOT/bin}/fm-task-step-loop.sh" "$1"
}
loop_pid() { cat "$HOME_DIR/state/.task-step-loop.lock/pid" 2>/dev/null || true; }

# A live session: a process named in state/.lock, bounded so an escaped one ends on its own. Sets SESSION.
hold_session() {
  sleep "$FM_TEST_STUB_MAX_BLOCK_SECONDS" &
  SESSION=$!
  printf '%s\n' "$SESSION" > "$HOME_DIR/state/.lock"
}
end_session() { kill "$SESSION" 2>/dev/null || true; wait "$SESSION" 2>/dev/null || true; }
fm_pid_alive_test() { kill -0 "$1" 2>/dev/null; }

make_step_case() {  # <name>: five tasks, each with a live window
  local t
  make_case "$1" on
  FAKEBIN=$(make_live_fakebin "$CASE_DIR")
  printf '%s\n' w1 w2 w3 w4 w5 > "$CASE_DIR/windows"
  for t in 1 2 3 4 5; do printf 'window=fmses:w%s\nharness=claude\nspawn_gen=g%s\n' "$t" "$t" > "$HOME_DIR/state/t$t.meta"; done
  hold_session
}

test_step_loop_writes_every_task_liveness() {
  local steps first out
  make_step_case step-loop
  # t3's first write gets no answer from the API (3), so the next pass tries it again
  out=$(FAKE_FAIL='step t3' FAKE_FAIL_ONCE=1 FAKE_FAIL_CODE=3 loop start)
  assert_contains "$out" "task-step-loop: started pid=" "the first start starts the loop"
  first=$(loop_pid)
  out=$(loop start)
  assert_equals "task-step-loop: running pid=$first" "$out" "a second start keeps the one loop of the home"
  wait_calls 3 '^step t5 alive' || { loop stop; end_session; fail "the fifth task's liveness did not reach the record within one pass: $(cat "$CALLS")"; }
  wait_count 3 '^step t3 ' 2 || true
  steps=$(grep -c '^step ' "$CALLS")
  [ "$steps" -eq 6 ] || { loop stop; end_session; fail "five tasks and one unanswered call should make six step calls, got $steps: $(cat "$CALLS")"; }
  # no watcher runs in this home: a pane closed now still stops its dot within one interval
  printf '%s\n' w1 w3 w4 w5 > "$CASE_DIR/windows"
  wait_calls 3 '^step t2 dead --generation g2$' || { loop stop; end_session; fail "a worker gone did not stop its dot within 3 s with no watcher: $(cat "$CALLS")"; }
  sleep 2
  out=$(loop stop)
  assert_equals "task-step-loop: stopped pid=$first" "$out" "stop ends the loop"
  assert_absent "$HOME_DIR/state/.task-step-loop.lock" "a stopped loop releases its lock"
  assert_equals "$(printf '%s\n' 'step t1 alive --generation g1' 'step t2 alive --generation g2' 'step t3 alive --generation g3' 'step t4 alive --generation g4' 'step t5 alive --generation g5' 'step t3 alive --generation g3' 'step t2 dead --generation g2')" \
    "$(grep '^step ' "$CALLS")" "the writer runs once per task and once per change, and again only after no answer"
  : > "$CALLS"; rm -f "$CALLS.failed"
  # t1 relaunched as g1b, and the writer refuses its report by a rule (5): a refusal is settled, not tried every pass
  sed -i.bak 's/^spawn_gen=g1$/spawn_gen=g1b/' "$HOME_DIR/state/t1.meta"
  FAKE_FAIL='step t1' loop start >/dev/null
  wait_calls 3 '^step t1 ' || { loop stop; end_session; fail "the restarted loop did not write t1: $(cat "$CALLS")"; }
  sleep 3
  loop stop >/dev/null
  end_session
  assert_equals 'step t1 alive --generation g1b' "$(grep '^step ' "$CALLS")" "a restarted loop writes only the changed task, and a refused write once"
  pass "step loop: one loop per home writes every task's liveness within one pass with no watcher running, once per change, across restarts; no answer is tried again, a refusal is not"
}

# The loop ends with the session: a home whose session lock names a dead pid, or has none, runs no loop.
test_step_loop_ends_with_the_session() {
  local pid t=0
  make_step_case step-loop-session
  loop start >/dev/null
  pid=$(loop_pid)

  fm_pid_alive_test "$pid" || { end_session; fail "the loop did not start"; }
  end_session
  while fm_pid_alive_test "$pid" && [ "$t" -lt 40 ]; do sleep 0.1; t=$((t + 1)); done
  fm_pid_alive_test "$pid" && { loop stop; fail "the loop outlived its session by 4 s"; }
  assert_absent "$HOME_DIR/state/.task-step-loop.lock" "a loop that ended with its session releases its lock"
  assert_equals "task-step-loop: off" "$(loop start)" "no loop starts while the session lock names a dead pid"
  rm -f "$HOME_DIR/state/.lock"
  assert_equals "task-step-loop: off" "$(loop start)" "no loop starts without a session lock"
  pass "step loop: the loop ends when the home's session lock goes away, and none starts without one"
}

# PR 264 review: a stop killed only the loop shell, so its in-flight writer could commit alive after a successor wrote
# dead, and the dot stayed alive. A stop now waits for the in-flight write before the lock is free for a successor.
test_step_loop_stop_waits_for_the_write() {
  local t=0
  make_step_case step-loop-stop
  printf '%s\n' w1 > "$CASE_DIR/windows"
  rm -f "$HOME_DIR"/state/t[2-5].meta
  # the first write of t1 is recorded only after 1.5 s, as an API that answers late
  FAKE_LATE='step t1 alive' loop start >/dev/null
  while [ ! -e "$CALLS.late" ] && [ "$t" -lt 50 ]; do sleep 0.1; t=$((t + 1)); done
  [ -e "$CALLS.late" ] || { loop stop; end_session; fail "the loop never wrote t1: $(cat "$CALLS")"; }
  loop stop >/dev/null
  : > "$CASE_DIR/windows"
  loop start >/dev/null
  wait_calls 4 '^step t1 dead' || { loop stop; end_session; fail "the successor did not write t1 dead: $(cat "$CALLS")"; }
  sleep 2
  loop stop >/dev/null
  end_session
  assert_equals "$(printf '%s\n' 'step t1 alive --generation g1' 'step t1 dead --generation g1')" "$(grep '^step ' "$CALLS")" \
    "the stopped loop's late write lands before the successor's"
  pass "step loop: a stop during a write waits for it, so a successor's write is the last one"
}

# The arm path starts the loop, and the watcher's delivery calls carry the writer settings of the flag file.
test_arm_starts_the_step_loop() {
  local t=0 arm
  make_step_case step-loop-arm
  printf 'FM_TASK_BASE_URL=http://task.example\n' > "$HOME_DIR/config/task-shadow"
  fm_test_track_watcher_state "$HOME_DIR/state"
  env FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_TASK_SHADOW_WRITER="$WRITER" FAKE_CALLS="$CALLS" FAKE_WINDOWS="$CASE_DIR/windows" \
    PATH="$FAKEBIN:$PATH" FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_TASK_STEP_EVERY=1 \
    FM_WATCH_HANDLING_SUCCESSOR=1 "${SBIN:-$ROOT/bin}/fm-watch-arm.sh" > "$CASE_DIR/arm.out" 2>&1 &
  arm=$!
  while [ -z "$(loop_pid)" ] && [ "$t" -lt 50 ]; do sleep 0.1; t=$((t + 1)); done
  wait_calls 15 '^deliver t5 ' || true
  kill -TERM "$arm" 2>/dev/null || true; wait "$arm" 2>/dev/null || true
  [ -n "$(loop_pid)" ] || { end_session; fail "the arm started no step loop: $(cat "$CASE_DIR/arm.out")"; }
  wait_calls 3 '^step t5 alive' || { loop stop; end_session; fail "the loop the arm started wrote nothing: $(cat "$CALLS")"; }
  # the loop outlives the watcher: a pane closed after the arm and its watcher stopped still stops its dot
  printf '%s\n' w1 w2 w3 w4 > "$CASE_DIR/windows"
  wait_calls 3 '^step t5 dead' || { loop stop; end_session; fail "a pane closed with no watcher running did not stop its dot: $(cat "$CALLS")"; }
  loop stop >/dev/null
  end_session
  for t in 1 2 3 4 5; do grep -q "^deliver t$t --consumer" "$CALLS" || fail "delivery skipped t$t: $(cat "$CALLS")"; done
  [ "$(paste -d ' ' "$CALLS" "$CALLS.env" | grep '^deliver ' | grep -vc 'url=http://task.example')" -eq 0 ] \
    || fail "a delivery call ran without the flag file's settings: $(paste -d ' ' "$CALLS" "$CALLS.env" | grep '^deliver ')"
  pass "arm: every arm starts the home's step loop, which outlives the watcher; delivery visits every task with the flag file's settings"
}

test_step_loop_writes_every_task_liveness
test_step_loop_ends_with_the_session
test_step_loop_stop_waits_for_the_write
test_arm_starts_the_step_loop
test_flag_absent_writes_nothing
test_dispatched_creates_assigns_and_starts
test_status_lines_map_to_writer_commands
test_working_after_a_block_unblocks_and_restarts
test_the_hook_never_fails_the_script
test_the_flag_file_carries_the_writer_settings
test_events_of_the_other_scripts
test_step_events
test_rows_task_hold_keeps_review
test_spawn_writes_the_record
test_worker_status_command_writes_the_record
test_teardown_writes_the_record
test_verify_close_writes_the_record
test_captain_hold_writes_the_record

# ---- mutation proofs: remove one rule of the hook, the case guarding it goes red ------------------------------

# The hook sources its settings lib from its own directory, so the lib is copied beside the mutated hook, and a
# mutation applies to whichever of the two holds the text.
MHOOK="$TMP_ROOT/mhook.sh"
MCONF="$TMP_ROOT/fm-task-shadow-config-lib.sh"
mutate_hook() {  # <label> <case function> <exact source text> <replacement>
  cp "$ROOT/bin/fm-task-shadow.sh" "$MHOOK"
  cp "$ROOT/bin/fm-task-shadow-config-lib.sh" "$MCONF"
  S="$3" R="$4" perl -0pi -e 's/\Q$ENV{S}\E/$ENV{R}/' "$MHOOK" "$MCONF"
  cmp -s "$ROOT/bin/fm-task-shadow.sh" "$MHOOK" && cmp -s "$ROOT/bin/fm-task-shadow-config-lib.sh" "$MCONF" && fail "mutation '$1' changed nothing"
  { bash -n "$MHOOK" && bash -n "$MCONF"; } 2>/dev/null || fail "mutation '$1' is not valid shell"
  if ( HOOK="$MHOOK"; "$2" ) >/dev/null 2>&1; then
    fail "removing the rule '$1' left $2 green"
  fi
  pass "rule '$1' is needed: $2 goes red without it"
}

mutate_hook 'the flag file switches the hook on' test_flag_absent_writes_nothing '[ -e "$FLAG" ] || exit 0' ':'
mutate_hook 'every call carries a stable key' test_dispatched_creates_assigns_and_starts '--key "shadow:$TASK:$suffix" ' ''
mutate_hook 'the title comes from the backlog row' test_dispatched_creates_assigns_and_starts 'title=$(backlog_field title' 'title=$(: title'
mutate_hook 'only the last status line is read' test_status_lines_map_to_writer_commands "tail -n 1)" "tail -n 2 | head -n 1)"
mutate_hook 'a done line carries its PR' test_status_lines_map_to_writer_commands '--pr-url "$url")' ')'
mutate_hook 'a refused working line is retried after unblock and start' test_working_after_a_block_unblocks_and_restarts 'blocked|triage) w "status-$key-unblock" unblock "$TASK" || return 0 ;;' 'blocked|triage) return 0 ;;'
mutate_hook 'a hung writer is cut off' test_the_hook_never_fails_the_script 'run=(timeout "$TIMEOUT" "${run[@]}")' ':'
mutate_hook 'the hook always exits 0' test_the_hook_never_fails_the_script $'esac\nexit 0' $'esac\nexit $?'
mutate_hook 'the flag file hands the writer its settings' test_the_flag_file_carries_the_writer_settings 'export "${line?}"' ':'
mutate_hook 'the flag file hands over only the writer settings' test_the_flag_file_carries_the_writer_settings 'FM_TASK_BASE_URL=*|FM_TASK_AUTH=*|FM_TASK_TOKEN_FILE=*' '*=*'
mutate_hook 'a verification-pending hold keeps a rows task in review' test_rows_task_hold_keeps_review '  if [ "$current" = review ] && rows_task &&' '  if false &&'
mutate_hook 'a captain hold is an ask for the owner' test_events_of_the_other_scripts '--why '"'"'a captain hold'"'"' --next-actor owner' '--why '"'"'a captain hold'"'"''
mutate_hook 'a refused hold leaves a comment' test_events_of_the_other_scripts '|| w "hold-$key-comment" event' '|| : event'
mutate_hook 'a close goes through done when the record holds the task running' test_events_of_the_other_scripts 'w "$1-done" "done" "$TASK" --summary "closed by the old source" --changed-files - --verification - --residual-risk - || return 1' 'return 1'
pass 'every rule of the hook has a red mutation proof'

# ---- mutation proofs for the scripts: delete the one hook call, the script's case goes red ---------------------

MSBIN="$TMP_ROOT/mbin"
mutate_script() {  # <label> <case function> <script> <text of the hook line to delete>
  rm -rf "$MSBIN"
  cp -R "$ROOT/bin" "$MSBIN"
  FRAG="$4" perl -ni -e 'print unless index($_, $ENV{FRAG}) >= 0' "$MSBIN/$3"
  cmp -s "$ROOT/bin/$3" "$MSBIN/$3" && fail "mutation '$1' changed nothing"
  bash -n "$MSBIN/$3" 2>/dev/null || fail "mutation '$1' is not valid shell"
  if ( SBIN="$MSBIN"; "$2" ) >/dev/null 2>&1; then
    fail "removing the hook call '$1' left $2 green"
  fi
  pass "hook call '$1' is needed: $2 goes red without it"
}

mutate_script 'the worker status command writes the record' test_worker_status_command_writes_the_record fm-brief.sh 'fm-task-shadow.sh'
mutate_script 'fm-spawn.sh writes the dispatched task' test_spawn_writes_the_record fm-spawn.sh 'fm-task-shadow.sh" dispatched'
mutate_script 'fm-teardown.sh writes the cleanup' test_teardown_writes_the_record fm-teardown.sh 'fm-task-shadow.sh" cleaned-up'
mutate_script 'fm-spawn.sh starts the workflow step' test_spawn_writes_the_record fm-spawn.sh 'fm-task-shadow.sh" step-start'
mutate_script 'fm-teardown.sh ends the workflow step' test_teardown_writes_the_record fm-teardown.sh 'fm-task-shadow.sh" step-end'
mutate_script 'fm-verify-close.sh writes the verified close' test_verify_close_writes_the_record fm-verify-close.sh 'fm-task-shadow.sh" verified'
mutate_script 'fm-captain-hold.sh writes the hold' test_captain_hold_writes_the_record fm-captain-hold.sh 'shadow_record held'
mutate_script 'fm-captain-hold.sh writes the closing answer' test_captain_hold_writes_the_record fm-captain-hold.sh 'shadow_record answered "$1" closed'
mutate_script 'fm-captain-hold.sh writes the release' test_captain_hold_writes_the_record fm-captain-hold.sh 'shadow_record answered "$1" released'
mutate_script 'fm-watch-arm.sh starts the step loop' test_arm_starts_the_step_loop fm-watch-arm.sh 'fm-task-step-loop.sh" start'
mutate_script 'fm-watch.sh hands delivery the flag settings' test_arm_starts_the_step_loop fm-watch.sh '|| fm_task_shadow_config "$CONFIG/task-shadow"'
mutate_script 'a stop waits for the in-flight write' test_step_loop_stop_waits_for_the_write fm-task-step-loop.sh "trap 'STOP=1' TERM INT HUP"
mutate_script 'an interrupted wait waits again for the write' test_step_loop_stop_waits_for_the_write fm-task-step-loop.sh 'while ! wait "$writer" && kill -0 "$writer"'
mutate_script 'the loop ends with the session' test_step_loop_ends_with_the_session fm-task-step-loop.sh 'case "$FM_LOCK_INSPECT_STATE" in free|stale) return 1 ;; esac'
