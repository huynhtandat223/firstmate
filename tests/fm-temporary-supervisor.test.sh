#!/usr/bin/env bash
# Behavior tests for the temporary-supervisor lifecycle.
#
# A temporary supervisor is one bounded direct report whose worktree IS its own
# firstmate home. bin/fm-supervisor-lib.sh owns that lifecycle; bin/fm-spawn.sh
# --supervisor opens and relaunches it, bin/fm-teardown.sh retires it, and
# bin/fm-primary-scope-lib.sh is what lets the home run its own hooks.
#
# These cases pin the guarantees the design exists for, each through the real
# executable rather than its source: the home is leased and marked but never
# registered as a secondmate, no product project is cloned into it, a relaunch
# comes back to that same home instead of leasing a second one, and cleanup
# refuses while a child record, unlanded work, or the programme report is still
# outstanding.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
BRIEF_WRITER="$ROOT/custom-skills/orchestrator/fm-supervisor-brief.sh"
TMP_ROOT=$(fm_test_tmproot fm-temporary-supervisor)
fm_git_identity

# A fake tmux permissive enough for the whole spawn sequence, plus a fake
# treehouse that records every lease holder it is asked for and returns a
# worktree by removing it. FM_FAKE_PANE_PATH, when set, is what the pane reports
# as its cwd - the child-dispatch case needs that; a supervisor spawn never
# polls for it because its home is resolved before any pane exists.
make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    exit 0
    ;;
esac
case "${1:-}" in
  new-window) printf '@9\n'; exit 0 ;;
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|kill-window|send-keys|set-window-option) exit 0 ;;
esac
exit 0
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  get)
    shift
    holder=
    while [ $# -gt 0 ]; do
      case "$1" in
        --lease-holder) shift; holder=${1:-} ;;
        --lease-holder=*) holder=${1#--lease-holder=} ;;
      esac
      shift
    done
    printf '%s\n' "$holder" >> "$FM_FAKE_LEASE_LOG"
    printf 'leased for %s\n' "$holder" >&2
    printf '%s\n' "$FM_FAKE_TREEHOUSE_HOME"
    exit 0
    ;;
  return)
    shift
    target=
    while [ $# -gt 0 ]; do
      case "$1" in --force) ;; *) target=$1 ;; esac
      shift
    done
    printf 'return %s\n' "$target" >> "$FM_FAKE_LEASE_LOG"
    [ -n "$target" ] && rm -rf -- "$target"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux" "$fakebin/treehouse"
  printf '%s\n' "$fakebin"
}

# One case fixture: a firstmate repo standing in for FM_ROOT, a parent home with
# one project clone, and a detached worktree of that repo standing in for the
# worktree treehouse would hand out under a lease.
make_case() {
  local name=$1 id=$2 dir root parent home fakebin
  dir="$TMP_ROOT/$name"
  root="$dir/firstmate"
  parent="$dir/parent"
  home="$dir/leased-home"
  mkdir -p "$root/bin"
  printf '# Firstmate\n' > "$root/AGENTS.md"
  # The real repo ignores its own operational directories, which is what keeps a
  # supervisor home clean enough for the unlanded-work check to pass.
  printf '%s\n' projects/ state/ data/ config/ > "$root/.gitignore"
  cat > "$root/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$root/bin/fm-guard.sh"
  git -C "$root" init -q
  git -C "$root" add -A
  git -C "$root" commit -qm initial
  git -C "$root" worktree add --detach --quiet "$home" HEAD
  mkdir -p "$parent/data" "$parent/state" "$parent/config" "$parent/projects"
  fm_git_init_commit "$parent/projects/alpha"
  git -C "$parent/projects/alpha" remote add origin "$parent/projects/alpha"
  git -C "$parent/projects/alpha" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  git -C "$parent/projects/alpha" update-ref refs/remotes/origin/main HEAD
  fakebin=$(make_fakebin "$dir")
  : > "$dir/lease.log"
  FM_ROOT_DIR=$root
  PARENT_HOME=$parent
  LEASED_HOME=$home
  FAKEBIN=$fakebin
  LEASE_LOG="$dir/lease.log"
  SUP_ID=$id
  scaffold_brief
}

