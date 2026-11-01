#!/usr/bin/env bash
# Behavior tests for bin/fm-verify-close.sh: the one way a row held as "verification pending"
# (left by bin/fm-teardown.sh for a landed user-visible task) reaches Done. The tasks-axi
# backlog is real; only the home around it is a fixture.
set -u

# shellcheck source=tests/verify-gate-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/verify-gate-helpers.sh"

command -v tasks-axi >/dev/null 2>&1 || { echo 'ok - skipped (tasks-axi is not installed)'; exit 0; }
unset TASKS_AXI_BACKEND || :

CLOSE="$ROOT/bin/fm-verify-close.sh"
TMP_ROOT=$(fm_test_tmproot fm-verify-close)
vg_install_gh "$TMP_ROOT/gh"
# The closed task has no endpoint record; deploy-verify finds its PR on its backlog line.
export FM_DEPLOY_VERIFY_REPO=example/repo
cd "$TMP_ROOT" || exit 1
ID=landed-ui
PR=https://github.com/example/repo/pull/7

make_home() {  # <name>: a home with an empty markdown backlog
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config" "$home/data/$ID"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$home/data/backlog.md"
  printf '%s\n' 'backend = "markdown"' '' '[markdown]' 'path = "data/backlog.md"' > "$home/.tasks.toml"
  printf '%s\n' "$home"
}

encode() { printf 'fm-hold-v1:%s' "$(printf '%s' "$1" | perl -MMIME::Base64=encode_base64 -0777 -ne 'print encode_base64($_, "")')"; }

# A queued row with its PR recorded, held as teardown leaves it.
add_row() {  # <home> <hold-reason-plain> [hold-kind]
  local home=$1 reason=$2 kind=${3:-external}
  tasks-axi add "$ID" "landed UI change" --kind ship --file "$home/data/backlog.md" >/dev/null
  tasks-axi update "$ID" --pr "$PR" --file "$home/data/backlog.md" >/dev/null
  tasks-axi hold "$ID" --reason "$(encode "$reason")" --kind "$kind" --file "$home/data/backlog.md" >/dev/null
}

# The gate's two records for the fixture issue (tests/verify-gate-helpers.sh): every row passes
# unless <status> is not pass, which leaves the A2 row at 390 in that state.
write_verify() {  # <home> <status>
  local home=$1 status=$2
  vg_write_records "$home" "$ID" none
  [ "$status" = pass ] || vg_set_row "$home" "$ID" A2@390 "$status" 'evidence: -'
}

show() { tasks-axi show "$ID" --file "$1/data/backlog.md" --full 2>/dev/null; }
field() { show "$1" | sed -n "s/^  $2: *//p" | head -1 | tr -d '"'; }

run_close() {  # <home>: output in $CLOSE_OUT, status in $CLOSE_RC
  CLOSE_RC=0
  CLOSE_OUT=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$1" "$CLOSE" "$ID" 2>&1) || CLOSE_RC=$?
}

test_complete_record_lifts_the_hold_and_closes_the_row() {
  local home before
  home=$(make_home complete)
  add_row "$home" 'verification pending: A2 is pending, not pass'
  write_verify "$home" pass
  before=$(show "$home")
  case "$before" in *'held: yes'*) ;; *) fail "fixture row is not held: $before" ;; esac
  run_close "$home"
  [ "$CLOSE_RC" = 0 ] || fail "a complete record was refused: $CLOSE_OUT"
  [ "$(field "$home" state)" = "done" ] || fail "the row is '$(field "$home" state)', want done: $CLOSE_OUT"
  [ "$(field "$home" held)" = no ] || fail "the closed row is still held"
  case "$(show "$home")" in *"pull/7"*) ;; *) fail "the PR recorded at teardown was lost: $(show "$home")" ;; esac
  case "$(field "$home" closed)" in "$(date +%Y-%m-%d)") ;; *) fail "the close date is not today: $(field "$home" closed)" ;; esac
  pass "a complete record lifts the hold and moves the row to Done with its PR"
}

