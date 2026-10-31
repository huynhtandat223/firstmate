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
row() {  # <id> <state> <evidence-field>: the issue's text for A1, A2 and K3, a stand-in text for any other id
  local text='WHEN a row is read, THE gate SHALL check it.'
  case "$1" in
    A1@*) text='WHEN a user acts, THE page SHALL answer.' ;;
    A2@*) text='WHEN a user saves, THE page SHALL keep the row.' ;;
    K3@*) text='WHEN the gate runs, THE gate SHALL refuse.' ;;
  esac
  printf -- '- %s | %s | %s | %s\n' "$1" "$text" "$2" "$3"
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

# Retired is for an id the issue dropped, not for one width of an id it still has.
case_retired_row_of_a_present_id_at_another_width() {
  local home
  home=$(new_home)
  insert_before "$(tester "$home")" 'verified: ' "$(row A1@1024 retired 'evidence: -')"
  refuses "$1" "$home" 'A1@1024 is retired, but the issue still has A1'
}

# A scenario of the issue that is not user-visible is not a gate row; its Tester row is ignored.
case_internal_scenario_row() {
  local home
  home=$(new_home)
  insert_before "$(tester "$home")" 'verified: ' "$(row K3@- pass 'evidence: https://example.test/x')"
  passes "$1" "$home"
}

# A scenario edited after the Tester checked it is not re-verified by an old row: the row's
# line must be the issue's current text for that id and width.
case_row_text_differs_from_the_issue() {
  local home tf
  home=$(new_home)
  tf=$(tester "$home")
  set_line "$tf" '- A1@1440 ' '- A1@1440 | WHEN a user acts, THE page SHALL answer slowly. | pass | evidence: https://example.test/shot'
  refuses "$1" "$home" "A1@1440 line differs from the issue: Tester 'WHEN a user acts, THE page SHALL answer slowly.', issue 'WHEN a user acts, THE page SHALL answer.'" || return 1
  [ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" = 1 ] || { echo "more than the one changed row: $OUT"; return 1; }
  # Surrounding blanks do not count as a difference.
  set_line "$tf" '- A1@1440 ' '- A1@1440 |   WHEN a user acts, THE page SHALL answer.  | pass | evidence: https://example.test/shot'
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

# The Tester's footer carries the digest of the issue's scenarios as the Tester read them: a
# scenario edited in a field the rows omit (controls, proof, data, mock, page) is not re-verified
# by an old record.
case_acceptance_digest() {
  local home current body
  home=$(new_home)
  current=$(vg_digest)
  body="$TMP_ROOT/edited.body"
  sed 's/click Save/click Save twice/' "$TMP_ROOT/gh/issue.body" > "$body"
  cmp -s "$body" "$TMP_ROOT/gh/issue.body" && { echo 'the edit changed nothing'; return 1; }
  VG_BODY_FILE=$body refuses "$1" "$home" "Tester acceptance $current is not the issue's current digest $(VG_BODY_FILE=$body vg_digest)" || return 1
  set_line "$(tester "$home")" 'verified: ' "verified: tester 1000 head=$VG_SHA"
  refuses "$1" "$home" "Tester verified line has no acceptance=<digest>"
}

case_verified_line_missing() {
  local home
  home=$(new_home)
  drop "$(tester "$home")" 'verified: '
  refuses "$1" "$home" "Tester record has no 'verified: tester <epoch> head=<sha> acceptance=<digest>' line"
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
  set_line "$(tester "$home")" 'verified: ' "verified: tester 1000 head=$old acceptance=$(vg_digest)"
  printf '{"type":"ask","round":"deploy","key":"deploy:%s:%s","task":"%s","sha":"%s"}\n' "$TASK" "$old" "$TASK" "$old" > "$ledger"
  passes "$1" "$home" || return 1
  printf '{"type":"ask","round":"deploy","key":"replay:%s:%s","task":"%s","sha":"%s"}\n' "$TASK" "$VG_SHA" "$TASK" "$VG_SHA" >> "$ledger"
  refuses "$1" "$home" "Tester head $old is not the deployed head $VG_SHA" || return 1
  printf '{"type":"ask","round":"draft","key":"draft:%s:1:%s","task":"%s","sha":"%s"}\n' "$TASK" "$old" "$TASK" "$old" >> "$ledger"
  printf '{"type":"ask","round":"deploy","key":"deploy:other:%s","task":"other","sha":"%s"}\n' "$old" "$old" >> "$ledger"
  refuses "$1" "$home" "Tester head $old is not the deployed head $VG_SHA" || return 1
  set_line "$(tester "$home")" 'verified: ' "verified: tester 1000 head=$VG_SHA acceptance=$(vg_digest)"
  passes "$1" "$home"
}

# deploy-verify maps a task by its PR (the endpoint record's pr=, else the PR on the task's backlog
# line), so the PR's repo decides: a PR in the watched repo needs a deploy ask, and a deployed:
# line stands in only for a PR in another repo. The issue's repo plays no part.
set_pr() {  # <home> <pr-url>
  printf 'kind=ship\npr=%s\n' "$2" > "$1/state/$TASK.meta"
}

case_a_pr_in_the_watched_repo_needs_an_ask() {
  local home other=https://github.com/x/y/issues/9
  home=$(new_home)
  passes "$1" "$home" || return 1
  : > "$home/data/deploy-verify/ledger.jsonl"
  insert_before "$(firstmate "$home")" 'approved: ' "deployed: $VG_SHA"
  refuses "$1" "$home" "no deploy ask for $TASK in" || return 1
  case "$OUT" in *'a deployed: line does not stand in for it'*) ;; *) echo "the refusal does not say the deployed: line is not accepted: $OUT"; return 1 ;; esac
  # The issue in another repo changes nothing: the PR is still in the watched repo.
  set_line "$(firstmate "$home")" 'issue: ' "issue: $other"
  set_line "$(tester "$home")" 'issue: ' "issue: $other"
  refuses "$1" "$home" "no deploy ask for $TASK in" || return 1
  printf '{"type":"ask","round":"deploy","key":"deploy:%s:%s","task":"%s","sha":"%s"}\n' "$TASK" "$VG_SHA" "$TASK" "$VG_SHA" \
    > "$home/data/deploy-verify/ledger.jsonl"
  drop "$(firstmate "$home")" 'deployed: '
  passes "$1" "$home"
}

