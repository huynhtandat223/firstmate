#!/usr/bin/env bash
# shellcheck disable=SC2016
# Behavior tests for the task identity checks (spec huynhtandat223/firstmate#200, E7;
# bin/fm-task-identity-check.sh). TI1: a done id is refused, citing its archive line.
# TI2: a second live task for one ticket key is refused, naming the first. TI3: a PR
# that closes another issue is refused, naming both issues (the forge read is a fake
# gh that answers with the real PR 1725 facts). Every case runs in a lab home under a
# temp root, never the live home.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-task-identity)
CHECK="$ROOT/bin/fm-task-identity-check.sh"

new_home() {  # <name>: a lab home with data/ state/ config/ projects/ and block mode on
  HOME_DIR="$TMP_ROOT/$1"
  mkdir -p "$HOME_DIR"/{data,state,config,projects}
  printf 'block\n' > "$HOME_DIR/config/enforce-task-identity"
}

run() {  # <args...>: the check against HOME_DIR; sets RC and OUT
  OUT=$(FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE='' PATH="${FAKEBIN:+$FAKEBIN:}$PATH" "$CHECK" "$@" 2>&1)
  RC=$?
}

test_ti1_a_done_id_is_refused_with_its_line() {
  new_home ti1
  {
    printf '# Archive\n\n## Archived 2026-09-25\n'
    printf -- '- [x] dci-screen-triggers - POST /v1/screen-triggers (repo: dms-code-index) (kind: ship) (done 2026-09-24)\n'
    printf -- '- [x] other-done - something else (kind: ship)\n'
  } > "$HOME_DIR/data/done-archive.md"
  run add dci-screen-triggers "Screen triggers again"
  expect_code 1 "$RC" "TI1 a done id must be refused: $OUT"
  assert_contains "$OUT" "data/done-archive.md:4" "TI1 the refusal should cite the archive line"
  run add dci-screen-triggers-2 "Screen triggers again"
  expect_code 0 "$RC" "a fresh id must pass: $OUT"
  printf -- '- [x] done-in-backlog - old (kind: ship)\n' > "$HOME_DIR/data/backlog.md"
  run add done-in-backlog "reuse"
  expect_code 1 "$RC" "a done row in the backlog also blocks reuse: $OUT"
  assert_contains "$OUT" "data/backlog.md:1" "the backlog line should be cited"
  pass "TI1: adding task dci-screen-triggers is refused, citing data/done-archive.md and its line; a new id and no match pass"
}