# Complete-looking evidence in the worker or firstmate home cannot replace the Tester.
test_local_evidence_cannot_replace_the_testers_own_record() {
  local home source
  for source in firstmate worker; do
    home=$(make_home "only-$source")
    add_row "$home" 'verification pending: Tester proof missing'
    write_verify "$home" pass
    if [ "$source" = firstmate ]; then
      cat "$(vg_tester_file "$home" "$ID")" >> "$home/data/$ID/verify.md"
    else
      cp "$(vg_tester_file "$home" "$ID")" "$home/data/$ID/notes.md"
    fi
    rm "$(vg_tester_file "$home" "$ID")"
    run_close "$home"
    [ "$CLOSE_RC" != 0 ] || fail "$source evidence closed the row without the Tester: $CLOSE_OUT"
    case "$CLOSE_OUT" in *'Tester record missing:'*) ;; *) fail "missing Tester not reported: $CLOSE_OUT" ;; esac
    [ "$(field "$home" state)" = queued ] && [ "$(field "$home" held)" = yes ] || fail "$source-only row lost its hold"
  done
  pass "firstmate and worker evidence cannot replace the Tester's own-home record"
}

test_incomplete_record_refuses_lists_problems_and_refreshes_the_reason() {
  local home
  home=$(make_home incomplete)
  add_row "$home" 'verification pending: an older gap'
  write_verify "$home" pending
  run_close "$home"
  [ "$CLOSE_RC" != 0 ] || fail "an incomplete record closed the row: $CLOSE_OUT"
  case "$CLOSE_OUT" in *"A2@390 is 'pending', not pass"*) ;; *) fail "the refusal does not list the problem: $CLOSE_OUT" ;; esac
  [ "$(field "$home" state)" = queued ] || fail "the refused row moved to '$(field "$home" state)'"
  [ "$(field "$home" held)" = yes ] || fail "the refused row lost its hold"
  case "$(field "$home" hold_reason)" in
    fm-hold-v1:*) ;;
    *) fail "the hold reason is not stored encoded: $(field "$home" hold_reason)" ;;
  esac
  case "$(printf '%s' "$(field "$home" hold_reason)" | sed 's/^fm-hold-v1://' | perl -MMIME::Base64 -e 'print decode_base64(<STDIN>)')" in
    "verification pending: "*"A2@390 is 'pending', not pass"*) ;;
    *) fail "the hold reason was not refreshed to the current gaps" ;;
  esac
  pass "an incomplete record refuses, lists the problems and refreshes the hold reason"
}

# A newer deploy of the task sends a new ask; the Tester's record is for the older head, so
# the close stays refused until the Tester verifies again.
test_a_newer_deploy_refuses_the_close_until_the_tester_verifies_again() {
  local home newer=2222222222222222222222222222222222222222
  home=$(make_home newer-deploy)
  add_row "$home" 'verification pending: an older gap'
  write_verify "$home" pass
  printf '{"type":"ask","round":"deploy","key":"deploy:%s:%s","task":"%s","sha":"%s"}\n' "$ID" "$newer" "$ID" "$newer" \
    >> "$home/data/deploy-verify/ledger.jsonl"
  run_close "$home"
  [ "$CLOSE_RC" != 0 ] || fail "a record for an older deploy closed the row: $CLOSE_OUT"
  case "$CLOSE_OUT" in *"is not the deployed head $newer"*) ;; *) fail "the refusal does not name the deployed head: $CLOSE_OUT" ;; esac
  [ "$(field "$home" state)" = queued ] && [ "$(field "$home" held)" = yes ] || fail "the refused row changed: $(show "$home")"
  sed -i.bak "s/head=[0-9a-f]*/head=$newer/" "$(vg_tester_file "$home" "$ID")"
  run_close "$home"
  [ "$CLOSE_RC" = 0 ] && [ "$(field "$home" state)" = "done" ] || fail "the re-verified record did not close the row: $CLOSE_OUT"
  pass "a newer deploy refuses the close until the Tester's record names that head"
}