case_a_pr_in_another_repo_takes_the_deployed_line() {
  local home
  home=$(new_home)
  set_pr "$home" https://github.com/x/y/pull/5
  : > "$home/data/deploy-verify/ledger.jsonl"
  refuses "$1" "$home" "no deployed head for $TASK" || return 1
  insert_before "$(firstmate "$home")" 'approved: ' "deployed: $VG_SHA"
  passes "$1" "$home" || return 1
  set_line "$(firstmate "$home")" 'deployed: ' 'deployed: 3333333333333333333333333333333333333333'
  refuses "$1" "$home" "Tester head $VG_SHA is not the deployed head 3333333333333333333333333333333333333333" || return 1
  # An ask in the ledger does not count for a PR deploy-verify does not map.
  printf '{"type":"ask","round":"deploy","key":"deploy:%s:%s","task":"%s","sha":"%s"}\n' "$TASK" "$VG_SHA" "$TASK" "$VG_SHA" \
    > "$home/data/deploy-verify/ledger.jsonl"
  refuses "$1" "$home" "is not the deployed head 3333333333333333333333333333333333333333"
}

# A finished task has no endpoint record; its PR is on its backlog line.
case_the_backlog_line_names_the_pr() {
  local home
  home=$(new_home)
  rm "$home/state/$TASK.meta"
  printf '%s\n' '## Done' "- [x] $TASK - landed UI change https://github.com/x/y/pull/5 (kind: ship) (closed 2026-10-24)" > "$home/data/backlog.md"
  : > "$home/data/deploy-verify/ledger.jsonl"
  refuses "$1" "$home" "no deployed head for $TASK" || return 1
  printf '%s\n' '## Done' "- [x] $TASK - landed UI change https://github.com/o/r/pull/5 (kind: ship) (closed 2026-10-24)" > "$home/data/backlog.md"
  refuses "$1" "$home" "no deploy ask for $TASK in" || return 1
  # Another task's PR does not make this one watched.
  printf '%s\n' '## Done' "- [x] $TASK - landed UI change https://github.com/x/y/pull/5 (kind: ship)" \
    '- [x] other - other change https://github.com/o/r/pull/6 (kind: ship)' > "$home/data/backlog.md"
  refuses "$1" "$home" "no deployed head for $TASK"
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
    printf '\nverified: tester 1000 head=%s acceptance=%s\n' "$draft" "$(VG_BODY_FILE="$FX/cfw-1616.body" vg_digest)"
  } > "$(tester "$home")"
  VG_BODY_FILE="$FX/cfw-1616.body" refuses "$1" "$home" "Tester head $draft is not the deployed head $VG_SHA" || return 1
  missing=0
  for id in $rows; do
    case "$id" in V3@1440|V4@1440) continue ;; esac
    case "$OUT" in *"$id is missing from the Tester record"*) missing=$((missing + 1)) ;; *) echo "$id is not named: $OUT"; return 1 ;; esac
  done
  [ "$missing" = 20 ] || { echo "$missing missing rows named, want 20"; return 1; }
}

