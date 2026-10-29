#!/usr/bin/env bash
# tests/fm-send-steer-dedupe.test.sh - the local steer checks of fm-send
# (spec huynhtandat223/firstmate#200, E5).
#
# A local inbox steer is refused when its body is identical to an unhandled
# record or to one written in the last 30 minutes (SD1), or when its text is
# under 8 characters (SD2). --again resends on purpose, and the steer path of
# fm-assistance.sh applies the same rule (SD3). Every check is log-only until
# config/enforce-steer-dedupe holds `block`. All cases run the real fm-send
# executable over a stub tmux in a lab home, never the live home.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEND="$ROOT/bin/fm-send.sh"
TMP_ROOT=$(fm_test_tmproot fm-send-steer-dedupe)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

make_stubs() { # <dir>
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

setup_case() { # <name> [block]: prints the case dir
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/home/state" "$dir/home/config"
  make_stubs "$dir"
  fm_write_meta "$dir/home/state/t1.meta" "window=sess:fm-t1" "kind=ship" "harness=claude"
  [ "${2:-}" != block ] || printf 'block\n' > "$dir/home/config/enforce-steer-dedupe"
  printf '%s\n' "$dir"
}

send() { # <dir> <fm-send args...>: sets RC and ERR
  local dir=$1
  shift
  ERR=$(env PATH="$dir/fakebin:$PATH" FM_ROOT_OVERRIDE="$dir/home" FM_HOME="$dir/home" \
    FM_SEND_SETTLE=0 "$SEND" "$@" 2>&1 >/dev/null)
  RC=$?
}

# Two bodies shaped like the Planner's duplicated steers (retro 10-24: 14 s and
# 45 s apart): long, multi-line, sent twice unchanged.
BODY_A=$'Amend ticket #153 on the project repo (spec #152) to the state-checked turn end.\nBehaviour: a checker on every worker turn end; the newest valid working line means no wake;\ndone, blocked and needs-decision mean a wake; a missing line means a ping, at most 3 per wait.'
BODY_B=$'Re-run the acceptance rows for the wave and report each row with its evidence.\nDo not widen the scope; list anything else you find as a follow-up.'

test_sd1_identical_unhandled_steer_is_refused() {
  local dir rec
  dir=$(setup_case sd1-unhandled block)
  send "$dir" t1 "$BODY_A"
  [ "$RC" -eq 0 ] || fail "the first send must be written: $ERR"
  [ -f "$dir/home/state/t1.inbox/001.msg" ] || fail "the first send left no 001.msg"
  send "$dir" t1 "$BODY_A"
  [ "$RC" -ne 0 ] || fail "the identical second send was accepted"
  assert_contains "$ERR" "001.msg" "the refusal does not name the existing record"
  assert_contains "$ERR" "--again" "the refusal does not name --again"
  rec=("$dir/home/state/t1.inbox"/*.msg)
  [ "${#rec[@]}" -eq 1 ] || fail "the refused send still wrote a record"
  printf '%s\n' "$ERR" > "$TMP_ROOT/sd1-unhandled-refusal.txt"
  pass "SD1: the second of two identical sends is refused naming 001.msg, the first is written"
}

test_sd1_identical_handled_steer_is_refused_inside_the_window() {
  local dir
  dir=$(setup_case sd1-handled block)
  send "$dir" t1 "$BODY_B"
  [ "$RC" -eq 0 ] || fail "first send: $ERR"
  mkdir -p "$dir/home/state/t1.inbox/handled"
  mv "$dir/home/state/t1.inbox/001.msg" "$dir/home/state/t1.inbox/handled/001.msg"
  send "$dir" t1 "$BODY_B"
  [ "$RC" -ne 0 ] || fail "an identical body written 0 minutes ago, already handled, was accepted"
  assert_contains "$ERR" "001.msg" "the refusal does not name the handled record"
  pass "SD1: a body identical to a handled record written inside 30 minutes is refused"
}

test_sd1_old_handled_steer_is_allowed_but_old_unhandled_is_not() {
  local dir
  dir=$(setup_case sd1-age block)
  send "$dir" t1 "$BODY_B"
  mkdir -p "$dir/home/state/t1.inbox/handled"
  mv "$dir/home/state/t1.inbox/001.msg" "$dir/home/state/t1.inbox/handled/001.msg"
  touch -d '3 hours ago' "$dir/home/state/t1.inbox/handled/001.msg"
  send "$dir" t1 "$BODY_B"
  [ "$RC" -eq 0 ] || fail "a body last written 3 hours ago and handled must be allowed: $ERR"
  touch -d '3 hours ago' "$dir/home/state/t1.inbox/002.msg"
  send "$dir" t1 "$BODY_B"
  [ "$RC" -ne 0 ] || fail "a body still unhandled after 3 hours must be refused"
  assert_contains "$ERR" "002.msg" "the refusal does not name the unhandled record"
  pass "SD1: a handled record older than 30 minutes no longer blocks; an unhandled one blocks at any age"
}

test_sd1_log_only_until_the_switch_is_set() {
  local dir log
  dir=$(setup_case sd1-log)
  send "$dir" t1 "$BODY_A"
  send "$dir" t1 "$BODY_A"
  [ "$RC" -eq 0 ] || fail "log-only default must accept the repeat: $ERR"
  [ -f "$dir/home/state/t1.inbox/002.msg" ] || fail "log-only default did not write 002.msg"
  log="$dir/home/state/enforce-steer-dedupe.log"
  grep -q 'would-refuse	duplicate	t1: identical body 001.msg' "$log" || fail "no would-refuse line: $(cat "$log" 2>&1)"
  printf 'log\n' > "$dir/home/config/enforce-steer-dedupe"
  send "$dir" t1 "$BODY_A"
  [ "$RC" -eq 0 ] || fail "a config of log must keep accepting"
  pass "SD1: with config/enforce-steer-dedupe absent the repeat is written and a would-refuse line is logged"
}

test_sd2_short_body_is_refused() {
  local dir
  dir=$(setup_case sd2 block)
  printf 'needs-decision [key=x]: pick one\n' > "$dir/home/state/t1.status"
  send "$dir" t1 --resolve-key x "x"
  [ "$RC" -ne 0 ] || fail "a one-character body was accepted"
  assert_contains "$ERR" "under 8 characters" "the refusal does not say why"
  [ ! -e "$dir/home/state/t1.inbox/001.msg" ] || fail "the refused short steer was written"
  grep -q 'needs-decision \[key=x\]' "$dir/home/state/t1.status" || fail "the status was lost"
  ! grep -q '^resolved' "$dir/home/state/t1.status" || fail "the refused send closed the decision anyway"
  send "$dir" t1 "eight ch"
  [ "$RC" -eq 0 ] || fail "an 8-character body must pass: $ERR"
  send "$dir" t1 "short"
  [ "$RC" -ne 0 ] || fail "a 5-character body was accepted"
  pass "SD2: a body under 8 characters is refused before anything is written or closed; 8 characters pass"
}

test_sd3_again_writes_the_repeat() {
  local dir
  dir=$(setup_case sd3 block)
  send "$dir" t1 "$BODY_A"
  send "$dir" t1 --again "$BODY_A"
  [ "$RC" -eq 0 ] || fail "--again must write the repeat: $ERR"
  [ -f "$dir/home/state/t1.inbox/002.msg" ] || fail "--again did not write 002.msg"
  [ "$(fm_inbox_body "$dir/home/state/t1.inbox/002.msg")" = "$BODY_A" ] || fail "the --again record body differs"
  send "$dir" t1 --again "x"
  [ "$RC" -ne 0 ] || fail "--again must not waive the short-text rule"
  pass "SD3: --again writes an identical body as a new record, and does not waive the short-text rule"
}

fm_inbox_body() { # <record>
  bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$1"
}

test_sd3_assistance_steer_applies_the_same_rule() {
  local dir="$TMP_ROOT/sd3-assist" parent helper out rc
  parent="$dir/parent"
  helper="$dir/helper"
  mkdir -p "$parent"/{data,state,config} "$helper"/{data,state,config}
  make_stubs "$dir"
  printf 'block\n' > "$parent/config/enforce-steer-dedupe"
  printf 'sample\n' > "$helper/.fm-assistance-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" > "$helper/.fm-assistance-parent"
  printf -- '- sample - Sample observer (home: %s; scope: observe; projects: ; added 2026-10-13)\n' "$helper" > "$parent/data/assistances.md"
  fm_write_meta "$parent/state/sample.meta" "window=sess:fm-t1" "kind=assistance" "harness=claude" "home=$helper"
  steer() { # <extra steer args...> -- <text>
    out=$(env -u FM_STATE_OVERRIDE -u FM_ROOT_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE \
      PATH="$dir/fakebin:$PATH" FM_HOME="$parent" FM_SEND_SETTLE=0 \
      "$ROOT/bin/fm-assistance.sh" steer sample "$@" 2>&1)
    rc=$?
  }
  steer --captain-words "Owner instruction" "$BODY_A"
  [ "$rc" -eq 0 ] || fail "the first assistance steer failed: $out"
  [ -f "$parent/state/sample.inbox/001.msg" ] || fail "the first assistance steer left no record"
  steer --captain-words "Owner instruction" "$BODY_A"
  [ "$rc" -ne 0 ] || fail "the identical assistance steer was accepted"
  assert_contains "$out" "001.msg" "the assistance refusal does not name the existing record"
  steer --again --captain-words "Owner instruction" "$BODY_A"
  [ "$rc" -eq 0 ] || fail "steer --again must write the repeat: $out"
  [ -f "$parent/state/sample.inbox/002.msg" ] || fail "steer --again left no 002.msg"
  pass "SD3: fm-assistance.sh steer refuses an identical body naming the record, and --again writes it"
}

test_sd1_identical_unhandled_steer_is_refused
test_sd1_identical_handled_steer_is_refused_inside_the_window
test_sd1_old_handled_steer_is_allowed_but_old_unhandled_is_not
test_sd1_log_only_until_the_switch_is_set
test_sd2_short_body_is_refused
test_sd3_again_writes_the_repeat
test_sd3_assistance_steer_applies_the_same_rule

echo "# fm-send-steer-dedupe.test.sh: all assertions passed"