test_a_row_not_held_for_verification_is_refused_and_unchanged() {
  local home before
  # Already Done.
  home=$(make_home done-row)
  tasks-axi add "$ID" "landed UI change" --kind ship --file "$home/data/backlog.md" >/dev/null
  tasks-axi start "$ID" --file "$home/data/backlog.md" >/dev/null
  tasks-axi "done" "$ID" --file "$home/data/backlog.md" >/dev/null
  write_verify "$home" pass
  before=$(show "$home")
  run_close "$home"
  [ "$CLOSE_RC" != 0 ] && [ "$(show "$home")" = "$before" ] || fail "a Done row was not refused unchanged: $CLOSE_OUT"
  # Open and not held.
  home=$(make_home unheld-row)
  tasks-axi add "$ID" "landed UI change" --kind ship --file "$home/data/backlog.md" >/dev/null
  write_verify "$home" pass
  before=$(show "$home")
  run_close "$home"
  [ "$CLOSE_RC" != 0 ] && [ "$(show "$home")" = "$before" ] || fail "an unheld row was not refused unchanged: $CLOSE_OUT"
  # A captain hold, even with a verification pending reason.
  home=$(make_home captain-row)
  add_row "$home" 'verification pending: A2 is pending, not pass' captain
  write_verify "$home" pass
  before=$(show "$home")
  run_close "$home"
  [ "$CLOSE_RC" != 0 ] && [ "$(show "$home")" = "$before" ] || fail "a captain hold was not refused unchanged: $CLOSE_OUT"
  # An external hold for another reason.
  home=$(make_home other-hold)
  add_row "$home" 'upstream release pending'
  write_verify "$home" pass
  before=$(show "$home")
  run_close "$home"
  [ "$CLOSE_RC" != 0 ] && [ "$(show "$home")" = "$before" ] || fail "another hold was not refused unchanged: $CLOSE_OUT"
  # No such row.
  home=$(make_home no-row)
  write_verify "$home" pass
  run_close "$home"
  [ "$CLOSE_RC" != 0 ] || fail "a missing row was not refused: $CLOSE_OUT"
  pass "a Done, unheld, captain-held or otherwise held row is refused and left unchanged"
}

# A landed task that was an open captain call keeps its captain hold and gains a
# "Verification pending:" body line at teardown. Answering or releasing that call must
# resolve it without moving an unverified task to Done.
captain_row() {  # <home> [marker 1|0] [body-line 1|0]: a captain-held row as teardown leaves it
  local home=$1 marker=${2:-1} line=${3:-1} body
  add_row "$home" 'which colour should the button be' captain
  body=$(mktemp "$TMP_ROOT/body.XXXXXX")
  if [ "$line" = 1 ]; then
    printf '%s\n' 'Verification pending: A2 is '"'"'pending'"'"', not pass' > "$body"
  else
    printf '%s\n' 'The captain call on the button colour.' > "$body"
  fi
  tasks-axi update "$ID" --body-file "$body" --file "$home/data/backlog.md" >/dev/null
  rm -f "$body"
  mkdir -p "$home/data/$ID"
  if [ "$marker" = 1 ]; then printf 'verification pending\n' > "$home/data/$ID/verify-pending"; fi
}

run_answer() {  # <home> [--release]: output in $ANSWER_OUT, status in $ANSWER_RC
  local home=$1
  shift
  printf 'blue\n' > "$home/decision.txt"
  ANSWER_RC=0
  ANSWER_OUT=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" "$ROOT/bin/fm-captain-hold.sh" answer "$ID" \
    --decision-file "$home/decision.txt" "$@" 2>&1) || ANSWER_RC=$?
}

check_pending_after_answer() {  # <home> <label>
  local home=$1 label=$2
  [ "$ANSWER_RC" = 0 ] || fail "$label: the answer failed: $ANSWER_OUT"
  [ "$(field "$home" state)" != "done" ] || fail "$label: an unverified task reached Done"
  [ "$(field "$home" held)" = yes ] || fail "$label: the open row is not held"
  [ "$(field "$home" hold_kind)" = external ] || fail "$label: the hold is '$(field "$home" hold_kind)', want external"
  case "$(printf '%s' "$(field "$home" hold_reason)" | sed 's/^fm-hold-v1://' | perl -MMIME::Base64 -e 'print decode_base64(<STDIN>)')" in
    "verification pending: "*"A2@390 is 'pending', not pass"*) ;;
    *) fail "$label: the hold reason does not name the missing items: $(field "$home" hold_reason)" ;;
  esac
}