# ---- tasks begun after T5: firstmate's record says 'record: rows', and the task record is read ----------------

# A stand-in for bin/fm-task.sh: it records its arguments and the writer settings it was given, then prints
# FAKE_OUT, writes FAKE_ERR to stderr and exits FAKE_RC.
FAKE_TASK="$TMP_ROOT/fake-fm-task.sh"
cat > "$FAKE_TASK" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$FAKE_ARGS"
printf 'url=%s\n' "${FM_TASK_BASE_URL:-}" >> "$FAKE_ARGS"
[ -z "${FAKE_OUT:-}" ] || printf '%s\n' "$FAKE_OUT"
[ -z "${FAKE_ERR:-}" ] || printf '%s\n' "$FAKE_ERR" >&2
exit "${FAKE_RC:-0}"
SH
chmod +x "$FAKE_TASK"
export FM_VERIFY_GATE_TASK="$FAKE_TASK"

rows_home() {  # prints a home whose task was begun after T5: no Tester file and no approved: line
  local home
  home=$(new_home)
  rm "$(tester "$home")"
  drop "$(firstmate "$home")" 'approved: '
  printf 'record: rows\n' >> "$(firstmate "$home")"
  printf '%s\n' "$home"
}

# The task record is the word on a marked task: the gate asks it about the issue on the deployed head with the Tester
# home as the evidence root, and passes on its clean answer without the Tester file or an approved: line.
case_rows_read_the_record() {
  local home
  home=$(rows_home)
  export FAKE_ARGS="$home/fake.args"
  FAKE_RC=0 passes "$1" "$home" || return 1
  [ "$(sed -n 1p "$FAKE_ARGS")" = "gate $TASK --issue $VG_ISSUE --head $VG_SHA --evidence-root $home/tester" ] \
    || { echo "the record was asked: $(sed -n 1p "$FAKE_ARGS" 2>&1)"; return 1; }
}

# Each reason the record gives is one gate problem.
case_rows_problems() {
  local home
  home=$(rows_home)
  export FAKE_ARGS="$home/fake.args"
  FAKE_RC=5 FAKE_OUT=$'A1@1440 is \'fail\', not pass\nno approved event for landed-ui' FAKE_ERR='fm-task: gate: landed-ui is not complete' \
    refuses "$1" "$home" "A1@1440 is 'fail', not pass" || return 1
  case "$OUT" in *'no approved event for landed-ui'*) ;; *) echo "the second reason is lost: $OUT"; return 1 ;; esac
  case "$OUT" in *'is not complete'*) echo "the writer's summary line became a problem: $OUT"; return 1 ;; esac
}

# A record that cannot be read refuses, naming why.
case_rows_record_unreadable() {
  local home
  home=$(rows_home)
  export FAKE_ARGS="$home/fake.args"
  FAKE_RC=3 FAKE_ERR='fm-task: GET /api/fm_task_event: no answer' refuses "$1" "$home" 'the task record cannot be read: fm-task: GET /api/fm_task_event: no answer'
}

# The deployed head is the newest deploy ask, as for the record files, and a missing ask refuses before the record is asked.
case_rows_deployed_head() {
  local home sha2=2222222222222222222222222222222222222222
  home=$(rows_home)
  export FAKE_ARGS="$home/fake.args"
  printf '{"type":"ask","round":"deploy","key":"k2","task":"%s","sha":"%s"}\n' "$TASK" "$sha2" >> "$home/data/deploy-verify/ledger.jsonl"
  FAKE_RC=0 passes "$1" "$home" || return 1
  case "$(sed -n 1p "$FAKE_ARGS")" in *"--head $sha2 "*) ;; *) echo "the record was asked about another head: $(sed -n 1p "$FAKE_ARGS")"; return 1 ;; esac
  rm -f "$FAKE_ARGS"; : > "$home/data/deploy-verify/ledger.jsonl"
  refuses "$1" "$home" "no deploy ask for $TASK" || return 1
  [ ! -e "$FAKE_ARGS" ] || { echo 'the record was asked with no deployed head'; return 1; }
}

