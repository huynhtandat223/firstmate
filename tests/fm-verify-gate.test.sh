#!/usr/bin/env bash
# Behavior tests for bin/fm-verify-gate-lib.sh: the user-visible done gate reads firstmate's
# record and the Tester's record, and refuses unless every user-visible scenario x width of
# the issue passed in the Tester's record on the deployed head and firstmate approved later.
#
# Each case runs the real gate over fixture records and the real fm-acceptance.mjs parser; only
# gh is a stand-in (tests/verify-gate-helpers.sh). Each case takes the library to run, so the
# mutation proofs at the end remove one rule at a time and show the case that guards it go red.
# shellcheck disable=SC2016 # mutation proofs pass literal source patterns to perl
set -u
# shellcheck source=tests/verify-gate-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/verify-gate-helpers.sh"

command -v node >/dev/null 2>&1 || { printf 'skip - node is not installed\n'; exit 0; }
command -v jq >/dev/null 2>&1 || fail 'jq is required'

TMP_ROOT=$(fm_test_tmproot fm-verify-gate)
FX="$ROOT/tests/fixtures/fm-acceptance"
unset FM_TESTER_HOME FM_STATE_OVERRIDE
vg_install_gh "$TMP_ROOT/gh"
TASK=landed-ui

new_home() {  # prints a home with passing records
  local home
  home=$(mktemp -d "$TMP_ROOT/home.XXXXXX")
  vg_write_records "$home" "$TASK"
  printf '%s\n' "$home"
}

# Runs the gate from <lib>; output in $OUT, status in $RC.
run_gate() {  # <lib> <home>
  RC=0
  OUT=$(FM_HOME="$2" bash -c '. "$1"; fm_verify_gate_problems "$2/data" "$3" "$2"' _ "$1" "$2" "$TASK" 2>&1) || RC=$?
}

# The gate refused with a problem containing <text>.
refuses() {  # <lib> <home> <text>
  run_gate "$1" "$2"
  [ "$RC" -eq 1 ] || { echo "exit $RC, want 1: $OUT"; return 1; }
  case "$OUT" in *"$3"*) ;; *) echo "no problem names '$3': $OUT"; return 1 ;; esac
}
passes() {  # <lib> <home>
  run_gate "$1" "$2"
  [ "$RC" -eq 0 ] && [ -z "$OUT" ] || { echo "exit $RC, want a clean pass: $OUT"; return 1; }
}
tester() { vg_tester_file "$1" "$TASK"; }
firstmate() { printf '%s/data/%s/verify.md\n' "$1" "$TASK"; }
# Fixed-string line edits (awk, so they run the same on every platform).
drop() {  # <file> <line-prefix>: delete the lines that start with <line-prefix>
  awk -v p="$2" 'index($0, p) != 1' "$1" > "$1.new" && mv "$1.new" "$1"
}
set_line() {  # <file> <line-prefix> <new-line>
  awk -v p="$2" -v n="$3" 'index($0, p) == 1 { print n; next } { print }' "$1" > "$1.new" && mv "$1.new" "$1"
}
insert_before() {  # <file> <line-prefix> <new-line>
  awk -v p="$2" -v n="$3" 'index($0, p) == 1 { print n } { print }' "$1" > "$1.new" && mv "$1.new" "$1"
}
row() {  # <id> <state> <evidence-field>
  printf -- '- %s | WHEN a row is read, THE gate SHALL check it. | %s | %s\n' "$1" "$2" "$3"
}

# ---- cases: each returns 0 when the behavior holds ----------------------------------

# Passing records pass, and the gate changes neither record.
case_pass_and_read_only() {
  local home sum
  home=$(new_home)
  passes "$1" "$home" || return 1
  drop "$(tester "$home")" '- A2@390 '
  sum=$(cat "$(tester "$home")" "$(firstmate "$home")" "$home/data/deploy-verify/ledger.jsonl" | sha256sum)
  refuses "$1" "$home" 'A2@390' || return 1
  [ "$sum" = "$(cat "$(tester "$home")" "$(firstmate "$home")" "$home/data/deploy-verify/ledger.jsonl" | sha256sum)" ] \
    || { echo 'the gate changed a record'; return 1; }
}