test_answering_a_verification_pending_captain_call_keeps_it_open() {
  local home before
  home=$(make_home answer-pending)
  captain_row "$home"
  write_verify "$home" pending
  run_answer "$home"
  check_pending_after_answer "$home" answer
  case "$(show "$home")" in *"Captain decision"*|*"blue"*) ;; *) fail "answer: the decision was not recorded on the row" ;; esac
  before=$(show "$home")
  run_answer "$home"
  [ "$ANSWER_RC" = 0 ] || fail "answer: an exact retry failed: $ANSWER_OUT"
  [ "$(show "$home")" = "$before" ] || fail "answer: an exact retry changed the row"
  run_close "$home"
  [ "$CLOSE_RC" != 0 ] || fail "answer: the close helper accepted an incomplete record"
  write_verify "$home" pass
  run_close "$home"
  [ "$CLOSE_RC" = 0 ] && [ "$(field "$home" state)" = "done" ] || fail "answer: a complete record did not close the row: $CLOSE_OUT"
  pass "answering a verification-pending captain call keeps the row open and held until the record is complete"
}

# Firstmate rewrites task bodies routinely, so the body line is a note and never the proof.
test_a_body_edit_cannot_turn_a_verification_pending_call_into_done() {
  local home
  home=$(make_home body-edited)
  captain_row "$home" 1 0
  write_verify "$home" pending
  run_answer "$home"
  check_pending_after_answer "$home" edited-body
  pass "a captain call stays held for verification when its body line was edited away"
}

test_an_unrelated_body_line_without_the_marker_closes_normally() {
  local home
  home=$(make_home no-marker)
  captain_row "$home" 0 1
  write_verify "$home" pending
  run_answer "$home"
  [ "$ANSWER_RC" = 0 ] || fail "no marker: the answer failed: $ANSWER_OUT"
  [ "$(field "$home" state)" = "done" ] || fail "no marker: an unrelated body line held the call (state '$(field "$home" state)')"
  pass "a body line with the same text but no teardown marker does not hold a captain call"
}

test_a_repeated_keyed_answer_for_a_verification_pending_row_is_not_skipped() {
  local home out
  home=$(make_home keyed-retry)
  captain_row "$home"
  write_verify "$home" pending
  out=$(printf '%s\tblue\t\t\n' "$ID" | FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" "$ROOT/bin/fm-captain-hold.sh" answers --source "fixture" 2>&1) \
    || fail "the first keyed answer failed: $out"
  case "$out" in *"closed: $ID"*) ;; *) fail "the first keyed answer was not accepted: $out" ;; esac
  out=$(printf '%s\tblue\t\t\n' "$ID" | FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" "$ROOT/bin/fm-captain-hold.sh" answers --source "fixture" 2>&1) \
    || fail "the repeated keyed answer was skipped: $out"
  case "$out" in *"closed: $ID"*) ;; *) fail "the repeated keyed answer was not reported closed: $out" ;; esac
  [ "$(field "$home" state)" != "done" ] && [ "$(field "$home" hold_kind)" = external ] \
    || fail "the repeated keyed answer changed the row: $(show "$home")"
  pass "a repeated keyed answer for a verification-pending row is an idempotent close, not a skip"
}