scaffold_brief() {
  FM_HOME="$PARENT_HOME" FM_ROOT_OVERRIDE="$ROOT" \
    "$BRIEF_WRITER" "$SUP_ID" >/dev/null || fail "could not scaffold the supervisor brief"
}

run_spawn() {
  FM_ROOT_OVERRIDE="$FM_ROOT_DIR" FM_HOME="$PARENT_HOME" \
    FM_STATE_OVERRIDE="$PARENT_HOME/state" FM_DATA_OVERRIDE="$PARENT_HOME/data" \
    FM_PROJECTS_OVERRIDE="$PARENT_HOME/projects" FM_CONFIG_OVERRIDE="$PARENT_HOME/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_TREEHOUSE_HOME="$LEASED_HOME" FM_FAKE_LEASE_LOG="$LEASE_LOG" \
    PATH="$FAKEBIN:$PATH" \
    "$SPAWN" "$@" 2>&1
}

run_teardown() {
  FM_ROOT_OVERRIDE="$FM_ROOT_DIR" FM_HOME="$PARENT_HOME" \
    FM_STATE_OVERRIDE="$PARENT_HOME/state" FM_DATA_OVERRIDE="$PARENT_HOME/data" \
    FM_CONFIG_OVERRIDE="$PARENT_HOME/config" \
    FM_TEARDOWN_GUARD_DONE=1 TMUX="fake,1,0" \
    FM_FAKE_TREEHOUSE_HOME="$LEASED_HOME" FM_FAKE_LEASE_LOG="$LEASE_LOG" \
    PATH="$FAKEBIN:$PATH" \
    "$TEARDOWN" "$@" 2>&1
}

# Mark the programme finished as far as the report and decision inventory go, so
# a case can isolate one refusal at a time.
satisfy_report_and_decisions() {
  mkdir -p "$PARENT_HOME/data/$SUP_ID"
  printf '# programme report\n' > "$PARENT_HOME/data/$SUP_ID/report.md"
  printf 'decisions_reviewed=1\n' >> "$PARENT_HOME/state/$SUP_ID.meta"
}

test_open_leases_a_marked_home_and_registers_nothing() {
  local out status registry_before registry_after
  make_case open-basic prog-open-a1
  printf -- '- other-domain (home: /nowhere)\n' > "$PARENT_HOME/data/secondmates.md"
  registry_before=$(cksum < "$PARENT_HOME/data/secondmates.md")

  out=$(run_spawn "$SUP_ID" --supervisor --harness codex)
  status=$?
  expect_code 0 "$status" "supervisor spawn should succeed (got: $out)"
  assert_contains "$out" "kind=supervisor" "spawn did not report a supervisor"

  assert_grep "kind=supervisor" "$PARENT_HOME/state/$SUP_ID.meta" "meta did not record kind=supervisor"
  assert_grep "home=$LEASED_HOME" "$PARENT_HOME/state/$SUP_ID.meta" "meta did not record the leased home"
  assert_grep "parent_home=$PARENT_HOME" "$PARENT_HOME/state/$SUP_ID.meta" "meta did not record the parent home"
  assert_no_grep "mode=" "$PARENT_HOME/state/$SUP_ID.meta" "a supervisor must record no delivery mode"
  assert_no_grep "yolo=" "$PARENT_HOME/state/$SUP_ID.meta" "a supervisor must record no approval posture"

  [ "$(cat "$LEASED_HOME/.fm-supervisor-home")" = "$SUP_ID" ] \
    || fail "the home carries no matching supervisor identity marker"
  assert_grep "supervisor-$SUP_ID" "$LEASE_LOG" "the home was not leased under this supervisor's holder label"

  registry_after=$(cksum < "$PARENT_HOME/data/secondmates.md")
  [ "$registry_before" = "$registry_after" ] \
    || fail "opening a supervisor modified data/secondmates.md"
  pass "opening a supervisor leases a marked home and touches no secondmate registration"
}