case_firstmate_record_missing() {
  local home
  home=$(new_home)
  rm "$(firstmate "$home")"
  refuses "$1" "$home" 'firstmate verification record missing'
}

case_tester_record_missing() {
  local home
  home=$(new_home)
  rm "$(tester "$home")"
  refuses "$1" "$home" "Tester record missing: $(tester "$home")"
}

case_no_tester_home() {
  local home
  home=$(new_home)
  rm "$home/state/tester.meta"
  refuses "$1" "$home" 'Tester record missing: no Tester home'
}

# FM_TESTER_HOME beats the home= line of state/tester.meta.
case_tester_home_override() {
  local home
  home=$(new_home)
  printf 'home=%s\n' "$home/elsewhere" > "$home/state/tester.meta"
  refuses "$1" "$home" 'Tester record missing' || return 1
  RC=0
  OUT=$(FM_TESTER_HOME="$home/tester" FM_HOME="$home" bash -c '. "$1"; fm_verify_gate_problems "$2/data" "$3" "$2"' _ "$1" "$home" "$TASK" 2>&1) || RC=$?
  [ "$RC" -eq 0 ] && [ -z "$OUT" ] || { echo "FM_TESTER_HOME was not used: $OUT"; return 1; }
}

case_firstmate_line_one() {
  local home
  home=$(new_home)
  set_line "$(firstmate "$home")" 'surface: ' 'surface: internal'
  refuses "$1" "$home" "line 1 of $(firstmate "$home") must be 'surface: user-visible'"
}

case_firstmate_issue_line() {
  local home
  home=$(new_home)
  drop "$(firstmate "$home")" 'issue: '
  refuses "$1" "$home" "firstmate record has no 'issue: <url>' line"
}

case_tester_surface() {
  local home
  home=$(new_home)
  set_line "$(tester "$home")" 'surface: ' 'surface: internal'
  refuses "$1" "$home" "Tester record needs 'surface: user-visible' (found 'internal')"
}

case_tester_issue_line() {
  local home
  home=$(new_home)
  drop "$(tester "$home")" 'issue: '
  refuses "$1" "$home" "Tester record has no 'issue: <url>' line"
}

case_records_name_different_issues() {
  local home
  home=$(new_home)
  set_line "$(tester "$home")" 'issue: ' 'issue: https://github.com/o/r/issues/10'
  refuses "$1" "$home" 'the records name different issues'
}

# An issue the parser refuses is listed problem by problem; an unreadable one says so.
case_issue_cannot_be_parsed() {
  local home body
  home=$(new_home)
  body="$TMP_ROOT/bad.body"
  printf '## Scenarios\n\n- [ ] K1 WHEN x, THE y SHALL z.\n' > "$body"
  VG_BODY_FILE=$body refuses "$1" "$home" "issue $VG_ISSUE cannot be read: missing section ## Context" || return 1
  case "$OUT" in *'missing section ## Decisions'*) ;; *) echo "not every parser problem is listed: $OUT"; return 1 ;; esac
}

case_issue_cannot_be_read() {
  local home
  home=$(new_home)
  VG_GH_FAIL=1 refuses "$1" "$home" "issue $VG_ISSUE cannot be read"
}

case_issue_without_user_visible_rows() {
  local home body
  home=$(new_home)
  body="$TMP_ROOT/internal.body"
  printf '%s\n' '## Acceptance' '' '- [ ] K3 WHEN the gate runs, THE gate SHALL refuse.' '  - env/page: Dev 5001' \
    '  - proof: a test' '  - data: none' '  - mock: none' '  - surface: internal' > "$body"
  VG_BODY_FILE=$body refuses "$1" "$home" "issue $VG_ISSUE has no user-visible scenario row"
}