# Teardown publishes its pending-close record before the transition runs. A crash between the two
# leaves the record and the live row; a captain answer in that window must not reach Done.
test_a_crash_after_the_pending_close_record_does_not_bypass_verification() {
  local home
  home=$(make_home crash-window)
  captain_row "$home" 0 0
  write_verify "$home" pending
  mkdir -p "$home/state"
  (
    cd "$home" || exit 1
    # shellcheck source=bin/fm-tasks-axi-lib.sh
    . "$ROOT/bin/fm-tasks-axi-lib.sh"
    # shellcheck source=bin/fm-backlog-transition-lib.sh
    . "$ROOT/bin/fm-backlog-transition-lib.sh"
    # shellcheck source=bin/fm-hold-reason-lib.sh
    . "$ROOT/bin/fm-hold-reason-lib.sh"
    fm_backlog_close_marker_write "$home/state" "$ID" "$home/data" 1792000000-1 \
      --verify-pending "$(fm_hold_reason_encode "A2 is pending, not pass")" --pr "$PR"
  ) || fail "the pending-close record could not be published"
  [ -f "$home/state/$ID.backlog-close" ] || fail "the pending-close record is missing"
  run_answer "$home"
  check_pending_after_answer "$home" crash-window
  pass "a captain answer between the pending-close record and the transition keeps the row held"
}

test_releasing_a_verification_pending_captain_call_keeps_it_held() {
  local home
  home=$(make_home release-pending)
  captain_row "$home"
  write_verify "$home" pending
  run_answer "$home" --release
  check_pending_after_answer "$home" release
  pass "releasing a verification-pending captain call holds it as verification pending"
}

test_answering_with_a_complete_record_closes_the_row() {
  local home
  home=$(make_home answer-complete)
  captain_row "$home"
  write_verify "$home" pass
  run_answer "$home"
  [ "$ANSWER_RC" = 0 ] || fail "a complete record: the answer failed: $ANSWER_OUT"
  [ "$(field "$home" state)" = "done" ] || fail "a complete record: the row is '$(field "$home" state)', want done"
  pass "answering with a complete record closes the row as before"
}

# A tasks-axi shim that logs each call, then runs the real one.
shim_tasks_axi() {  # <log>: prepends the shim dir to PATH
  local log=$1 real
  real=$(command -v tasks-axi)
  mkdir -p "$TMP_ROOT/shim"
  cat > "$TMP_ROOT/shim/tasks-axi" <<SHIM
#!/usr/bin/env bash
printf '%s\\n' "\$1" >> $(printf '%q' "$log")
exec $(printf '%q' "$real") "\$@"
SHIM
  chmod +x "$TMP_ROOT/shim/tasks-axi"
  PATH="$TMP_ROOT/shim:$PATH"
}

test_closing_is_one_mutation_and_never_leaves_an_unheld_open_row() {
  local home log="$TMP_ROOT/close-calls.log" saved=$PATH
  home=$(make_home one-mutation)
  add_row "$home" 'verification pending: A2 is pending, not pass'
  write_verify "$home" pass
  printf 'verification pending\n' > "$home/data/$ID/verify-pending"
  : > "$log"
  shim_tasks_axi "$log"
  run_close "$home"
  PATH=$saved
  [ "$CLOSE_RC" = 0 ] || fail "a complete record was refused: $CLOSE_OUT"
  [ ! -e "$home/data/$ID/verify-pending" ] || fail "closing left the verification-pending marker"
  grep -qx 'done' "$log" || fail "the close never ran tasks-axi done: $(tr '\n' ' ' < "$log")"
  ! grep -qx 'unhold' "$log" || fail "the close lifted the hold before done: $(tr '\n' ' ' < "$log")"
  pass "closing a verification-pending row is one done mutation, with no unheld open interval"
}

