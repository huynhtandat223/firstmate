#!/usr/bin/env bash
# shellcheck disable=SC2016
# Behavior tests for the DMS account guard (spec huynhtandat223/firstmate#200, E6a;
# config/dms-account, bin/fm-dms-account-lib.sh).
#
# CA1, CA2 (spawn): each case drives the real fm-spawn.sh through the shared fake
# tmux, in a lab home under a temp root, never the live home. The relaunch and
# assistance start cases live in tests/fm-control-relaunch.test.sh and
# tests/fm-assistance.test.sh, beside the fixtures those commands need.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=bin/fm-dms-account-lib.sh
. "$ROOT/bin/fm-dms-account-lib.sh"

# shellcheck disable=SC2088
TILDE='~'  # the file is written with a literal tilde, as the live one is
TMP_ROOT=$(fm_test_tmproot fm-dms-account)
unset LAVISH_AXI_HOST ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN OPENAI_API_KEY

# new_case <name> <project-name> -> sets CASE HOME_DIR PROJ WT FAKEBIN
new_case() {
  CASE="$TMP_ROOT/$1"
  HOME_DIR="$CASE/home"
  PROJ="$CASE/$2"
  WT="$CASE/wt"
  FAKEBIN=$(fm_test_make_spawn_fakebin "$CASE/fake")
  fm_test_spawn_home "$HOME_DIR" claude
  fm_git_worktree "$PROJ" "$WT" "wt-$1"
  mkdir -p "$HOME_DIR/user-home"
  : > "$CASE/launch.log"
}

# The lab file of the live shape: the root first, then the DMS projects.
write_dms_account() {  # <root-as-written> [block]
  {
    printf '# DMS work runs on one account\n'
    printf 'root %s\n\n' "$1"
    printf 'project dms-workspaces\nproject dms-kernel   # a trailing comment\nproject AutoLedgers\nassistance dms\n'
  } > "$HOME_DIR/config/dms-account"
  if [ "${2:-}" = block ]; then printf 'block\n' > "$HOME_DIR/config/enforce-dms-account"; fi
}

# spawn_scout <id> <claude-config-dir>: a scout spawn whose invoking process
# carries the given CLAUDE_CONFIG_DIR (the task from the report: dev-5902-inspect).
spawn_scout() {
  local id=$1 root=$2
  fm_test_spawn_brief "$HOME_DIR" "$id"
  : > "$CASE/launch.log"
  FM_FAKE_LAUNCH_LOG="$CASE/launch.log" FM_TEST_CLAUDE_CONFIG_DIR="$root" \
    fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$id" "$PROJ" --scout
}

test_ca1_a_dms_spawn_on_the_wrong_account_is_refused() {
  local out rc id=dev-5902-inspect
  new_case ca1 dms-workspaces
  write_dms_account "$TILDE/.claude-account2" block
  mkdir -p "$CASE/account3"
  out=$(spawn_scout "$id" "$CASE/account3"); rc=$?
  expect_code 1 "$rc" "CA1 a DMS spawn on account3 must refuse: $out"
  assert_contains "$out" "config/dms-account" "CA1 the refusal should name the file"
  assert_contains "$out" "$TILDE/.claude-account2" "CA1 the refusal should name the root"
  assert_contains "$out" "$CASE/account3" "CA1 the refusal should name the resolved account"
  assert_absent "$HOME_DIR/state/$id.meta" "CA1 a refused spawn must not publish a task record"
  assert_absent "$HOME_DIR/state/$id.status" "CA1 a refused spawn must not write a status line"
  [ ! -s "$CASE/launch.log" ] || fail "CA1 a refused spawn must not launch a worker: $(cat "$CASE/launch.log")"
  [ -z "$(find "$HOME_DIR/state" -name "$id*" 2>/dev/null)" ] || fail "CA1 a refused spawn must leave no record of the task: $(find "$HOME_DIR/state" -name "$id*")"
  printf '%s\n' "$out" > "$TMP_ROOT/ca1-refusal.txt"
  # The default account is not the root either.
  out=$(spawn_scout "$id" ''); rc=$?
  expect_code 1 "$rc" "CA1 a DMS spawn on the default account must refuse: $out"
  assert_contains "$out" "$HOME_DIR/user-home/.claude" "CA1 the default account should be named as resolved"
  pass "CA1: a DMS spawn with CLAUDE_CONFIG_DIR on another account refuses before any record or endpoint, naming config/dms-account and ~/.claude-account2"
}