case_row_absent_from_tester_record() {
  local home
  home=$(new_home)
  drop "$(tester "$home")" '- A2@390 '
  refuses "$1" "$home" 'A2@390 is missing from the Tester record' || return 1
  [ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" = 1 ] || { echo "more than the one missing row: $OUT"; return 1; }
}

case_row_not_pass() {
  local home
  home=$(new_home)
  set_line "$(tester "$home")" '- A1@1440 ' "$(row A1@1440 pending 'evidence: https://example.test/shot')"
  refuses "$1" "$home" "A1@1440 is 'pending', not pass"
}

case_row_without_evidence_field() {
  local home
  home=$(new_home)
  set_line "$(tester "$home")" '- A1@390 ' "$(row A1@390 pass shot.png)"
  refuses "$1" "$home" "A1@390 has no 'evidence:' field"
}

case_row_pass_without_evidence() {
  local home
  home=$(new_home)
  set_line "$(tester "$home")" '- A1@390 ' "$(row A1@390 pass 'evidence: -')"
  refuses "$1" "$home" 'A1@390 is pass without evidence'
}

# An evidence path must exist: absolute as written, relative under the Tester home.
case_row_evidence_path() {
  local home
  home=$(new_home)
  set_line "$(tester "$home")" '- A1@390 ' "$(row A1@390 pass "evidence: $home/no-such.png")"
  refuses "$1" "$home" "A1@390 evidence path does not exist: $home/no-such.png" || return 1
  set_line "$(tester "$home")" '- A1@390 ' "$(row A1@390 pass 'evidence: shots/a1.png')"
  refuses "$1" "$home" 'A1@390 evidence path does not exist: shots/a1.png' || return 1
  mkdir -p "$home/tester/shots"
  : > "$home/tester/shots/a1.png"
  passes "$1" "$home"
}

case_row_id_not_in_issue() {
  local home
  home=$(new_home)
  insert_before "$(tester "$home")" 'verified: ' "$(row A9@1440 pass 'evidence: https://example.test/x')"
  refuses "$1" "$home" "A9@1440 is not a row of $VG_ISSUE"
}

# A retired row is allowed for an id the issue dropped; for an id it still has it is not a pass.
case_retired_row() {
  local home
  home=$(new_home)
  insert_before "$(tester "$home")" 'verified: ' "$(row A9@1440 retired 'evidence: -')"
  passes "$1" "$home" || return 1
  set_line "$(tester "$home")" '- A1@1440 ' "$(row A1@1440 retired 'evidence: -')"
  refuses "$1" "$home" "A1@1440 is 'retired', not pass"
}

# A scenario of the issue that is not user-visible is not a gate row; its Tester row is ignored.
case_internal_scenario_row() {
  local home
  home=$(new_home)
  insert_before "$(tester "$home")" 'verified: ' "$(row K3@- pass 'evidence: https://example.test/x')"
  passes "$1" "$home"
}

case_malformed_tester_row() {
  local home
  home=$(new_home)
  insert_before "$(tester "$home")" 'verified: ' '- A1@1440 pass'
  refuses "$1" "$home" 'malformed Tester row'
}

# The verified line closes the record: rows appended or changed after an old footer are not
# covered by it, and a scenario row outside '## Scenarios' is never skipped.
case_verified_line_closes_the_record() {
  local home tf
  home=$(new_home)
  tf=$(tester "$home")
  drop "$tf" '- A2@390 '
  printf '%s\n' "$(row A2@390 pass 'evidence: https://example.test/late')" >> "$tf"
  refuses "$1" "$home" "the 'verified: tester' line must come after the last scenario row" || return 1
  home=$(new_home)
  tf=$(tester "$home")
  printf '%s\n' '' '## Notes' "$(row A1@1440 pass 'evidence: https://example.test/x')" >> "$tf"
  refuses "$1" "$home" "scenario row outside '## Scenarios'"
}

case_verified_line_missing() {
  local home
  home=$(new_home)
  drop "$(tester "$home")" 'verified: '
  refuses "$1" "$home" "Tester record has no 'verified: tester <epoch> head=<sha>' line"
}

case_verified_line_without_head() {
  local home
  home=$(new_home)
  set_line "$(tester "$home")" 'verified: ' 'verified: tester 1000'
  refuses "$1" "$home" 'Tester verified line has no head=<sha>'
}

# The deployed head is the newest deploy or replay ask of this task: a newer deploy refuses an
# older record, a draft round and another task's ask do not count.
case_deployed_head_is_the_newest_ask() {
  local home old=2222222222222222222222222222222222222222 ledger
  home=$(new_home)
  ledger="$home/data/deploy-verify/ledger.jsonl"
  set_line "$(tester "$home")" 'verified: ' "verified: tester 1000 head=$old"
  printf '{"type":"ask","round":"deploy","key":"deploy:%s:%s","task":"%s","sha":"%s"}\n' "$TASK" "$old" "$TASK" "$old" > "$ledger"
  passes "$1" "$home" || return 1
  printf '{"type":"ask","round":"deploy","key":"replay:%s:%s","task":"%s","sha":"%s"}\n' "$TASK" "$VG_SHA" "$TASK" "$VG_SHA" >> "$ledger"
  refuses "$1" "$home" "Tester head $old is not the deployed head $VG_SHA" || return 1
  printf '{"type":"ask","round":"draft","key":"draft:%s:1:%s","task":"%s","sha":"%s"}\n' "$TASK" "$old" "$TASK" "$old" >> "$ledger"
  printf '{"type":"ask","round":"deploy","key":"deploy:other:%s","task":"other","sha":"%s"}\n' "$old" "$old" >> "$ledger"
  refuses "$1" "$home" "Tester head $old is not the deployed head $VG_SHA" || return 1
  set_line "$(tester "$home")" 'verified: ' "verified: tester 1000 head=$VG_SHA"
  passes "$1" "$home"
}

# A repo deploy-verify does not watch has no ask: firstmate's own deployed: line is the head.
case_deployed_line_without_an_ask() {
  local home
  home=$(new_home)
  : > "$home/data/deploy-verify/ledger.jsonl"
  refuses "$1" "$home" "no deployed head for $TASK" || return 1
  insert_before "$(firstmate "$home")" 'approved: ' "deployed: $VG_SHA"
  passes "$1" "$home" || return 1
  set_line "$(firstmate "$home")" 'deployed: ' 'deployed: 3333333333333333333333333333333333333333'
  refuses "$1" "$home" "Tester head $VG_SHA is not the deployed head 3333333333333333333333333333333333333333"
}

case_approval() {
  local home
  home=$(new_home)
  drop "$(firstmate "$home")" 'approved: '
  refuses "$1" "$home" "missing 'approved: firstmate <epoch>' line" || return 1
  printf 'approved: firstmate soon\n' >> "$(firstmate "$home")"
  refuses "$1" "$home" 'approved line needs a numeric epoch' || return 1
  set_line "$(firstmate "$home")" 'approved: ' 'approved: firstmate 999'
  refuses "$1" "$home" "approved: firstmate 999 is not newer than the Tester's verified epoch 1000" || return 1
  set_line "$(firstmate "$home")" 'approved: ' 'approved: firstmate 1000'
  refuses "$1" "$home" "approved: firstmate 1000 is not newer" || return 1
  set_line "$(firstmate "$home")" 'approved: ' 'approved: firstmate 1001'
  passes "$1" "$home"
}

# The home.video case of 3a: V3 and V4 proven at 1440 only, on the draft head, while the
# official row was deployed later.
case_home_video() {
  local home draft=4444444444444444444444444444444444444444 rows id missing
  home=$(new_home)
  rows=$(node "$ROOT/bin/fm-acceptance.mjs" rows - < "$FX/cfw-1616.body" | awk -F' [|] ' '{sub(/^- /, "", $1); print $1}')
  {
    printf '%s\n' 'surface: user-visible' "issue: $VG_ISSUE" '' '## Scenarios'
    printf '%s\n' '- V3@1440 | the Video page lists matching files | pass | evidence: https://example.test/v3' \
      '- V4@1440 | the Video page shows Không tìm thấy | pass | evidence: https://example.test/v4'
    printf '\nverified: tester 1000 head=%s\n' "$draft"
  } > "$(tester "$home")"
  VG_BODY_FILE="$FX/cfw-1616.body" refuses "$1" "$home" "Tester head $draft is not the deployed head $VG_SHA" || return 1
  missing=0
  for id in $rows; do
    case "$id" in V3@1440|V4@1440) continue ;; esac
    case "$OUT" in *"$id is missing from the Tester record"*) missing=$((missing + 1)) ;; *) echo "$id is not named: $OUT"; return 1 ;; esac
  done
  [ "$missing" = 20 ] || { echo "$missing missing rows named, want 20"; return 1; }
}