test_teardown_holds_the_row_before_it_leaves_in_flight() {
  local home log="$TMP_ROOT/hold-calls.log" saved=$PATH hold_line reopen_line
  home=$(make_home hold-first)
  tasks-axi add "$ID" "landed UI change" --kind ship --file "$home/data/backlog.md" >/dev/null
  tasks-axi start "$ID" --file "$home/data/backlog.md" >/dev/null
  : > "$log"
  shim_tasks_axi "$log"
  (
    cd "$home" || exit 1
    # shellcheck source=bin/fm-tasks-axi-lib.sh
    . "$ROOT/bin/fm-tasks-axi-lib.sh"
    # shellcheck source=bin/fm-backlog-transition-lib.sh
    . "$ROOT/bin/fm-backlog-transition-lib.sh"
    # shellcheck source=bin/fm-hold-reason-lib.sh
    . "$ROOT/bin/fm-hold-reason-lib.sh"
    fm_backlog_verify_pending "$home/data" "$ID" "$(encode "A2 is pending, not pass")" --pr "$PR"
  ) || fail "fm_backlog_verify_pending failed"
  PATH=$saved
  hold_line=$(grep -nx 'hold' "$log" | head -1 | cut -d: -f1)
  reopen_line=$(grep -nx 'reopen' "$log" | head -1 | cut -d: -f1)
  [ -n "$hold_line" ] && [ -n "$reopen_line" ] && [ "$hold_line" -lt "$reopen_line" ] \
    || fail "the row was reopened before it was held: $(tr '\n' ' ' < "$log")"
  [ "$(field "$home" held)" = yes ] && [ "$(field "$home" hold_kind)" = external ] && [ "$(field "$home" state)" = queued ] \
    || fail "the row did not end held as external and queued: $(show "$home")"
  [ -f "$home/data/$ID/verify-pending" ] || fail "teardown left no verification-pending marker"
  pass "teardown holds the row before it reopens it, so it is never queued and unheld"
}

# Dev 5001 stores a hold reason in fm_task.backlog_hold_reason, which holds 2000 characters;
# a longer value refuses the row write after its event is stored (HTTP 400 VALIDATION_ERROR).
# This shim refuses the same way, so a task with many missing rows shows whether teardown
# still holds its row.
shim_reason_limit() {  # prepends the shim dir to PATH
  local real
  real=$(command -v tasks-axi)
  mkdir -p "$TMP_ROOT/limit-shim"
  cat > "$TMP_ROOT/limit-shim/tasks-axi" <<SHIM
#!/usr/bin/env bash
prev=
for arg in "\$@"; do
  if [ "\$prev" = --reason ] && [ "\${#arg}" -gt 2000 ]; then
    echo "HTTP 400 VALIDATION_ERROR: backlogHoldReason exceeds 2000 characters" >&2
    exit 1
  fi
  prev=\$arg
done
exec $(printf '%q' "$real") "\$@"
SHIM
  chmod +x "$TMP_ROOT/limit-shim/tasks-axi"
  PATH="$TMP_ROOT/limit-shim:$PATH"
}

test_teardown_holds_a_row_with_many_missing_items_within_the_reason_limit() {
  local home saved=$PATH items='' n reason kept more
  home=$(make_home many-missing)
  tasks-axi add "$ID" "landed UI change" --kind ship --file "$home/data/backlog.md" >/dev/null
  tasks-axi start "$ID" --file "$home/data/backlog.md" >/dev/null
  # One item per line, as teardown records them; each item's own text holds "; ".
  for n in $(seq 1 40); do
    items="${items:+$items
}EN$n@1440 has no check row in the record; run rows"
  done
  shim_reason_limit
  (
    cd "$home" || exit 1
    # shellcheck source=bin/fm-tasks-axi-lib.sh
    . "$ROOT/bin/fm-tasks-axi-lib.sh"
    # shellcheck source=bin/fm-backlog-transition-lib.sh
    . "$ROOT/bin/fm-backlog-transition-lib.sh"
    fm_backlog_verify_pending "$home/data" "$ID" "$(encode "$items")" --pr "$PR"
  ) || { PATH=$saved; fail "teardown could not hold a row with 40 missing items: the reason is over the field limit"; }
  PATH=$saved
  [ "$(field "$home" held)" = yes ] && [ "$(field "$home" hold_kind)" = external ] \
    || fail "the row did not end held as external: $(show "$home")"
  reason=$(tasks-axi show "$ID" --file "$home/data/backlog.md" --full 2>/dev/null | sed -n 's/^  hold_reason: *//p' | tr -d '"')
  [ "${#reason}" -le 2000 ] || fail "the stored reason is ${#reason} characters, over the 2000 limit"
  reason=$(printf '%s' "${reason#fm-hold-v1:}" | perl -MMIME::Base64=decode_base64 -0777 -ne 'print decode_base64($_)')
  case "$reason" in
    "verification pending: EN1@1440 has no check row"*"; and "*" more (bin/fm-verify-close.sh $ID lists all)") ;;
    *) fail "the cut reason does not keep the first items and count the rest: $reason" ;;
  esac
  case "$reason" in *$'\n'*) fail "the stored reason is not one line of \"; \"-joined items: $reason" ;; esac
  kept=$(printf '%s' "$reason" | grep -o 'EN[0-9]*@1440 has no check row in the record; run rows' | wc -l)
  more=$(printf '%s' "$reason" | sed -n 's/.*; and \([0-9]*\) more (bin.*/\1/p')
  [ "$((kept + more))" -eq 40 ] || fail "the cut reason keeps $kept items and counts $more more, not 40 in all: $reason"
  pass "teardown holds a row with many missing items within the 5001 hold-reason limit"
}

