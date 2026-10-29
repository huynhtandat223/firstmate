#!/usr/bin/env bash
# shellcheck disable=SC2016
# Behavior tests for the model deny list (spec huynhtandat223/firstmate#200, E6b;
# config/model-deny, bin/fm-model-deny-lib.sh).
#
# MD1, MD2 (spawn): each case drives the real fm-spawn.sh through the shared fake
# tmux, in a lab home under a temp root, never the live home. The relaunch case
# lives in tests/fm-control-relaunch.test.sh, beside the fixtures it needs.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=bin/fm-model-deny-lib.sh
. "$ROOT/bin/fm-model-deny-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-model-deny)
unset LAVISH_AXI_HOST ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN OPENAI_API_KEY

new_case() {  # <name> -> sets CASE HOME_DIR PROJ WT FAKEBIN
  CASE="$TMP_ROOT/$1"
  HOME_DIR="$CASE/home"
  PROJ="$CASE/project"
  WT="$CASE/wt"
  FAKEBIN=$(fm_test_make_spawn_fakebin "$CASE/fake")
  fm_test_spawn_home "$HOME_DIR" claude
  fm_git_worktree "$PROJ" "$WT" "wt-$1"
  : > "$CASE/launch.log"
}

write_deny() {  # [block]
  printf '# captain-private\n*deepseek-v4-pro*  captain.md:9 DeepSeek is always Flash\n' > "$HOME_DIR/config/model-deny"
  if [ "${1:-}" = block ]; then printf 'block\n' > "$HOME_DIR/config/enforce-model-deny"; fi
}

spawn_scout() {  # <id> <model>
  local id=$1 model=$2
  fm_test_spawn_brief "$HOME_DIR" "$id"
  : > "$CASE/launch.log"
  FM_FAKE_LAUNCH_LOG="$CASE/launch.log" \
    fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$id" "$PROJ" --scout --model "$model"
}

test_md1_a_denied_model_is_refused_before_any_record() {
  local out rc id=md-pro
  new_case md1
  write_deny block
  out=$(spawn_scout "$id" 9route/ds/deepseek-v4-pro); rc=$?
  expect_code 1 "$rc" "MD1 a Pro spawn must refuse: $out"
  assert_contains "$out" "captain.md:9 DeepSeek is always Flash" "MD1 the refusal should print the line's reason"
  [ -z "$(find "$HOME_DIR/state" -name "$id*" 2>/dev/null)" ] || fail "MD1 a refused spawn must leave no record: $(find "$HOME_DIR/state" -name "$id*")"
  [ ! -s "$CASE/launch.log" ] || fail "MD1 a refused spawn must not launch"
  pass "MD1: --model 9route/ds/deepseek-v4-pro refuses before any endpoint or record and prints the reason"
}

test_md2_flash_and_an_absent_file_pass() {
  local out rc
  new_case md2
  write_deny block
  out=$(spawn_scout md-flash 9route/ds/deepseek-v4-flash); rc=$?
  expect_code 0 "$rc" "MD2 Flash should pass: $out"
  new_case md2-absent
  out=$(spawn_scout md-absent 9route/ds/deepseek-v4-pro); rc=$?
  expect_code 0 "$rc" "MD2 with no config/model-deny nothing changes: $out"
  pass "MD2: the Flash model passes, and an absent config/model-deny changes nothing"
}

test_log_only_until_the_switch_is_set() {
  local out rc
  new_case logonly
  write_deny
  out=$(spawn_scout md-log 9route/ds/deepseek-v4-pro); rc=$?
  expect_code 0 "$rc" "log-only default must launch: $out"
  grep -q 'would-refuse	9route/ds/deepseek-v4-pro	captain.md:9 DeepSeek is always Flash' "$HOME_DIR/state/enforce-model-deny.log" \
    || fail "hit log lacks the would-refuse line: $(cat "$HOME_DIR/state/enforce-model-deny.log" 2>&1)"
  pass "with config/enforce-model-deny absent the denied model launches and the would-be refusal is logged"
}

test_the_library_reads_the_file_strictly() {
  local cfg="$TMP_ROOT/lib-cfg" state="$TMP_ROOT/lib-state" err
  mkdir -p "$cfg" "$state"
  printf 'block\n' > "$cfg/enforce-model-deny"
  fm_model_deny_guard "$cfg" "$state" any-model || fail "an absent file must pass"
  printf '*-pro   no pro\n*-opus-4*  old opus\n' > "$cfg/model-deny"
  fm_model_deny_guard "$cfg" "$state" '' || fail "an empty model must pass"
  fm_model_deny_guard "$cfg" "$state" default || fail "the default model must pass"
  fm_model_deny_guard "$cfg" "$state" fast-flash || fail "an unmatched model must pass"
  err=$(fm_model_deny_guard "$cfg" "$state" big-pro 2>&1) && fail "a matching model must refuse"
  assert_contains "$err" "no pro" "the reason should print"
  err=$(fm_model_deny_guard "$cfg" "$state" claude-opus-4-1 2>&1) && fail "the second glob must refuse"
  assert_contains "$err" "old opus" "the second reason should print"
  printf '*-pro\n' > "$cfg/model-deny"
  err=$(fm_model_deny_guard "$cfg" "$state" x 2>&1) && fail "a glob with no reason must refuse"
  assert_contains "$err" "has no reason" "the missing reason should be named"
  pass "the library matches each glob, prints its reason, passes empty and default, and refuses a line with no reason"
}

test_md1_a_denied_model_is_refused_before_any_record
test_md2_flash_and_an_absent_file_pass
test_log_only_until_the_switch_is_set
test_the_library_reads_the_file_strictly

echo "# fm-model-deny.test.sh: all assertions passed"