CASES="pass_and_read_only firstmate_record_missing tester_record_missing no_tester_home tester_home_override
firstmate_line_one firstmate_issue_line tester_surface tester_issue_line records_name_different_issues
issue_cannot_be_parsed issue_cannot_be_read issue_without_user_visible_rows row_absent_from_tester_record
row_not_pass row_without_evidence_field row_pass_without_evidence row_evidence_path row_id_not_in_issue retired_row
internal_scenario_row malformed_tester_row verified_line_closes_the_record verified_line_missing verified_line_without_head
deployed_head_is_the_newest_ask deployed_line_without_an_ask approval home_video"

# ---- real gate ------------------------------------------------------------------------

# FM_VERIFY_GATE_TEST_LIB runs the cases against another library (the gate of main, for the
# red-first run), and FM_VERIFY_GATE_TEST_CASES names the cases; neither runs the mutations.
for c in ${FM_VERIFY_GATE_TEST_CASES:-$CASES}; do
  out=$(case_"$c" "${FM_VERIFY_GATE_TEST_LIB:-$ROOT/bin/fm-verify-gate-lib.sh}" 2>&1) || fail "case $c failed on the real gate: $out"
  pass "fm-verify-gate $c"
done
[ -z "${FM_VERIFY_GATE_TEST_LIB:-}${FM_VERIFY_GATE_TEST_CASES:-}" ] || exit 0