# A pending-close record written before items went one per line holds them "; "-joined; replaying
# one whose items fit the field keeps every item rather than counting them as one.
test_a_legacy_joined_record_keeps_its_items() {
  local home items='' n reason
  home=$(make_home legacy-joined)
  tasks-axi add "$ID" "landed UI change" --kind ship --file "$home/data/backlog.md" >/dev/null
  tasks-axi start "$ID" --file "$home/data/backlog.md" >/dev/null
  # Each legacy item holds "; " itself, so its pieces cannot be counted as items.
  for n in $(seq 1 40); do items="${items:+$items; }EN$n@1440 has no check row in the record; run rows"; done
  (
    cd "$home" || exit 1
    # shellcheck source=bin/fm-tasks-axi-lib.sh
    . "$ROOT/bin/fm-tasks-axi-lib.sh"
    # shellcheck source=bin/fm-backlog-transition-lib.sh
    . "$ROOT/bin/fm-backlog-transition-lib.sh"
    fm_backlog_verify_pending "$home/data" "$ID" "$(encode "$items")" --pr "$PR"
  ) || fail "a legacy joined record could not be held"
  reason=$(tasks-axi show "$ID" --file "$home/data/backlog.md" --full 2>/dev/null | sed -n 's/^  hold_reason: *//p' | tr -d '"')
  reason=$(printf '%s' "${reason#fm-hold-v1:}" | perl -MMIME::Base64=decode_base64 -0777 -ne 'print decode_base64($_)')
  case "$reason" in
    "verification pending: EN1@1440 has no check row in the record; run rows; EN2@1440"*"; and more (bin/fm-verify-close.sh $ID lists all)") ;;
    *) fail "a legacy joined record lost its items or claimed a count it cannot know: $reason" ;;
  esac
  [ "${#reason}" -le 1400 ] || fail "a legacy cut reason is ${#reason} characters, over its limit"
  pass "a legacy \"; \"-joined record keeps its items in the cut reason"
}

test_complete_record_lifts_the_hold_and_closes_the_row
test_local_evidence_cannot_replace_the_testers_own_record
test_incomplete_record_refuses_lists_problems_and_refreshes_the_reason
test_a_newer_deploy_refuses_the_close_until_the_tester_verifies_again
test_a_row_not_held_for_verification_is_refused_and_unchanged
test_answering_a_verification_pending_captain_call_keeps_it_open
test_releasing_a_verification_pending_captain_call_keeps_it_held
test_answering_with_a_complete_record_closes_the_row
test_closing_is_one_mutation_and_never_leaves_an_unheld_open_row
test_teardown_holds_the_row_before_it_leaves_in_flight
test_a_body_edit_cannot_turn_a_verification_pending_call_into_done
test_an_unrelated_body_line_without_the_marker_closes_normally
test_a_repeated_keyed_answer_for_a_verification_pending_row_is_not_skipped
test_a_crash_after_the_pending_close_record_does_not_bypass_verification
test_teardown_holds_a_row_with_many_missing_items_within_the_reason_limit
test_a_legacy_joined_record_keeps_its_items
