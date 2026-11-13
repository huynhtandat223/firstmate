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
  gate) if [ -s "$FAKE_DIR/gate_out" ]; then cat "$FAKE_DIR/gate_out"; exit 5; fi ;;
  *) exit 0 ;;
esac
SH
chmod +x "$WRITER"

GH="$TMP_ROOT/fake-gh.sh"
cat >"$GH" <<'SH'
#!/usr/bin/env bash
# A compare call: prints the status in $FAKE_DIR/gh_status, or fails when it says FAIL.
st=$(cat "$FAKE_DIR/gh_status" 2>/dev/null || echo FAIL)
[ "$st" != FAIL ] || exit 1
echo "$st"
SH
chmod +x "$GH"

# Optional case settings, reset by make_case: PR (the task's PR url), DEPLOYED (a deployed: line), ROW_ACTOR
# (next actor of a pending row), ASK_ROUND and ASK_EXTRA (a second ask head), GH_STATUS (compare answer).
PR=- DEPLOYED=- ROW_ACTOR=- ASK_ROUND=rows ASK_EXTRA=- GH_STATUS=FAIL GATE_OUT=

# make_case <name> <state> <block-kind|-> <until|-> <row-status> <ask-head|->
make_case() {
  local d="$TMP_ROOT/$1" ask
  mkdir -p "$d/home/data/$ID" "$d/home/data/deploy-verify" "$d/home/state" "$d/home/config"
  printf 'surface: user-visible\nissue: task:%s\nrecord: rows\n' "$ID" >"$d/home/data/$ID/verify.md"
  [ "$DEPLOYED" = - ] || printf 'deployed: %s\n' "$DEPLOYED" >>"$d/home/data/$ID/verify.md"
  jq -n --arg s "$2" --arg k "$3" --arg u "$4" --arg pr "$PR" \
    '{state:$s,stage:"pr",blockKind:(if $k=="-" then null else $k end),blockReason:"waiting",holdUntil:(if $u=="-" then null else $u end),prUrl:(if $pr=="-" then null else $pr end),lastSeq:7}' >"$d/task.json"
  jq -n --arg st "$5" --arg h "$H" --arg a "$ROW_ACTOR" \
    '{head:$h,rows:[{key:"DC1@390",surface:"user-visible",status:$st,nextActor:(if $st=="pass" then "firstmate" elif $a=="-" then "tester" else $a end),head:(if $st=="pass" then $h else null end)}]}' >"$d/checks.json"
  : >"$d/home/data/deploy-verify/ledger.jsonl"
  for ask in "$6" "$ASK_EXTRA"; do
    [ "$ask" = - ] || printf '{"type":"ask","round":"%s","task":"%s","head":"%s","sha":"%s","tester":"running","prs":[]}\n' "$ASK_ROUND" "$ID" "$ask" "$ask" >>"$d/home/data/deploy-verify/ledger.jsonl"
  done
  echo "$GH_STATUS" >"$d/gh_status"
  printf '%s' "$GATE_OUT" >"$d/gate_out"
  : >"$d/calls"
  CASE=$d
  PR=- DEPLOYED=- ROW_ACTOR=- ASK_ROUND=rows ASK_EXTRA=- GH_STATUS=FAIL GATE_OUT=
}

run() {  # [--check]: OUT and RC
  RC=0
  OUT=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$CASE/home" FM_VERIFY_GATE_TASK="$WRITER" FAKE_DIR="$CASE" \
    FM_VERIFY_GATE_GH="$GH" FM_DEPLOY_VERIFY_REPO=example/repo "$CLOSE" "$@" "$ID" 2>&1) || RC=$?
}
writes() { grep -Ev '^(show|checks|approve|gate) ' "$CASE/calls" || true; }

test_handoff_writes_the_deploy_event_with_the_ledger_head() {
  make_case pr-handoff review - - pass "$H"
  run --check
  [ "$RC" = 1 ] || fail "--check reported ready with no deploy event: $OUT"
  case "$OUT" in *"no deploy event for $ID on head $H"*) ;; *) fail "--check did not name the missing deploy event: $OUT" ;; esac
  [ -z "$(writes)" ] || fail "--check wrote: $(writes)"
  run
  [ "$RC" = 0 ] || fail "the handoff was refused: $OUT"
  case "$OUT" in *"approve ready task=$ID"*) ;; *) fail "the handoff did not report approve ready: $OUT" ;; esac
  grep -q "^event $ID deploy --role firstmate --head $H --touched none" "$CASE/calls" || fail "no deploy event with the ledger head: $(writes)"
  grep -qx "deployed: $H" "$CASE/home/data/$ID/verify.md" || fail "verify.md lacks the deployed head"
  case "$(writes)" in *approve*) fail "the handoff approved the task" ;; esac
  grep -q "^gate $ID --issue task:$ID --head $H .*--before-approval --touched none" "$CASE/calls" || fail "the handoff did not read the record before approval: $(grep '^gate ' "$CASE/calls")"
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