# The writer runs with the home's record settings from config/task-shadow.
case_rows_writer_settings() {
  local home
  home=$(rows_home)
  export FAKE_ARGS="$home/fake.args"
  mkdir -p "$home/config"
  printf 'FM_TASK_BASE_URL=http://record.test:5001\nOTHER=x\n' > "$home/config/task-shadow"
  FAKE_RC=0 passes "$1" "$home" || return 1
  grep -qx 'url=http://record.test:5001' "$FAKE_ARGS" || { echo "the writer settings were not given: $(cat "$FAKE_ARGS")"; return 1; }
}

# A task begun before T5 has no marker: the record files decide, and the task record is never asked.
case_rows_files_before_t5() {
  local home
  home=$(new_home)
  export FAKE_ARGS="$home/fake.args"
  FAKE_RC=5 FAKE_OUT='a reason the record would give' passes "$1" "$home" || return 1
  [ ! -e "$FAKE_ARGS" ] || { echo 'the task record was asked about a task begun before T5'; return 1; }
  drop "$(firstmate "$home")" 'approved: '
  refuses "$1" "$home" "missing 'approved: firstmate"
}

# A carried pass the record prints is no problem: the gate passes, and the line goes to stderr with its head.
case_rows_carried() {
  local home err
  home=$(rows_home)
  export FAKE_ARGS="$home/fake.args"
  err="$home/gate.err"
  RC=0
  OUT=$(FM_HOME="$home" FAKE_RC=0 FAKE_OUT='A1@1440 carried: pass on head d0, and no later deployed PR names A1' bash -c '. "$1"; fm_verify_gate_problems "$2/data" "$3" "$2"' _ "$1" "$home" "$TASK" 2>"$err") || RC=$?
  [ "$RC" -eq 0 ] && [ -z "$OUT" ] || { echo "a carried pass became a problem: exit $RC: $OUT"; return 1; }
  grep -qx 'A1@1440 carried: pass on head d0, and no later deployed PR names A1' "$err" || { echo "the carried pass is not printed: $(cat "$err")"; return 1; }
  OUT=$(FM_HOME="$home" FAKE_RC=5 FAKE_OUT=$'A1@1440 carried: pass on head d0, and no later deployed PR names A1\nA2@1440 is \'fail\', not pass' bash -c '. "$1"; fm_verify_gate_problems "$2/data" "$3" "$2"' _ "$1" "$home" "$TASK" 2>"$err") || RC=$?
  [ "$OUT" = "A2@1440 is 'fail', not pass" ] || { echo "problems with a carried pass beside them: $OUT"; return 1; }
}

CASES="pass_and_read_only firstmate_record_missing tester_record_missing no_tester_home tester_home_override
firstmate_line_one firstmate_issue_line tester_surface tester_issue_line records_name_different_issues
issue_cannot_be_parsed issue_cannot_be_read issue_without_user_visible_rows row_absent_from_tester_record
row_not_pass row_without_evidence_field row_pass_without_evidence row_evidence_path row_id_not_in_issue retired_row
retired_row_of_a_present_id_at_another_width internal_scenario_row row_text_differs_from_the_issue malformed_tester_row verified_line_closes_the_record acceptance_digest verified_line_missing verified_line_without_head
deployed_head_is_the_newest_ask a_pr_in_the_watched_repo_needs_an_ask a_pr_in_another_repo_takes_the_deployed_line the_backlog_line_names_the_pr approval home_video
rows_read_the_record rows_problems rows_record_unreadable rows_deployed_head rows_writer_settings rows_files_before_t5 rows_carried"

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
# The library reads backlog rows through its sibling bin/fm-tasks-axi.sh, which needs its own sibling libraries.
for f in fm-tasks-axi.sh fm-tasks-axi-lib.sh fm-backlog-transition-lib.sh fm-hold-reason-lib.sh fm-timeout-lib.sh fm-pr-lib.sh; do
  ln -s "$ROOT/bin/$f" "$MBIN/$f"
done
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

