#!/usr/bin/env bash
# Behavior tests for the record: rows handoff of bin/fm-verify-close.sh: the head the rows passed on is
# written as the deploy event, an expired transient wait is cleared, --check writes nothing, and every
# missing item is named with its next action. The task writer is a stand-in that logs each call.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo 'ok - skipped (jq is not installed)'; exit 0; }

CLOSE="${CLOSE_OVERRIDE:-$ROOT/bin/fm-verify-close.sh}"
TMP_ROOT=$(fm_test_tmproot fm-verify-close-rows)
ID=page-task
H=1111111111111111111111111111111111111111
OLD=2222222222222222222222222222222222222222

WRITER="$TMP_ROOT/fake-fm-task.sh"
cat >"$WRITER" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_DIR/calls"
case "$1" in
  show) cat "$FAKE_DIR/task.json" ;;
  checks) case " $* " in *" --as-deployed "*) echo '{"rows":[]}' ;; *) cat "$FAKE_DIR/checks.json" ;; esac ;;
  unblock|start|done)
    st=ready; [ "$1" = start ] && st=running; [ "$1" = done ] && st=review
    jq --arg s "$st" '.state=$s|.blockKind=null' "$FAKE_DIR/task.json" >"$FAKE_DIR/t.new" && mv "$FAKE_DIR/t.new" "$FAKE_DIR/task.json" ;;
  approve) exit "${FAKE_APPROVE_RC:-0}" ;;
  *) exit 0 ;;
esac
SH
chmod +x "$WRITER"

# make_case <name> <state> <block-kind|-> <until|-> <row-status> <ask-head|->
make_case() {
  local d="$TMP_ROOT/$1"
  mkdir -p "$d/home/data/$ID" "$d/home/data/deploy-verify" "$d/home/state" "$d/home/config"
  printf 'surface: user-visible\nissue: task:%s\nrecord: rows\n' "$ID" >"$d/home/data/$ID/verify.md"
  jq -n --arg s "$2" --arg k "$3" --arg u "$4" \
    '{state:$s,stage:"pr",blockKind:(if $k=="-" then null else $k end),blockReason:"waiting",holdUntil:(if $u=="-" then null else $u end),lastSeq:7}' >"$d/task.json"
  jq -n --arg st "$5" --arg h "$H" \
    '{head:$h,rows:[{key:"DC1@390",surface:"user-visible",status:$st,nextActor:(if $st=="pass" then "firstmate" else "tester" end),head:(if $st=="pass" then $h else null end)}]}' >"$d/checks.json"
  : >"$d/home/data/deploy-verify/ledger.jsonl"
  [ "$6" = - ] || printf '{"type":"ask","round":"rows","task":"%s","head":"%s","sha":"%s","prs":[]}\n' "$ID" "$6" "$6" >"$d/home/data/deploy-verify/ledger.jsonl"
  : >"$d/calls"
  CASE=$d
}

run() {  # [--check]: OUT and RC
  RC=0
  OUT=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$CASE/home" FM_VERIFY_GATE_TASK="$WRITER" FAKE_DIR="$CASE" \
    FM_DEPLOY_VERIFY_REPO=example/repo "$CLOSE" "$@" "$ID" 2>&1) || RC=$?
}
writes() { grep -Ev '^(show|checks|approve) ' "$CASE/calls" || true; }

test_handoff_writes_the_deploy_event_with_the_ledger_head() {
  make_case pr-handoff review - - pass "$H"
  run --check
  [ "$RC" = 1 ] || fail "--check reported ready with no deploy event: $OUT"
  case "$OUT" in *"no deploy event for $ID on head $H"*) ;; *) fail "--check did not name the missing deploy event: $OUT" ;; esac
  [ -z "$(writes)" ] || fail "--check wrote: $(writes)"
  run
  [ "$RC" = 0 ] || fail "the handoff was refused: $OUT"
  case "$OUT" in *"approve ready task=$ID"*) ;; *) fail "the handoff did not report approve ready: $OUT" ;; esac
  grep -q "^event $ID deploy --head $H --touched none" "$CASE/calls" || fail "no deploy event with the ledger head: $(writes)"
  grep -qx "deployed: $H" "$CASE/home/data/$ID/verify.md" || fail "verify.md lacks the deployed head"
  case "$(writes)" in *approve*) fail "the handoff approved the task" ;; esac
  pass "the handoff writes the deploy event with the head the rows passed on and leaves approve to firstmate"
}

test_open_rows_are_named_and_nothing_is_written() {
  make_case open-rows review - - pending -
  run
  [ "$RC" = 1 ] || fail "open rows were accepted: $OUT"
  case "$OUT" in *"DC1@390 is pending for tester"*"ask-rows $ID"*) ;; *) fail "the open row and its next action are not named: $OUT" ;; esac
  [ -z "$(writes)" ] || fail "a refused handoff wrote: $(writes)"
  pass "open rows and a missing ask are named with their next action and nothing is written"
}

test_an_expired_transient_wait_is_cleared_before_the_deploy_event() {
  make_case expired blocked transient 2000-01-01T00:00:00Z pass "$H"
  run
  [ "$RC" = 0 ] || fail "an expired wait with passing rows was refused: $OUT"
  [ "$(writes | awk '{print $1}' | tr '\n' ' ')" = "unblock start done event " ] || fail "wrong write order: $(writes | tr '\n' '|')"
  make_case future blocked transient 2999-01-01T00:00:00Z pass "$H"
  run
  [ "$RC" = 1 ] || fail "a wait that has not expired was cleared: $OUT"
  case "$OUT" in *"still active"*) ;; *) fail "the active wait is not named: $OUT" ;; esac
  [ -z "$(writes)" ] || fail "an active wait caused writes: $(writes)"
  pass "a transient wait is cleared only when its date has passed and its rows pass"
}

test_handoff_writes_the_deploy_event_with_the_ledger_head
test_open_rows_are_named_and_nothing_is_written
test_an_expired_transient_wait_is_cleared_before_the_deploy_event
