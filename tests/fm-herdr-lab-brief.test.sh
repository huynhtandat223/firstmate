#!/usr/bin/env bash
# shellcheck disable=SC2016
# Behavior tests for the Herdr-lab brief check (spec huynhtandat223/firstmate#200, E8a;
# bin/fm-herdr-lab-phrase-lib.sh). HL1: fm-brief.sh --check refuses the unguarded T4 brief of
# 2026-10-26 (TR33, assistance rotation). HL2: fm-send.sh refuses the HV1 probe-pane steer to a
# task whose brief has no lab block, and writes it to a task whose brief has one. Every case
# runs in a lab home under a temp root, never the live home.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-herdr-lab-brief)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
# shellcheck source=bin/fm-herdr-lab-phrase-lib.sh
. "$ROOT/bin/fm-herdr-lab-phrase-lib.sh"

# The TR33 line of the T4 brief as firstmate wrote it, and the HV1 steer as it was sent (retro 10-26#10, #26).
TR33='- TR33: prove the rotation in your Herdr lab (the contract above) with a scratch assistance in your scratch `FM_HOME`. The live Planner propose and rotation: write the exact commands and expected events into notes.md; firstmate runs them after review.'
HV1="PR 1702 merged at eedb51dc8; clone synced. Wait for the main deploy of eedb51dc8 on 5001, read back both Video drafts served 200 with selectionContext declared (SysAdmin wrapper), and record it in verify.md; the Tester re-checks HV4. Also for HV1 the Tester needs a probe pane whose reply holds 'follow up on': create one disposable probe the agent.chat.v2.harvest draft lists, name it in verify.md, and remove it after the Tester's HV1. Report with fm-task.sh done or block; do not end your turn before."

NO_LAB='# Herdr lifecycle declaration - NOT ENABLED
**HARD SAFETY GATE:** this scaffold cannot inspect the task text filled in above.'
WITH_LAB='# Herdr lifecycle declaration
This brief was explicitly scaffolded with `--herdr-lab` because the task will drive Herdr lifecycle behavior.'

write_brief() {  # <dir> <id> <task-text> <lab-section>
  mkdir -p "$1/home/data/$2" "$1/home/state" "$1/home/config"
  printf '# Task\n## Captain'"'"'s intent\n%s\n\n## Firstmate spec\nBuild it.\n\n%s\n' "$3" "$4" > "$1/home/data/$2/brief.md"
}

check() {  # <dir> <id>: sets RC and ERR
  ERR=$(FM_HOME="$1/home" FM_ROOT_OVERRIDE='' FM_DATA_OVERRIDE="$1/home/data" FM_CONFIG_OVERRIDE="$1/home/config" FM_STATE_OVERRIDE="$1/home/state" "$ROOT/bin/fm-brief.sh" --check "$2" 2>&1)
  RC=$?
}

test_the_phrase_rule() {
  local text
  [ -n "$(fm_herdr_lab_phrase "$TR33")" ] || fail "TR33 must match"
  [ -n "$(fm_herdr_lab_phrase "$HV1")" ] || fail "HV1 must match"
  for text in "restart the assistance" "stop a pane" "rotate the assistance now" "the pane must be closed" "relaunch your assistance"; do
    [ -n "$(fm_herdr_lab_phrase "$text")" ] || fail "must match: $text"
  done
  for text in "Fix the summary toggle and add a test." "The panel layout changes at 390." "Read the assistance charter and report." "Close the issue after the merge."; do
    [ -z "$(fm_herdr_lab_phrase "$text")" ] || fail "must not match: $text => $(fm_herdr_lab_phrase "$text")"
  done
  pass "the phrase rule matches a lifecycle verb near pane or assistance in either order, and ignores plain text and panel"
}

test_hl1_the_t4_brief_is_refused() {
  local dir="$TMP_ROOT/hl1"
  write_brief "$dir" t4 "$TR33" "$NO_LAB"
  printf 'block\n' > "$dir/home/config/enforce-herdr-lab-brief"
  check "$dir" t4
  [ "$RC" -eq 1 ] || fail "HL1 the unguarded T4 brief must be refused, got $RC: $ERR"
  assert_contains "$ERR" "re-scaffold with --herdr-lab" "HL1 the refusal should say how to fix it"
  write_brief "$dir" t4 "$TR33" "$WITH_LAB"
  check "$dir" t4
  [ "$RC" -eq 0 ] || fail "HL1 the same task with the lab block must pass: $ERR"
  write_brief "$dir" plain "Fix the summary toggle." "$NO_LAB"
  check "$dir" plain
  [ "$RC" -eq 0 ] || fail "a brief with no lifecycle phrase must pass: $ERR"
  pass "HL1: fm-brief.sh --check refuses the T4 brief with 're-scaffold with --herdr-lab'; with the lab block, or with no lifecycle phrase, it passes"
}