test_a_create_after_dispatch_is_not_refused_for_its_own_branch() {
  local out
  new_home after-dispatch
  git init -q "$HOME_DIR/projects/proj"
  git -C "$HOME_DIR/projects/proj" commit -q --allow-empty -m i
  # The spawn made the pool worktree, whose branch the project clone shares.
  git -C "$HOME_DIR/projects/proj" branch fm/spawned-task
  printf 'token\n' > "$HOME_DIR/token"
  printf -- '- [x] done-task - old (kind: ship)\n' > "$HOME_DIR/data/done-archive.md"
  # The API address is closed: a create that passes the identity check fails on the network,
  # one the check refuses stops before it.
  out=$(FM_HOME="$HOME_DIR" FM_TASK_BASE_URL=http://127.0.0.1:9 FM_TASK_TOKEN_FILE="$HOME_DIR/token" "$ROOT/bin/fm-task.sh" create spawned-task --title "Spawned" --kind ship --repo proj 2>&1)
  assert_not_contains "$out" "task identity" "a create after dispatch must not be refused for the branch its own spawn made: $out"
  out=$(FM_HOME="$HOME_DIR" FM_TASK_BASE_URL=http://127.0.0.1:9 FM_TASK_TOKEN_FILE="$HOME_DIR/token" "$ROOT/bin/fm-task.sh" create done-task --title "Again" --kind ship --repo proj 2>&1)
  assert_contains "$out" "task identity" "a create of a done id is still refused: $out"
  # Intake keeps the branch check: the tasks-axi add path passes the repo.
  run add spawned-task "Spawned" proj
  expect_code 1 "$RC" "intake must still refuse an id whose branch exists: $OUT"
  pass "a fm-task.sh create after dispatch is not refused for its own fm/<id> branch, while a done id and the intake branch check still refuse"
}

test_the_fm_branch_blocks_reuse() {
  new_home branch
  git init -q "$HOME_DIR/projects/proj"
  git -C "$HOME_DIR/projects/proj" commit -q --allow-empty -m i
  git -C "$HOME_DIR/projects/proj" branch fm/old-task
  run add old-task "again" proj
  expect_code 1 "$RC" "an existing fm/<id> branch must refuse: $OUT"
  assert_contains "$OUT" "fm/old-task" "the branch should be named"
  run add new-task "again" proj
  expect_code 0 "$RC" "a new id must pass: $OUT"
  run add old-task "again" no-such-project
  expect_code 0 "$RC" "an unknown project has no branch to find: $OUT"
  pass "an existing fm/<id> branch in the project clone refuses the add, naming the branch"
}

test_ti2_a_second_task_for_one_ticket_key_is_refused() {
  new_home ti2
  {
    printf -- '- [ ] dev-15769-next-step - DEV-15769 next step: split the migration (repo: dms-workspaces) (kind: ship)\n'
    printf -- '  body mentioning DEV-15770 only in the note\n'
    printf -- '- [x] dev-15769-inspect - DEV-15769 inspect (kind: scout)\n'
    printf -- '- [ ] ps-9-live - PS-9 something (kind: ship)\n'
  } > "$HOME_DIR/data/backlog.md"
  run add dev-15769-followup "DEV-15769 follow-up: summarize"
  expect_code 1 "$RC" "TI2 a second task for DEV-15769 must be refused: $OUT"
  assert_contains "$OUT" "dev-15769-next-step" "TI2 the refusal should name the live task"
  assert_not_contains "$OUT" "dev-15769-inspect" "a done task is not a live holder of the key"
  run add dev-15770-a "DEV-15770 fresh"
  expect_code 0 "$RC" "a key only in a note must pass: $OUT"
  run add ps-99-a "PS-99 other"
  expect_code 0 "$RC" "a different key must pass: $OUT"
  run add ps-9-live "PS-9 same task"
  expect_code 0 "$RC" "a task is not its own duplicate: $OUT"
  run add ps-9-b "ps-9 lowercase"
  expect_code 1 "$RC" "the key match ignores case: $OUT"
  pass "TI2: a title carrying a live task's ticket key is refused naming that task; done tasks, other keys and the task itself pass"
}

test_log_only_until_the_switch_is_set() {
  new_home logonly
  rm "$HOME_DIR/config/enforce-task-identity"
  printf -- '- [x] reused - old\n' > "$HOME_DIR/data/backlog.md"
  run add reused "again"
  expect_code 0 "$RC" "log-only must not refuse: $OUT"
  grep -q 'would-refuse	reused-id	' "$HOME_DIR/state/enforce-task-identity.log" || fail "no would-refuse line: $(cat "$HOME_DIR/state/enforce-task-identity.log" 2>&1)"
  pass "with config/enforce-task-identity absent the reused id is allowed and logged"
}

make_fake_gh() {  # <closing-issue-url>...: a gh whose pr view lists these closing references
  FAKEBIN="$TMP_ROOT/fakegh-$RANDOM"
  mkdir -p "$FAKEBIN"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'for u in'
    printf ' %q' "$@"
    printf '; do echo "$u"; done\n'
  } > "$FAKEBIN/gh"
  chmod +x "$FAKEBIN/gh"
}

test_ti3_a_pr_closing_another_issue_is_refused() {
  local pr=https://github.com/huynhtandat223/cfw-modules/pull/1725
  new_home ti3
  printf -- '- [x] titan-start-profile-maint - Profile Maintenance https://github.com/huynhtandat223/cfw-modules/issues/1707 https://github.com/huynhtandat223/cfw-modules/pull/1715 (repo: cfw-modules) (kind: ship)\n  more text #1708\n' > "$HOME_DIR/data/backlog.md"
  make_fake_gh https://github.com/huynhtandat223/cfw-modules/issues/1708
  run pr titan-start-profile-maint "$pr"
  expect_code 1 "$RC" "TI3 PR 1725 closes #1708 and must be refused: $OUT"
  assert_contains "$OUT" "issues/1707" "TI3 the task's issue should be named"
  assert_contains "$OUT" "issues/1708" "TI3 the closed issue should be named"
  make_fake_gh https://github.com/huynhtandat223/cfw-modules/issues/1707
  run pr titan-start-profile-maint https://github.com/huynhtandat223/cfw-modules/pull/1715
  expect_code 0 "$RC" "a PR that closes the linked issue must pass: $OUT"
  make_fake_gh
  run pr titan-start-profile-maint "$pr"
  expect_code 0 "$RC" "a PR with no closing reference has nothing to compare: $OUT"
  make_fake_gh https://github.com/huynhtandat223/cfw-modules/issues/1707 https://github.com/huynhtandat223/cfw-modules/issues/1708
  run pr titan-start-profile-maint "$pr"
  expect_code 0 "$RC" "a PR that also closes the linked issue passes: $OUT"
  run pr no-such-task "$pr"
  expect_code 0 "$RC" "a task with no backlog item has no linked issue: $OUT"
  FAKEBIN=''
  pass "TI3: a PR whose closing references omit the task's linked issue is refused naming both issues; matching, empty and unlinked cases pass"
}

test_the_merge_path_runs_the_pr_identity_check_too() {
  local pr=https://github.com/huynhtandat223/cfw-modules/pull/1725 id=titan-start-profile-maint out rc
  new_home merge
  printf -- '- [ ] %s - Profile Maintenance https://github.com/huynhtandat223/cfw-modules/issues/1707 (repo: cfw-modules) (kind: ship)\n' "$id" > "$HOME_DIR/data/backlog.md"
  printf 'kind=ship\nproject=%s\n' "$HOME_DIR/projects/cfw-modules" > "$HOME_DIR/state/$id.meta"
  make_fake_gh https://github.com/huynhtandat223/cfw-modules/issues/1708
  for merge in 0 1; do
    out=$(FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE='' FM_PR_CHECK_MERGE=$([ "$merge" = 1 ] && echo 1 || echo '') PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-pr-check.sh" "$id" "$pr" 2>&1); rc=$?
    expect_code 1 "$rc" "fm-pr-check.sh (merge path: $merge) must refuse a PR that closes another issue: $out"
    assert_contains "$out" "issues/1708" "the closed issue should be named (merge path: $merge)"
  done
  grep -q '^pr=' "$HOME_DIR/state/$id.meta" && fail "a refused PR must not be recorded"
  FAKEBIN=''
  pass "fm-pr-check.sh runs the PR identity check on the merge path as well"
}

test_the_callers_run_the_check() {
  new_home callers
  printf -- '- [x] reused-id - old\n' > "$HOME_DIR/data/backlog.md"
  cp "$ROOT/.tasks.toml" "$HOME_DIR/.tasks.toml"
  FAKEBIN="$TMP_ROOT/faketasks"
  mkdir -p "$FAKEBIN"
  printf '#!/usr/bin/env bash\necho "tasks-axi ran: $*" >> "%s/ran"\n' "$TMP_ROOT" > "$FAKEBIN/tasks-axi"
  chmod +x "$FAKEBIN/tasks-axi"
  rm -f "$TMP_ROOT/ran"
  OUT=$(FM_HOME="$HOME_DIR" PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-tasks-axi.sh" add reused-id "again" --kind ship 2>&1); RC=$?
  expect_code 2 "$RC" "fm-tasks-axi.sh add of a done id must refuse: $OUT"
  assert_contains "$OUT" "already a done task" "the wrapper should print the refusal"
  [ ! -e "$TMP_ROOT/ran" ] || fail "tasks-axi must not run after a refusal"
  OUT=$(FM_HOME="$HOME_DIR" PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-tasks-axi.sh" add brand-new "fresh" --kind ship 2>&1); RC=$?
  expect_code 0 "$RC" "a fresh id must reach tasks-axi: $OUT"
  [ -e "$TMP_ROOT/ran" ] || fail "tasks-axi should have run for a fresh id"
  pass "fm-tasks-axi.sh add runs the identity check before tasks-axi"
}

test_ti1_a_done_id_is_refused_with_its_line
test_a_create_after_dispatch_is_not_refused_for_its_own_branch
test_the_fm_branch_blocks_reuse
test_ti2_a_second_task_for_one_ticket_key_is_refused
test_log_only_until_the_switch_is_set
test_ti3_a_pr_closing_another_issue_is_refused
test_the_merge_path_runs_the_pr_identity_check_too
test_the_callers_run_the_check

echo "# fm-task-identity.test.sh: all assertions passed"
