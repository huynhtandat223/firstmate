#!/usr/bin/env bash
# Behavior tests for bin/fm-verify-close.sh: the one way a row held as "verification pending"
# (left by bin/fm-teardown.sh for a landed user-visible task) reaches Done. The tasks-axi
# backlog is real; only the home around it is a fixture.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tasks-axi >/dev/null 2>&1 || { echo 'ok - skipped (tasks-axi is not installed)'; exit 0; }
unset TASKS_AXI_BACKEND || :

CLOSE="$ROOT/bin/fm-verify-close.sh"
TMP_ROOT=$(fm_test_tmproot fm-verify-close)
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

write_verify() {  # <home> <status>
  local home=$1 status=$2
  printf '%s\n' 'surface: user-visible' '## Acceptance' \
    '- A1 | the page shows the new button | pass | evidence: https://example.test/shot' \
    "- A2 | the button saves | $status | evidence: https://example.test/save" > "$home/data/$ID/verify.md"
  [ "$status" != pass ] || printf '%s\n' 'approved: firstmate 1792486840' >> "$home/data/$ID/verify.md"
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

test_incomplete_record_refuses_lists_problems_and_refreshes_the_reason() {
  local home
  home=$(make_home incomplete)
  add_row "$home" 'verification pending: an older gap'
  write_verify "$home" pending
  run_close "$home"
  [ "$CLOSE_RC" != 0 ] || fail "an incomplete record closed the row: $CLOSE_OUT"
  case "$CLOSE_OUT" in *"A2 is 'pending', not pass"*) ;; *) fail "the refusal does not list the problem: $CLOSE_OUT" ;; esac
  [ "$(field "$home" state)" = queued ] || fail "the refused row moved to '$(field "$home" state)'"
  [ "$(field "$home" held)" = yes ] || fail "the refused row lost its hold"
  case "$(field "$home" hold_reason)" in
    fm-hold-v1:*) ;;
    *) fail "the hold reason is not stored encoded: $(field "$home" hold_reason)" ;;
  esac
  case "$(printf '%s' "$(field "$home" hold_reason)" | sed 's/^fm-hold-v1://' | perl -MMIME::Base64 -e 'print decode_base64(<STDIN>)')" in
    "verification pending: "*"A2 is 'pending', not pass"*) ;;
    *) fail "the hold reason was not refreshed to the current gaps" ;;
  esac
  pass "an incomplete record refuses, lists the problems and refreshes the hold reason"
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

test_complete_record_lifts_the_hold_and_closes_the_row
test_incomplete_record_refuses_lists_problems_and_refreshes_the_reason
test_a_row_not_held_for_verification_is_refused_and_unchanged