# ---- mutation proofs: remove one rule, the case guarding it goes red ---------------------

MBIN="$TMP_ROOT/mbin"
mkdir -p "$MBIN"
cp "$ROOT/bin/fm-acceptance.mjs" "$MBIN/fm-acceptance.mjs"
cp "$ROOT/bin/fm-verify-gate-lib.sh" "$TMP_ROOT/gate.orig"
MLIB="$MBIN/fm-verify-gate-lib.sh"

mutate() {  # <label> <case> <perl-substitution>
  cp "$TMP_ROOT/gate.orig" "$MLIB"
  perl -0pi -e "$3" "$MLIB"
  cmp -s "$TMP_ROOT/gate.orig" "$MLIB" && fail "mutation '$1' changed nothing"
  bash -n "$MLIB" || fail "mutation '$1' broke the library's syntax"
  if out=$(case_"$2" "$MLIB" 2>&1); then
    fail "removing the rule '$1' left case $2 green"
  fi
  pass "rule '$1' is needed: case $2 goes red without it"
}
# Drop the problem a rule reports: the call turns into a no-op that does not close the gate.
unsay() {  # <label> <case> <message-prefix>
  P=$3 mutate "$1" "$2" 's/\Qfm_verify_gate_say "$ENV{P}\E/: "$ENV{P}/g'
}