test_a_row_with_no_head_looks_up_the_ask_on_the_deployed_head() {
  PR=https://github.com/example/repo/pull/5 ASK_ROUND=deploy
  make_case no-head-row review - - pending "$H"
  run --check
  [ "$RC" = 1 ] || fail "an open row was accepted: $OUT"
  case "$OUT" in *"no verify ask in ledger"*) fail "a false missing-ask item is printed though the deploy ask exists: $OUT" ;; esac
  case "$OUT" in *"DC1@390 is pending for tester on $H (running)"*"bin/fm-task.sh check $ID DC1@390 pass|fail"*"--head $H"*) ;; *) fail "the deployed head and its Tester are not named: $OUT" ;; esac
  pass "a pending row with no head names the ask on the deployed head and its Tester"
}

test_a_pending_worker_row_prints_check_not_changes() {
  ROW_ACTOR=worker
  make_case worker-row review - - pending -
  run --check
  [ "$RC" = 1 ] || fail "a pending worker row was accepted: $OUT"
  case "$OUT" in *"DC1@390 is pending for worker"*"bin/fm-task.sh check $ID DC1@390 pass|fail"*) ;; *) fail "the pending worker row does not name the check command: $OUT" ;; esac
  case "$OUT" in *"bin/fm-task.sh changes"*) fail "a pending row is sent back as a defect: $OUT" ;; esac
  pass "a pending worker row prints the check command and never changes"
}

test_the_handoff_writes_as_firstmate() {
  make_case role blocked transient 2000-01-01T00:00:00Z pass "$H"
  run
  [ "$RC" = 0 ] || fail "the handoff was refused: $OUT"
  [ -n "$(writes)" ] || fail "no write was made"
  while IFS= read -r line; do
    case "$line" in *"--role firstmate"*) ;; *) fail "a write is not recorded as firstmate: $line" ;; esac
  done < <(writes)
  pass "every write of the handoff passes --role firstmate"
}

test_an_approved_task_prints_already_approved() {
  make_case approved "done" - - pass "$H"
  run
  [ "$RC" = 0 ] || fail "an approved task was refused: $OUT"
  case "$OUT" in "already approved task=$ID"*) ;; *) fail "an approved task is not reported as approved: $OUT" ;; esac
  case "$OUT" in *"approve ready"*) fail "an approved task is reported as approve ready: $OUT" ;; esac
  pass "a task already done prints already approved"
}

test_a_transient_wait_without_a_valid_until_date_is_not_cleared() {
  local until
  for until in - not-a-date; do
    make_case "no-until-$until" blocked transient "$until" pass "$H"
    run
    [ "$RC" = 1 ] || fail "a wait with until '$until' was cleared: $OUT"
    case "$OUT" in *"no valid until date"*"bin/fm-task.sh unblock $ID"*) ;; *) fail "the missing date and the unblock command are not named for '$until': $OUT" ;; esac
    [ -z "$(writes)" ] || fail "a wait with until '$until' caused writes: $(writes)"
  done
  pass "a transient wait with no valid until date names unblock and writes nothing"
}

test_a_pr_outside_the_repo_keeps_its_recorded_deployed_line() {
  PR=https://github.com/other/repo/pull/9
  make_case other-pr-none review - - pass "$H"
  run
  [ "$RC" = 1 ] || fail "a PR outside the repo was taken from a rows ask: $OUT"
  case "$OUT" in *"outside example/repo"*"deployed:"*) ;; *) fail "the missing deployed line is not named: $OUT" ;; esac
  [ -z "$(writes)" ] || fail "a refused handoff wrote: $(writes)"
  ! grep -q '^deployed:' "$CASE/home/data/$ID/verify.md" || fail "the rows ask head was written as the deployed line"
  PR=https://github.com/other/repo/pull/9 DEPLOYED="$OLD"
  make_case other-pr-recorded review - - pass "$H"
  run
  [ "$RC" = 0 ] || fail "a recorded deployed line was refused: $OUT"
  grep -q "^event $ID deploy .*--head $OLD " "$CASE/calls" || fail "the deploy event does not carry the recorded deployed head: $(writes)"
  [ "$(grep -c '^deployed:' "$CASE/home/data/$ID/verify.md")" = 1 ] || fail "the recorded deployed line was replaced or repeated"
  pass "a PR outside the repo keeps its deployed line and is refused without one"
}