P="out=\$(printf '%s\\n' \"\$out\" | grep -v ' carried: pass on head ' || :)" mutate 'a carried pass is no problem' rows_carried 's/\Q$ENV{P}\E/:/'
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
mutate 'a retired row is allowed for a dropped id' retired_row 's/\[ "\$rstate" != retired \]; then/true; then/'
unsay 'retired is only for an id the issue dropped' retired_row_of_a_present_id_at_another_width '$rid is retired, but the issue still has'
unsay 'a retired row is not a pass for a present id' retired_row '$rid is '"'"'$rstate'"'"', not pass'
mutate 'only user-visible rows are gate rows' internal_scenario_row 's/--surface all 2>\/dev\/null\) \|\| all_rows=\$rows/--surface user-visible 2>\/dev\/null) || all_rows=\$rows/'
unsay 'a Tester row carries the issue'"'"'s current text' row_text_differs_from_the_issue '$rid line differs from the issue'
unsay 'a Tester row is well formed' malformed_tester_row 'malformed Tester row'
unsay 'the verified line follows the last row' verified_line_closes_the_record "the 'verified: tester' line must come after"
unsay 'a scenario row outside Scenarios is refused' verified_line_closes_the_record "scenario row outside"
unsay 'the Tester digest is the issue'"'"'s current digest' acceptance_digest 'Tester acceptance '
unsay 'the verified line carries a digest' acceptance_digest 'Tester verified line has no acceptance='
unsay 'the verified line is required' verified_line_missing "Tester record has no 'verified: tester"
unsay 'the verified line names a head' verified_line_without_head 'Tester verified line has no head='
unsay 'the Tester head is the deployed head' deployed_head_is_the_newest_ask 'Tester head '
mutate 'the newest ask is the deployed head' deployed_head_is_the_newest_ask 's/\| tail -n 1\n\}/| head -n 1\n}/'
mutate 'a draft round is not a deploy' deployed_head_is_the_newest_ask 's/\.round == "deploy" and //'
mutate 'only the task'"'"'s own asks count' deployed_head_is_the_newest_ask 's/ and \.task == \$t//'
unsay 'a deployed head is required' a_pr_in_another_repo_takes_the_deployed_line 'no deployed head for'
mutate 'a PR elsewhere takes the deployed line' a_pr_in_another_repo_takes_the_deployed_line 's/want_sha=\$\(fm_verify_gate_field "\$file" deployed\)/want_sha=/'
unsay 'a missing ask refuses for a PR in the watched repo' a_pr_in_the_watched_repo_needs_an_ask 'no deploy ask for'
mutate 'a PR in the watched repo needs an ask, not a deployed line' a_pr_in_the_watched_repo_needs_an_ask 's/if fm_verify_gate_task_in_repo "\$state" "\$data" "\$id" "\$repo"; then/if false; then/'
mutate 'the endpoint record names the PR' pass_and_read_only 's/case "\$pr" in "https:\/\/github.com\/\$4\/pull\/"\[0-9\]\*\) return 0 ;; esac//'
mutate 'the backlog row names the PR' the_backlog_line_names_the_pr 's/select\(\.id == \$task and /select(false and /'
mutate 'only the task'"'"'s own backlog row counts' the_backlog_line_names_the_pr 's/\.id == \$task and //'
unsay 'approval is required' approval "missing 'approved: firstmate"
unsay 'approval is a number' approval 'approved line needs a numeric epoch'
unsay 'approval is newer than the Tester' approval 'approved: firstmate $approved is not newer'
mutate 'an equal epoch is not newer' approval 's/"\$approved" -le "\$v_epoch"/"\$approved" -lt "\$v_epoch"/'
unsay 'the home.video draft head is refused' home_video 'Tester head '
# Replace one exact source text.
swap() {  # <label> <case> <text> <replacement>
  S=$3 R=$4 mutate "$1" "$2" 's/\Q$ENV{S}\E/$ENV{R}/'
}
swap 'a marked task reads the task record' rows_read_the_record '[ "$(fm_verify_gate_field "$file" record)" = rows ]' 'false'
swap 'a task begun before T5 reads the record files' rows_files_before_t5 ' && [ "$(fm_verify_gate_field "$file" record)" = rows ]; then' '; then'
swap 'the Tester home is the evidence root' rows_read_the_record '${tester_home:+--evidence-root "$tester_home"}' ''
swap 'each reason the record gives is a problem' rows_problems "printf '%s\\n' \"\$out\"
    bad=1" 'bad=1'
unsay 'a record that cannot be read is a problem' rows_record_unreadable 'the task record cannot be read: $(sed'
swap 'the record is asked about the deployed head' rows_deployed_head '--head "$want_sha"' '--head "$issue"'
swap 'no deployed head, no read of the record' rows_deployed_head '[ -n "$want_sha" ] || return 0' ':'
swap 'the writer runs with the record settings' rows_writer_settings '    fm_task_shadow_config "$config/task-shadow"' '    :'
pass 'every rule of the gate has a red mutation proof'