test_open_clones_no_project_into_the_home() {
  local out status
  make_case open-noclone prog-noclone-b2
  out=$(run_spawn "$SUP_ID" --supervisor --harness codex)
  status=$?
  expect_code 0 "$status" "supervisor spawn should succeed (got: $out)"

  [ ! -d "$LEASED_HOME/projects/alpha" ] \
    || fail "the supervisor home received a clone of the parent home's project"
  assert_present "$PARENT_HOME/projects/alpha" "the parent home's clone must survive untouched"
  pass "opening a supervisor clones no product project into its home"
}

test_home_is_a_primary_scope_only_once_marked() {
  local unmarked
  make_case scope-marker prog-scope-c3
  unmarked="$TMP_ROOT/scope-marker/unmarked"
  git -C "$FM_ROOT_DIR" worktree add --detach --quiet "$unmarked" HEAD
  mkdir -p "$unmarked/state" "$LEASED_HOME/state"

  # The predicate every firstmate hook uses to decide whether it is in a genuine
  # primary home. A linked worktree is out of scope until the supervisor marker
  # declares it a home of its own.
  # shellcheck source=bin/fm-primary-scope-lib.sh
  . "$ROOT/bin/fm-primary-scope-lib.sh"
  ! fm_primary_scope_matches "$unmarked" "$unmarked/state" \
    || fail "an unmarked linked worktree must not count as a primary home"
  printf '%s\n' "$SUP_ID" > "$LEASED_HOME/.fm-supervisor-home"
  fm_primary_scope_matches "$LEASED_HOME" "$LEASED_HOME/state" \
    || fail "a marked supervisor home must count as a primary home for its own hooks"
  pass "the supervisor marker is what puts its home in scope for its own hooks"
}