test_deployed_heads_that_cannot_be_ordered_are_refused() {
  local gh
  for gh in FAIL diverged; do
    PR=https://github.com/example/repo/pull/5 ASK_ROUND=deploy ASK_EXTRA="$OLD" GH_STATUS=$gh
    make_case "order-$gh" review - - pass "$H"
    run
    [ "$RC" = 1 ] || fail "unorderable heads ($gh) were accepted: $OUT"
    case "$OUT" in *"cannot order the deployed heads"*"$H"*"$OLD"*) ;; *) fail "the heads that could not be compared are not named ($gh): $OUT" ;; esac
    [ -z "$(writes)" ] || fail "a refused handoff ($gh) wrote: $(writes)"
  done
  PR=https://github.com/example/repo/pull/5 ASK_ROUND=deploy ASK_EXTRA="$OLD" GH_STATUS=ahead
  make_case order-ahead review - - pass "$H"
  run
  [ "$RC" = 0 ] || fail "ordered heads were refused: $OUT"
  grep -q "^event $ID deploy .*--head $OLD " "$CASE/calls" || fail "the later head was not written: $(writes)"
  pass "deployed heads that cannot be ordered are refused and named"
}

test_a_ready_task_is_never_advanced_to_review() {
  local mode
  make_case ready ready - - pass "$H"
  for mode in --check ""; do
    run $mode
    [ "$RC" = 1 ] || fail "a ready task (returned by changes) was accepted${mode:+ in $mode}: $OUT"
    case "$OUT" in *"$ID is in state ready, not review"*) ;; *) fail "the ready state is not named${mode:+ in $mode}: $OUT" ;; esac
    [ -z "$(writes)" ] || fail "a ready task caused writes: $(writes)"
  done
  pass "a task that is ready for any reason but a cleared transient wait is refused and nothing is written"
}

test_rows_without_evidence_or_a_current_digest_are_refused_before_any_write() {
  local mode
  GATE_OUT=$'DC1@390 is pass without evidence\nTester acceptance old is not the issue\'s current digest new\n'
  make_case gate blocked transient 2000-01-01T00:00:00Z pass "$H"
  for mode in --check ""; do
    run $mode
    [ "$RC" = 1 ] || fail "rows the task record rejects were accepted${mode:+ in $mode}: $OUT"
    case "$OUT" in *"task record gate: DC1@390 is pass without evidence"*"task record gate: Tester acceptance old"*) ;; *) fail "the gate's reasons are not named${mode:+ in $mode}: $OUT" ;; esac
    [ -z "$(writes)" ] || fail "rows the record rejects caused writes: $(writes)"
  done
  pass "evidence and digest problems from the task record gate refuse the handoff before any write"
}

# A deploy whose PRs were all skipped writes no deploy-round ask, only a skip line and a `deployed` line: the rows ask
# on its head then counts as a deployed head, so rows that passed on it are no longer refused as "no verify ask".
test_a_deployed_line_makes_the_rows_ask_head_a_deployed_head() {
  PR=https://github.com/example/repo/pull/6 ASK_ROUND=rows
  make_case deployed-line review - - pass "$H"
  run --check
  [ "$RC" = 1 ] || fail "rows passed on a head no deploy line names were accepted: $OUT"
  case "$OUT" in *"passed on $H, which has no verify ask"*) ;; *) fail "the undeployed head is not named: $OUT" ;; esac
  printf '{"type":"skip","pr":"https://github.com/example/repo/pull/6","task":"%s","reason":"no-issue"}\n' "$ID" >>"$CASE/home/data/deploy-verify/ledger.jsonl"
  run --check
  case "$OUT" in *"passed on $H, which has no verify ask"*) ;; *) fail "a skip line proved a deploy: $OUT" ;; esac
  printf '{"type":"deployed","sha":"%s","run":"https://example.test/runs/1","completed":"2026-11-13T07:00:00Z","at":1}\n' "$H" >>"$CASE/home/data/deploy-verify/ledger.jsonl"
  run --check
  case "$OUT" in *"which has no verify ask"*) fail "a deployed line did not prove the deploy: $OUT" ;; esac
  case "$OUT" in *"no deploy event for $ID on head $H"*) ;; *) fail "the head is not the ledger head: $OUT" ;; esac
  [ -z "$(writes)" ] || fail "--check wrote: $(writes)"
  pass "a deployed line makes the head of a rows ask the deployed head, and a skip line does not"
}

test_handoff_writes_the_deploy_event_with_the_ledger_head
test_open_rows_are_named_and_nothing_is_written
test_an_expired_transient_wait_is_cleared_before_the_deploy_event
test_a_row_with_no_head_looks_up_the_ask_on_the_deployed_head
test_a_deployed_line_makes_the_rows_ask_head_a_deployed_head
test_a_pending_worker_row_prints_check_not_changes
test_the_handoff_writes_as_firstmate
test_an_approved_task_prints_already_approved
test_a_transient_wait_without_a_valid_until_date_is_not_cleared
test_a_pr_outside_the_repo_keeps_its_recorded_deployed_line
test_deployed_heads_that_cannot_be_ordered_are_refused
test_a_ready_task_is_never_advanced_to_review
test_rows_without_evidence_or_a_current_digest_are_refused_before_any_write