test_the_linked_issue_scenarios_count() {
  local dir="$TMP_ROOT/issue" stub
  write_brief "$dir" t5 "Ship it. Issue https://github.com/o/r/issues/9" "$NO_LAB"
  printf 'block\n' > "$dir/home/config/enforce-herdr-lab-brief"
  stub="$dir/acceptance.sh"
  printf '#!/usr/bin/env bash\necho "- X1@- | WHEN the assistance is restarted, THE rotation SHALL resume | pending"\n' > "$stub"
  chmod +x "$stub"
  ERR=$(FM_ACCEPTANCE_BIN="$stub" FM_HOME="$dir/home" FM_ROOT_OVERRIDE='' FM_DATA_OVERRIDE="$dir/home/data" FM_CONFIG_OVERRIDE="$dir/home/config" FM_STATE_OVERRIDE="$dir/home/state" "$ROOT/bin/fm-brief.sh" --check t5 2>&1); RC=$?
  [ "$RC" -eq 1 ] || fail "a lifecycle phrase in the linked issue's scenarios must refuse, got $RC: $ERR"
  pass "the linked issue's acceptance lines are read too"
}

test_log_only_until_the_switch_is_set() {
  local dir="$TMP_ROOT/logonly"
  write_brief "$dir" t4 "$TR33" "$NO_LAB"
  check "$dir" t4
  [ "$RC" -eq 0 ] || fail "log-only must not refuse: $ERR"
  grep -q 'would-refuse	brief	t4:' "$dir/home/state/enforce-herdr-lab-brief.log" || fail "no would-refuse line: $(cat "$dir/home/state/enforce-herdr-lab-brief.log" 2>&1)"
  pass "with config/enforce-herdr-lab-brief absent the brief check logs and passes"
}

make_stubs() {  # <dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat >"$fb/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) printf 'fm-t1\nwin\n'; exit 0 ;;
esac
exit 0
SH
  printf '#!/usr/bin/env bash\nexit 0\n' >"$fb/sleep"
  chmod +x "$fb/tmux" "$fb/sleep"
}

send() {  # <dir> <id> <text>: sets RC and ERR
  ERR=$(env PATH="$1/fakebin:$PATH" FM_ROOT_OVERRIDE="$1/home" FM_HOME="$1/home" FM_SEND_SETTLE=0 "$ROOT/bin/fm-send.sh" "$2" "$3" 2>&1 >/dev/null)
  RC=$?
}

test_hl2_the_probe_pane_steer() {
  local dir="$TMP_ROOT/hl2"
  write_brief "$dir" t1 "Verify the draft." "$NO_LAB"
  write_brief "$dir" t2 "Verify the draft." "$WITH_LAB"
  make_stubs "$dir"
  fm_write_meta "$dir/home/state/t1.meta" "window=sess:fm-t1" "kind=ship" "harness=claude"
  fm_write_meta "$dir/home/state/t2.meta" "window=sess:fm-t2" "kind=ship" "harness=claude"
  printf 'block\n' > "$dir/home/config/enforce-herdr-lab-brief"
  send "$dir" t1 "$HV1"
  [ "$RC" -ne 0 ] || fail "HL2 the probe-pane steer to a task without the lab block must be refused"
  assert_contains "$ERR" "re-scaffold with --herdr-lab" "HL2 the refusal should say how to fix it"
  [ -z "$(find "$dir/home/state/t1.inbox" -name '*.msg' 2>/dev/null)" ] || fail "a refused steer must not write a record"
  send "$dir" t2 "$HV1"
  [ "$RC" -eq 0 ] || fail "HL2 the same text to a task with the lab block must be written: $ERR"
  [ -f "$dir/home/state/t2.inbox/001.msg" ] || fail "no record written for the lab task"
  send "$dir" t1 "Please read the report and fix the summary toggle bug."
  [ "$RC" -eq 0 ] || fail "a steer with no lifecycle phrase must pass: $ERR"
  pass "HL2: the HV1 probe-pane steer is refused for a task whose brief has no lab block and written for one that has it"
}

test_the_phrase_rule
test_hl1_the_t4_brief_is_refused
test_the_linked_issue_scenarios_count
test_log_only_until_the_switch_is_set
test_hl2_the_probe_pane_steer

echo "# fm-herdr-lab-brief.test.sh: all assertions passed"