test_ca2_the_right_account_and_other_projects_pass() {
  local out rc
  new_case ca2-root dms-workspaces
  write_dms_account "$TILDE/.claude-account2" block
  out=$(spawn_scout dev-5902-inspect "$HOME_DIR/user-home/.claude-account2"); rc=$?
  expect_code 0 "$rc" "CA2 a DMS spawn on the declared root should succeed: $out"
  assert_grep "kind=scout" "$HOME_DIR/state/dev-5902-inspect.meta" "CA2 the task record should exist"

  new_case ca2-other other-project
  write_dms_account "$TILDE/.claude-account2" block
  mkdir -p "$CASE/account3"
  out=$(spawn_scout other-task "$CASE/account3"); rc=$?
  expect_code 0 "$rc" "CA2 a project not in the file should pass on any account: $out"

  new_case ca2-absent dms-workspaces
  mkdir -p "$CASE/account3"
  out=$(spawn_scout absent-task "$CASE/account3"); rc=$?
  expect_code 0 "$rc" "CA2 with config/dms-account absent the guard should do nothing: $out"
  pass "CA2: the declared root passes, a project outside the file passes, and an absent file changes nothing"
}

test_log_only_until_the_switch_is_set() {
  local out rc log
  new_case logonly dms-workspaces
  write_dms_account "$TILDE/.claude-account2"
  mkdir -p "$CASE/account3"
  out=$(spawn_scout log-task "$CASE/account3"); rc=$?
  expect_code 0 "$rc" "a DMS spawn on the wrong account must still launch while config/enforce-dms-account is absent: $out"
  log="$HOME_DIR/state/enforce-dms-account.log"
  [ -f "$log" ] || fail "log-only default wrote no hit log"
  grep -q 'would-refuse	project-dms-workspaces	' "$log" || fail "hit log lacks the would-refuse line: $(cat "$log")"
  pass "with config/enforce-dms-account absent the wrong account launches and the would-be refusal is logged"
}

test_the_library_reads_the_file_strictly() {
  local cfg="$TMP_ROOT/lib-cfg" state="$TMP_ROOT/lib-state" err
  mkdir -p "$cfg" "$state"
  printf 'block\n' > "$cfg/enforce-dms-account"
  fm_dms_account_guard "$cfg" "$state" project dms-kernel claude '/x' || fail "an absent file must pass"
  printf 'project dms-kernel\n' > "$cfg/dms-account"
  err=$(fm_dms_account_guard "$cfg" "$state" project dms-kernel claude '/x' 2>&1) && fail "a file with no root line must refuse"
  assert_contains "$err" "no 'root <path>' line" "the missing root should be named"
  printf 'root /r\nprojekt dms-kernel\n' > "$cfg/dms-account"
  err=$(fm_dms_account_guard "$cfg" "$state" project dms-kernel claude '/x' 2>&1) && fail "an unknown line must refuse"
  assert_contains "$err" "line 2" "the bad line number should be named"
  printf 'root /r\nproject dms-kernel\nassistance dms\n' > "$cfg/dms-account"
  fm_dms_account_guard "$cfg" "$state" project dms-kernel pi '/x' || fail "a non-claude launch must pass"
  fm_dms_account_guard "$cfg" "$state" project dms-kernel claude '/r/' || fail "a trailing slash on the root must pass"
  fm_dms_account_guard "$cfg" "$state" project dms-kernel claude '/x' 2>/dev/null && fail "the wrong root must refuse"
  fm_dms_account_guard "$cfg" "$state" assistance dms claude '/x' 2>/dev/null && fail "the dms assistance on the wrong root must refuse"
  fm_dms_account_guard "$cfg" "$state" assistance planner claude '/x' || fail "an assistance outside the file must pass"
  fm_dms_account_guard "$cfg" "$state" project dms claude '/x' || fail "a project is not matched by an assistance line"
  pass "the library refuses a malformed file, ignores non-claude launches and unlisted names, and compares roots without a trailing slash"
}