test_relaunch_returns_to_the_same_home() {
  local out status leases
  make_case relaunch prog-relaunch-d4
  out=$(run_spawn "$SUP_ID" --supervisor --harness codex)
  expect_code 0 $? "first spawn should succeed (got: $out)"
  rm -f "$PARENT_HOME/state/.spawn-$SUP_ID.lock"/* 2>/dev/null || true

  out=$(run_spawn "$SUP_ID" --supervisor --harness codex)
  status=$?
  expect_code 0 "$status" "relaunch should succeed (got: $out)"
  assert_grep "home=$LEASED_HOME" "$PARENT_HOME/state/$SUP_ID.meta" "relaunch did not stay in the recorded home"
  leases=$(grep -c "^supervisor-$SUP_ID$" "$LEASE_LOG" || true)
  [ "$leases" = 1 ] || fail "relaunch took $leases leases; it must reuse the one already recorded"
  pass "a relaunch returns to the recorded home instead of leasing a second one"
}

test_relaunch_refuses_when_the_recorded_home_is_gone() {
  local out status
  make_case relaunch-gone prog-gone-e5
  out=$(run_spawn "$SUP_ID" --supervisor --harness codex)
  expect_code 0 $? "first spawn should succeed (got: $out)"
  rm -rf "$LEASED_HOME"

  out=$(run_spawn "$SUP_ID" --supervisor --harness codex)
  status=$?
  [ "$status" -ne 0 ] || fail "relaunch must refuse when the recorded home is gone"
  assert_contains "$out" "$LEASED_HOME" "the refusal must name the recorded home"
  pass "a relaunch refuses rather than silently starting a second home"
}

test_open_refuses_to_reuse_another_task_id() {
  local out status
  make_case id-reuse prog-reuse-f6
  fm_write_meta "$PARENT_HOME/state/$SUP_ID.meta" \
    "window=firstmate:fm-$SUP_ID" "worktree=$LEASED_HOME" "project=$LEASED_HOME" \
    "harness=codex" "kind=ship" "mode=direct-PR" "yolo=off"
  out=$(run_spawn "$SUP_ID" --supervisor --harness codex)
  status=$?
  [ "$status" -ne 0 ] || fail "a supervisor must not adopt an id already recorded as another kind"
  assert_contains "$out" "kind=ship" "the refusal must name the recorded kind"
  pass "opening a supervisor refuses an id already recorded as another kind"
}

test_open_refuses_a_delivery_contract_and_a_project_argument() {
  local out status
  make_case refusals prog-refuse-g7
  out=$(run_spawn "$SUP_ID" --supervisor --harness codex --mode direct-PR --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a supervisor spawn must refuse a delivery mode"
  assert_contains "$out" "--mode applies only to ship spawns" "unexpected mode refusal text"
  out=$(run_spawn "$SUP_ID" "$PARENT_HOME/projects/alpha" --supervisor --harness codex)
  status=$?
  [ "$status" -ne 0 ] || fail "a supervisor spawn must refuse a project positional"
  assert_contains "$out" "takes only <task-id>" "unexpected positional refusal text"
  pass "opening a supervisor refuses a delivery contract and a project argument"
}

test_child_dispatch_lands_in_the_supervisor_home() {
  local out status child=child-ship-h8 child_wt
  make_case child-dispatch prog-child-h8
  out=$(run_spawn "$SUP_ID" --supervisor --harness codex)
  expect_code 0 $? "supervisor spawn should succeed (got: $out)"

  child_wt="$TMP_ROOT/child-dispatch/child-wt"
  git -C "$PARENT_HOME/projects/alpha" worktree add --quiet -b "fm/$child" "$child_wt"
  mkdir -p "$LEASED_HOME/data/$child"
  printf 'Delivery contract: mode=direct-PR\n' > "$LEASED_HOME/data/$child/brief.md"

  # The supervisor dispatches from its OWN home, allocating from the parent
  # home's clone by absolute path.
  out=$(FM_ROOT_OVERRIDE="$FM_ROOT_DIR" FM_HOME="$LEASED_HOME" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_FAKE_PANE_PATH="$child_wt" \
    FM_FAKE_TREEHOUSE_HOME="$LEASED_HOME" FM_FAKE_LEASE_LOG="$LEASE_LOG" \
    PATH="$FAKEBIN:$PATH" \
    "$SPAWN" "$child" "$PARENT_HOME/projects/alpha" --mode direct-PR --yolo off --harness codex 2>&1)
  status=$?
  expect_code 0 "$status" "the supervisor's child dispatch should succeed (got: $out)"

  assert_present "$LEASED_HOME/state/$child.meta" "the child record must live in the supervisor's own home"
  assert_absent "$PARENT_HOME/state/$child.meta" "the parent home must not hold the child's record"
  assert_grep "worktree=$child_wt" "$LEASED_HOME/state/$child.meta" "the child did not get its own isolated copy"
  pass "a supervisor dispatches ordinary workers into its own home from the parent's clone"
}

test_cleanup_refuses_while_a_child_record_remains() {
  local out status
  make_case cleanup-child prog-cleanup-i9
  out=$(run_spawn "$SUP_ID" --supervisor --harness codex)
  expect_code 0 $? "supervisor spawn should succeed (got: $out)"
  satisfy_report_and_decisions
  mkdir -p "$LEASED_HOME/state"
  fm_write_meta "$LEASED_HOME/state/leftover-worker.meta" \
    "window=firstmate:fm-leftover-worker" "worktree=$LEASED_HOME" "harness=codex" "kind=ship"

  out=$(run_teardown "$SUP_ID")
  status=$?
  [ "$status" -ne 0 ] || fail "cleanup must refuse while a child worker record remains"
  assert_contains "$out" "still has in-flight work" "unexpected child-work refusal text"
  assert_present "$LEASED_HOME" "a refused cleanup must leave the home intact"
  pass "cleanup refuses while the supervisor still holds a child worker record"
}

test_cleanup_refuses_without_the_programme_report() {
  local out status
  make_case cleanup-report prog-cleanup-j1
  out=$(run_spawn "$SUP_ID" --supervisor --harness codex)
  expect_code 0 $? "supervisor spawn should succeed (got: $out)"

  out=$(run_teardown "$SUP_ID")
  status=$?
  [ "$status" -ne 0 ] || fail "cleanup must refuse without the programme report"
  assert_contains "$out" "has no report at" "unexpected missing-report refusal text"
  assert_present "$LEASED_HOME" "a refused cleanup must leave the home intact"
  pass "cleanup refuses until the programme report exists"
}

test_cleanup_refuses_until_the_decision_gate_passes() {
  local out status
  make_case cleanup-decisions prog-cleanup-k2
  out=$(run_spawn "$SUP_ID" --supervisor --harness codex)
  expect_code 0 $? "supervisor spawn should succeed (got: $out)"
  mkdir -p "$PARENT_HOME/data/$SUP_ID"
  printf '# programme report\n' > "$PARENT_HOME/data/$SUP_ID/report.md"

  out=$(run_teardown "$SUP_ID")
  status=$?
  [ "$status" -ne 0 ] || fail "cleanup must refuse before the unresolved-decision gate passes"
  assert_contains "$out" "unresolved-decision completion gate" "unexpected decision-gate refusal text"
  assert_present "$LEASED_HOME" "a refused cleanup must leave the home intact"
  pass "cleanup refuses until the unresolved-decision completion gate passes"
}

test_cleanup_refuses_unlanded_work_in_the_home() {
  local out status
  make_case cleanup-unlanded prog-cleanup-l3
  out=$(run_spawn "$SUP_ID" --supervisor --harness codex)
  expect_code 0 $? "supervisor spawn should succeed (got: $out)"
  satisfy_report_and_decisions
  printf 'unfinished\n' > "$LEASED_HOME/scratch.txt"
  git -C "$LEASED_HOME" add scratch.txt

  out=$(run_teardown "$SUP_ID")
  status=$?
  [ "$status" -ne 0 ] || fail "cleanup must refuse while the home holds uncommitted work"
  assert_contains "$out" "uncommitted changes" "unexpected unlanded-work refusal text"
  assert_present "$LEASED_HOME" "a refused cleanup must leave the home intact"
  pass "cleanup refuses while the supervisor home holds unlanded work"
}

test_cleanup_returns_the_lease_once_everything_is_reconciled() {
  local out status
  make_case cleanup-clean prog-cleanup-m4
  out=$(run_spawn "$SUP_ID" --supervisor --harness codex)
  expect_code 0 $? "supervisor spawn should succeed (got: $out)"
  satisfy_report_and_decisions

  out=$(run_teardown "$SUP_ID")
  status=$?
  expect_code 0 "$status" "cleanup should succeed once everything is reconciled (got: $out)"
  assert_grep "return $LEASED_HOME" "$LEASE_LOG" "cleanup did not return the home's lease"
  assert_absent "$PARENT_HOME/state/$SUP_ID.meta" "cleanup left the task record behind"
  assert_present "$PARENT_HOME/data/$SUP_ID/report.md" "the programme report must survive cleanup"
  pass "cleanup returns the lease and keeps the programme report"
}

test_open_leases_a_marked_home_and_registers_nothing
test_open_clones_no_project_into_the_home
test_home_is_a_primary_scope_only_once_marked
test_relaunch_returns_to_the_same_home
test_relaunch_refuses_when_the_recorded_home_is_gone
test_open_refuses_to_reuse_another_task_id
test_open_refuses_a_delivery_contract_and_a_project_argument
test_child_dispatch_lands_in_the_supervisor_home
test_cleanup_refuses_while_a_child_record_remains
test_cleanup_refuses_without_the_programme_report
test_cleanup_refuses_until_the_decision_gate_passes
test_cleanup_refuses_unlanded_work_in_the_home
test_cleanup_returns_the_lease_once_everything_is_reconciled

echo "# all fm-temporary-supervisor tests passed"