unsay 'firstmate record is required' firstmate_record_missing 'firstmate verification record missing'
unsay 'the Tester record is required' tester_record_missing 'Tester record missing: $tfile'
unsay 'a Tester home is required' no_tester_home 'Tester record missing: no Tester home'
mutate 'FM_TESTER_HOME overrides tester.meta' tester_home_override 's/tester_home=\$\{FM_TESTER_HOME:-\}/tester_home=/'
unsay 'line 1 is the user-visible surface' firstmate_line_one 'line 1 of'
unsay 'firstmate names the issue' firstmate_issue_line "firstmate record has no 'issue:"
unsay 'the Tester surface is user-visible' tester_surface "Tester record needs 'surface: user-visible'"
unsay 'the Tester names the issue' tester_issue_line "Tester record has no 'issue:"
unsay 'both records name one issue' records_name_different_issues 'the records name different issues'
mutate 'the issue problems are listed' issue_cannot_be_parsed 's/\n\s*printf .%s. "\$parse" \| jq -r --arg i[^\n]*/\n        :/'
unsay 'an unreadable issue is a problem' issue_cannot_be_read 'issue $issue cannot be read'
unsay 'an issue needs user-visible rows' issue_without_user_visible_rows 'issue $issue has no user-visible scenario row'
unsay 'every issue row must be in the Tester record' row_absent_from_tester_record '$rid is missing from the Tester record'
unsay 'a row must be pass' row_not_pass '$rid is '"'"'$rstate'"'"', not pass'
unsay 'a pass row has an evidence field' row_without_evidence_field '$rid has no '"'"'evidence:'"'"' field'
unsay 'a pass row has evidence' row_pass_without_evidence '$1 is pass without evidence'
unsay 'an evidence path must exist' row_evidence_path '$1 evidence path does not exist'
unsay 'a Tester row id must be in the issue' row_id_not_in_issue '$rid is not a row of'
mutate 'a retired row is allowed for a dropped id' retired_row 's/\[ "\$rstate" = retired \] \|\|/false ||/'
unsay 'a retired row is not a pass for a present id' retired_row '$rid is '"'"'$rstate'"'"', not pass'
mutate 'only user-visible rows are gate rows' internal_scenario_row 's/--surface all 2>\/dev\/null\) \|\| all_rows=\$rows/--surface user-visible 2>\/dev\/null) || all_rows=\$rows/'
unsay 'a Tester row is well formed' malformed_tester_row 'malformed Tester row'
unsay 'the verified line follows the last row' verified_line_closes_the_record "the 'verified: tester' line must come after"
unsay 'a scenario row outside Scenarios is refused' verified_line_closes_the_record "scenario row outside"
unsay 'the verified line is required' verified_line_missing "Tester record has no 'verified: tester"
unsay 'the verified line names a head' verified_line_without_head 'Tester verified line has no head='
unsay 'the Tester head is the deployed head' deployed_head_is_the_newest_ask 'Tester head '
mutate 'the newest ask is the deployed head' deployed_head_is_the_newest_ask 's/\| tail -n 1\n\}/| head -n 1\n}/'
mutate 'a draft round is not a deploy' deployed_head_is_the_newest_ask 's/\.round == "deploy" and //'
mutate 'only the task'"'"'s own asks count' deployed_head_is_the_newest_ask 's/ and \.task == \$t//'
unsay 'a deployed head is required' deployed_line_without_an_ask 'no deployed head for'
mutate 'the deployed line stands in for a missing ask' deployed_line_without_an_ask 's/want_sha=\$\{ask_sha:-\$deployed\}/want_sha=\$ask_sha/'
unsay 'approval is required' approval "missing 'approved: firstmate"
unsay 'approval is a number' approval 'approved line needs a numeric epoch'
unsay 'approval is newer than the Tester' approval 'approved: firstmate $approved is not newer'
mutate 'an equal epoch is not newer' approval 's/"\$approved" -le "\$v_epoch"/"\$approved" -lt "\$v_epoch"/'
unsay 'the home.video draft head is refused' home_video 'Tester head '
pass 'every rule of the gate has a red mutation proof'