test_a_raw_command_with_its_own_account_is_checked() {
  local out rc id=raw-task
  new_case raw dms-workspaces
  write_dms_account "$TILDE/.claude-account2" block
  # The caller's environment is the declared root; the raw command overrides it.
  fm_test_spawn_brief "$HOME_DIR" "$id"
  out=$(FM_FAKE_LAUNCH_LOG="$CASE/launch.log" FM_TEST_CLAUDE_CONFIG_DIR="$HOME_DIR/user-home/.claude-account2" \
    fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$id" "$PROJ" "CLAUDE_CONFIG_DIR=$CASE/account3 claude --flag" --scout); rc=$?
  expect_code 1 "$rc" "a raw claude command with another CLAUDE_CONFIG_DIR must refuse though the caller env is right: $out"
  assert_contains "$out" "$CASE/account3" "the refusal should name the raw command's account"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused raw spawn must not publish a task record"
  out=$(FM_FAKE_LAUNCH_LOG="$CASE/launch.log" FM_TEST_CLAUDE_CONFIG_DIR="$CASE/account3" \
    fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$id" "$PROJ" "CLAUDE_CONFIG_DIR='$HOME_DIR/user-home/.claude-account2' claude --flag" --scout); rc=$?
  expect_code 0 "$rc" "a raw claude command that sets the declared root must pass though the caller env is wrong: $out"
  pass "a raw claude launch command's own CLAUDE_CONFIG_DIR= is the account that is checked, not the caller's"
}

# spawn_raw <id> <raw-command> [caller-account]: a scout spawn with a raw launch command.
spawn_raw() {
  local id=$1 raw=$2 root=${3:-$HOME_DIR/user-home/.claude-account2}
  fm_test_spawn_brief "$HOME_DIR" "$id"
  : > "$CASE/launch.log"
  FM_FAKE_LAUNCH_LOG="$CASE/launch.log" FM_TEST_CLAUDE_CONFIG_DIR="$root" \
    fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$id" "$PROJ" "$raw" --scout
}

test_a_raw_launch_on_a_listed_project_must_start_with_claude() {
  local out rc raw declared
  new_case rawshape dms-workspaces
  write_dms_account "$TILDE/.claude-account2" block
  declared="$HOME_DIR/user-home/.claude-account2"
  for raw in \
    "env CLAUDE_CONFIG_DIR=$declared claude --flag" \
    "command claude --flag" \
    "exec claude --flag" \
    "ANTHROPIC_API_KEY=account3key CLAUDE_CONFIG_DIR=$declared claude --flag" \
    "CLAUDE_CODE_OAUTH_TOKEN=x claude --flag" \
    "custom-agent --flag"; do
    out=$(spawn_raw "shape-task" "$raw"); rc=$?
    expect_code 1 "$rc" "block mode must refuse the raw launch '$raw': $out"
    assert_contains "$out" "raw launch command is refused" "the refusal should say it is the raw command ($raw)"
    assert_absent "$HOME_DIR/state/shape-task.meta" "a refused raw launch must not publish a record ($raw)"
  done
  out=$(spawn_raw shape-ok "CLAUDE_CONFIG_DIR='$declared' FOO=1 claude --flag"); rc=$?
  expect_code 0 "$rc" "a raw launch that starts with claude and assigns no credential must pass: $out"
  # A project outside the file keeps every shape.
  new_case rawshape-other other-project
  write_dms_account "$TILDE/.claude-account2" block
  out=$(spawn_raw other-shape "env FOO=1 custom-agent --flag" "$CASE/account3"); rc=$?
  expect_code 0 "$rc" "a raw launch on an unlisted project is untouched: $out"
  # Log-only logs each breach and refuses nothing.
  new_case rawshape-log dms-workspaces
  write_dms_account "$TILDE/.claude-account2"
  out=$(spawn_raw log-shape "env CLAUDE_CONFIG_DIR=$declared claude --flag"); rc=$?
  expect_code 0 "$rc" "log-only must launch the env wrapper: $out"
  grep -q 'would-refuse	project-dms-workspaces	.*not claude' "$HOME_DIR/state/enforce-dms-account.log" || fail "log-only wrote no wrapper line: $(cat "$HOME_DIR/state/enforce-dms-account.log" 2>&1)"
  out=$(spawn_raw log-cred "ANTHROPIC_API_KEY=k CLAUDE_CONFIG_DIR=$declared claude --flag"); rc=$?
  expect_code 0 "$rc" "log-only must launch the credential assignment: $out"
  grep -q 'would-refuse	project-dms-workspaces	.*assigns ANTHROPIC_API_KEY' "$HOME_DIR/state/enforce-dms-account.log" || fail "log-only wrote no credential line"
  pass "block mode refuses a raw launch on a listed project unless it starts with claude and assigns no shed-list credential; log-only logs both"
}

test_a_quoted_root_with_a_space_is_read_whole() {
  local out rc root
  new_case space dms-workspaces
  root="$HOME_DIR/user-home/with space/.claude-account2"
  write_dms_account "$root" block
  mkdir -p "$root"
  fm_test_spawn_brief "$HOME_DIR" space-task
  out=$(FM_FAKE_LAUNCH_LOG="$CASE/launch.log" FM_TEST_CLAUDE_CONFIG_DIR="$CASE" \
    fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" space-task "$PROJ" "CLAUDE_CONFIG_DIR='$root' claude --flag" --scout); rc=$?
  expect_code 0 "$rc" "a quoted declared root with a space must not be split: $out"
  fm_dms_account_raw_parse "CLAUDE_CONFIG_DIR=\"/a b/c\" X=1 claude"
  [ "$FM_DMS_RAW_ROOT" = "/a b/c" ] || fail "a double-quoted root was split: $FM_DMS_RAW_ROOT"
  pass "a quoted CLAUDE_CONFIG_DIR with a space in a raw launch command is read as one path"
}

test_a_guarded_launch_sheds_the_other_credentials() {
  local out rc
  new_case shed dms-workspaces
  write_dms_account "$TILDE/.claude-account2" block
  out=$(spawn_scout shed-task "$HOME_DIR/user-home/.claude-account2"); rc=$?
  expect_code 0 "$rc" "a DMS spawn on the declared root should succeed: $out"
  assert_grep '-u ANTHROPIC_API_KEY' "$CASE/launch.log" "a guarded DMS launch must shed ANTHROPIC_API_KEY"
  assert_grep '-u CLAUDE_CODE_OAUTH_TOKEN' "$CASE/launch.log" "a guarded DMS launch must shed CLAUDE_CODE_OAUTH_TOKEN"
  new_case shed-other other-project
  write_dms_account "$TILDE/.claude-account2" block
  out=$(spawn_scout shed-other "$CASE/account3"); rc=$?
  expect_code 0 "$rc" "a project outside the file should launch: $out"
  assert_no_grep '-u ANTHROPIC_API_KEY' "$CASE/launch.log" "a launch outside config/dms-account must not shed credentials"
  # Log-only must not change the launch: an existing key-only login keeps working.
  new_case shed-log dms-workspaces
  write_dms_account "$TILDE/.claude-account2"
  out=$(spawn_scout shed-log "$HOME_DIR/user-home/.claude-account2"); rc=$?
  expect_code 0 "$rc" "a DMS spawn in log-only mode should succeed: $out"
  assert_no_grep '-u ANTHROPIC_API_KEY' "$CASE/launch.log" "log-only must not shed credentials"
  pass "a DMS launch sheds ANTHROPIC_API_KEY and CLAUDE_CODE_OAUTH_TOKEN only in block mode, and an unlisted project is left alone"
}

test_a_dotted_project_dir_names_the_clone() {
  local out rc
  new_case dot dms-workspaces
  write_dms_account "$TILDE/.claude-account2" block
  mkdir -p "$CASE/account3"
  fm_test_spawn_brief "$HOME_DIR" dot-task
  out=$(FM_FAKE_LAUNCH_LOG="$CASE/launch.log" FM_TEST_CLAUDE_CONFIG_DIR="$CASE/account3" \
    fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" dot-task "$PROJ/." --scout); rc=$?
  expect_code 1 "$rc" "a DMS clone named as <dir>/. must still be guarded: $out"
  [ "$(fm_dms_account_project_name "$PROJ/.")" = dms-workspaces ] || fail "the dotted path did not resolve to the clone name"
  [ "$(fm_dms_account_project_name "$PROJ/")" = dms-workspaces ] || fail "the trailing slash did not resolve to the clone name"
  ln -s "$PROJ" "$CASE/link"
  [ "$(fm_dms_account_project_name "$CASE/link")" = dms-workspaces ] || fail "a symlink did not resolve to the clone name"
  pass "a project dir given as <dir>/. , <dir>/ or a symlink is guarded as the DMS clone it is"
}

test_an_unreadable_file_refuses() {
  local cfg="$TMP_ROOT/unreadable-cfg" state="$TMP_ROOT/unreadable-state" err
  mkdir -p "$cfg/dms-account" "$state"
  err=$(fm_dms_account_guard "$cfg" "$state" project dms-kernel claude '/x' 2>&1) && fail "a config/dms-account that exists but is not a readable file must refuse"
  assert_contains "$err" "cannot be read" "the unreadable file should be named"
  rmdir "$cfg/dms-account"
  ln -s "$cfg/missing-target" "$cfg/dms-account"
  fm_dms_account_guard "$cfg" "$state" project dms-kernel claude '/x' 2>/dev/null && fail "a dangling config/dms-account must refuse"
  rm -f "$cfg/dms-account"
  fm_dms_account_guard "$cfg" "$state" project dms-kernel claude '/x' || fail "only a true absence is a no-op"
  pass "a config/dms-account that exists but cannot be read refuses; only true absence is a no-op"
}

test_ca1_a_dms_spawn_on_the_wrong_account_is_refused
test_a_raw_command_with_its_own_account_is_checked
test_a_raw_launch_on_a_listed_project_must_start_with_claude
test_a_quoted_root_with_a_space_is_read_whole
test_a_guarded_launch_sheds_the_other_credentials
test_a_dotted_project_dir_names_the_clone
test_an_unreadable_file_refuses
test_ca2_the_right_account_and_other_projects_pass
test_log_only_until_the_switch_is_set
test_the_library_reads_the_file_strictly

echo "# fm-dms-account.test.sh: all assertions passed"
