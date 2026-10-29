#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# Behavior tests for the merge self-test gate (spec huynhtandat223/firstmate#217,
# ticket #218): bin/fm-selftest-gate-lib.sh, and its call from bin/fm-pr-merge.sh.
#
# Every case runs in a lab home under a temp root, never the live home. A stub
# `gh` answers `pr view --json body` from a fixture, so nothing reaches GitHub
# and nothing merges. Each hit is log-only until config/enforce-<check> holds
# `block`.
#   SG1  the real body of cfw-modules PR 1730 hits `phrase` on its lines 4 and 16:
#        refused under `block`, only logged without the file.
#   SG2  a user-visible cfw-modules task with a PASS receipt at the live head
#        logs nothing; each missing or stale piece hits its own code and prints
#        the verify-cfw command to run.
#   SG3  an internal task, or another repository, gets only the phrase rule; a
#        phrase inside a fence or a `>` quote does not hit.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/bin/fm-selftest-gate-lib.sh"
FIXTURE="$ROOT/tests/fixtures/selftest-gate"
TMP_ROOT=$(fm_test_tmproot fm-selftest-gate)
CFW_URL=https://github.com/huynhtandat223/cfw-modules/pull/1800
OTHER_URL=https://github.com/example/repo/pull/5
HEAD=0123456789abcdef0123456789abcdef01234567
TASK=board-fix
APOSTROPHE=$'\u2019'

# make_case <name> [surface]: a lab home with state/, config/ and data/, and a
# gh stub that prints $case/pr.json for `pr view ... --json body`.
make_case() {
  local name=$1 surface=${2:-} dir="$TMP_ROOT/$1"
  mkdir -p "$dir/home/state" "$dir/home/config" "$dir/home/data/$TASK" "$dir/fakebin"
  fm_write_meta "$dir/home/state/$TASK.meta" "kind=ship" "mode=direct-PR"
  [ -z "$surface" ] || printf 'surface=%s\n' "$surface" >> "$dir/home/state/$TASK.meta"
  cat > "$dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
case "$*" in
  "pr view "*"--json body") cat "$FM_TEST_PR_JSON"; exit "${FM_TEST_GH_RC:-0}" ;;
esac
exit 1
SH
  chmod +x "$dir/fakebin/gh"
  : > "$dir/gh.log"
  printf '%s\n' "$dir"
}

# set_body <case> <body-file>: the PR body the stub serves.
set_body() {
  jq -n --rawfile body "$2" '{body: $body}' > "$1/pr.json"
}

# run_gate <case> <url> [head]: run fm_selftest_gate in the lab; sets RC and ERR.
run_gate() {
  local dir=$1 url=$2 head=${3:-$HEAD}
  RC=0
  FM_HOME="$dir/home" STATE="$dir/home/state" \
  FM_TEST_GH_LOG="$dir/gh.log" FM_TEST_PR_JSON="$dir/pr.json" \
  PATH="$dir/fakebin:$PATH" \
    bash -c '. "$1"; fm_selftest_gate "$2" "$3" "$4"' _ "$LIB" "$url" "$TASK" "$head" \
    > /dev/null 2> "$dir/err" || RC=$?
  ERR=$(cat "$dir/err")
}

count_logs() {  # <case>: how many enforce logs the run wrote
  find "$1/home/state" -name 'enforce-*.log' | wc -l | tr -d ' '
}

log_of() {  # <case> <check>
  cat "$1/home/state/enforce-$2.log" 2>/dev/null || true
}

selftest_line() {  # <sha>
  printf 'Self-test: verify-cfw run board-task-detail --target storybook:fm/board-fix head=%s PASS\n' "$1"
}

# write_receipt <case> <head> <actor> <result> [failed-check]
write_receipt() {
  local dir=$1 head=$2 actor=$3 result=$4 failed=${5:-pass}
  jq -n --arg head "$head" --arg actor "$actor" --arg result "$result" --arg failed "$failed" '
    {tool: "verify-cfw", head: $head, target: "storybook:fm/board-fix", features: ["board-task-detail"],
     widths: [1440, 390], actor: $actor, result: $result,
     results: [{feature: "board-task-detail", state: "detail sheet open on a phone", width: 390, check: "page", result: "pass"},
               {feature: "board-task-detail", state: "document dialog open", width: 390, check: "touch", result: $failed}]}' \
    > "$dir/home/data/$TASK/selftest-$head.json"
}

body_file() {  # <case> <text>
  printf '%s\n' "$2" > "$1/body.md"
  set_body "$1" "$1/body.md"
}

test_sg1_pr_1730_body_hits_phrase_on_lines_4_and_16() {
  local dir
  dir=$(make_case sg1-log)
  jq -r .body "$FIXTURE/cfw-modules-pr-1730.json" > "$dir/body.md"
  set_body "$dir" "$dir/body.md"

  run_gate "$dir" https://github.com/huynhtandat223/cfw-modules/pull/1730 \
    "$(jq -r .headRefOid "$FIXTURE/cfw-modules-pr-1730.json")"
  expect_code 0 "$RC" "sg1: no config file means the merge path continues"
  assert_contains "$ERR" 'would refuse: phrase body line 4:' "sg1: line 4 is named on stderr"
  assert_contains "$ERR" 'not ready to merge' "sg1: the line 4 phrase is quoted"
  assert_contains "$ERR" 'would refuse: phrase body line 16:' "sg1: line 16 is named on stderr"
  assert_contains "$ERR" 'do not merge yet' "sg1: the line 16 phrase is quoted"
  assert_equals 2 "$(log_of "$dir" merge-selftest | wc -l | tr -d ' ')" "sg1: one log line per hit"
  assert_equals 2 "$(log_of "$dir" merge-selftest | awk -F'\t' '$3 == "phrase" && $2 == "would-refuse"' | wc -l | tr -d ' ')" \
    "sg1: both log lines carry code phrase in log-only mode"
  assert_equals 0 "$(grep -c 'merge-verifier' "$dir/err")" "sg1: the verifier check stays out of a phrase hit"

  printf 'block\n' > "$dir/home/config/enforce-merge-selftest"
  run_gate "$dir" https://github.com/huynhtandat223/cfw-modules/pull/1730 \
    "$(jq -r .headRefOid "$FIXTURE/cfw-modules-pr-1730.json")"
  expect_code 1 "$RC" "sg1: block refuses the merge"
  assert_contains "$ERR" 'refused: phrase body line 4:' "sg1: block names line 4"
  assert_contains "$ERR" 'refused: phrase body line 16:' "sg1: block names line 16"
  assert_equals 2 "$(log_of "$dir" merge-selftest | awk -F'\t' '$2 == "refuse"' | wc -l | tr -d ' ')" \
    "sg1: block logs the two hits as refuse"
  pass "sg1: PR 1730's body is refused under block and only logged without it"
}

test_sg2_receipt_at_the_live_head_logs_nothing() {
  local dir
  dir=$(make_case sg2-pass user-visible)
  body_file "$dir" "$(printf 'Moves the sheet.\n\n%s' "$(selftest_line "${HEAD:0:9}")")"
  write_receipt "$dir" "$HEAD" tester PASS

  run_gate "$dir" "$CFW_URL"
  expect_code 0 "$RC" "sg2: a PASS receipt at the live head merges"
  assert_equals '' "$ERR" "sg2: nothing on stderr"
  assert_equals 0 "$(count_logs "$dir")" "sg2: no log file written"

  # The receipt may also be named by the sha the body carries.
  rm "$dir/home/data/$TASK/selftest-$HEAD.json"
  body_file "$dir" "$(selftest_line "$HEAD")"
  write_receipt "$dir" "$HEAD" tester PASS
  run_gate "$dir" "$CFW_URL"
  assert_equals '' "$ERR" "sg2: a full-length sha in the body passes too"
  pass "sg2: a PASS receipt at the live head logs nothing"
}

assert_receipt_hit() {  # <case> <code>
  local dir=$1 code=$2
  expect_code 0 "$RC" "sg2 $code: log-only continues"
  assert_contains "$ERR" "would refuse: $code" "sg2 $code: named on stderr"
  assert_contains "$ERR" "npm run verify-cfw -- run " "sg2 $code: the command is printed"
  assert_contains "$ERR" "--head $HEAD --widths 1440,390 --json --out $dir/home/data/$TASK/" \
    "sg2 $code: the command carries the live head and the receipt directory"
  assert_equals 1 "$(log_of "$dir" merge-selftest | awk -F'\t' -v c="$code" '$3 == c' | wc -l | tr -d ' ')" \
    "sg2 $code: one log line with the code"
  assert_equals 1 "$(log_of "$dir" merge-selftest | wc -l | tr -d ' ')" "sg2 $code: no other hit"
}

test_sg2_each_missing_piece_hits_its_own_code() {
  local dir

  dir=$(make_case sg2-no-line user-visible)
  body_file "$dir" 'Moves the sheet.'
  run_gate "$dir" "$CFW_URL"
  assert_receipt_hit "$dir" no-selftest-line

  dir=$(make_case sg2-stale user-visible)
  body_file "$dir" "$(selftest_line fedcba987)"
  write_receipt "$dir" "$HEAD" tester PASS
  run_gate "$dir" "$CFW_URL"
  assert_receipt_hit "$dir" stale-head
  assert_contains "$ERR" 'head=fedcba987' "sg2 stale-head: the stale sha is named"

  dir=$(make_case sg2-short user-visible)
  body_file "$dir" "$(selftest_line 0123456)"
  run_gate "$dir" "$CFW_URL"
  assert_receipt_hit "$dir" no-selftest-line

  dir=$(make_case sg2-no-receipt user-visible)
  body_file "$dir" "$(selftest_line "${HEAD:0:12}")"
  run_gate "$dir" "$CFW_URL"
  assert_receipt_hit "$dir" no-receipt

  dir=$(make_case sg2-fail user-visible)
  body_file "$dir" "$(selftest_line "${HEAD:0:12}")"
  write_receipt "$dir" "$HEAD" tester FAIL fail
  run_gate "$dir" "$CFW_URL"
  assert_receipt_hit "$dir" receipt-fail

  dir=$(make_case sg2-blocked user-visible)
  body_file "$dir" "$(selftest_line "${HEAD:0:12}")"
  write_receipt "$dir" "$HEAD" tester BLOCKED
  run_gate "$dir" "$CFW_URL"
  assert_receipt_hit "$dir" receipt-fail

  dir=$(make_case sg2-pass-with-fail user-visible)
  body_file "$dir" "$(selftest_line "${HEAD:0:12}")"
  write_receipt "$dir" "$HEAD" tester PASS fail
  run_gate "$dir" "$CFW_URL"
  assert_receipt_hit "$dir" receipt-fail

  dir=$(make_case sg2-other-head user-visible)
  body_file "$dir" "$(selftest_line "${HEAD:0:12}")"
  write_receipt "$dir" "ffffffffffffffffffffffffffffffffffffffff" tester PASS
  mv "$dir/home/data/$TASK/selftest-ffffffffffffffffffffffffffffffffffffffff.json" "$dir/home/data/$TASK/selftest-$HEAD.json"
  run_gate "$dir" "$CFW_URL"
  assert_receipt_hit "$dir" receipt-fail

  dir=$(make_case sg2-not-json user-visible)
  body_file "$dir" "$(selftest_line "${HEAD:0:12}")"
  printf 'not json\n' > "$dir/home/data/$TASK/selftest-$HEAD.json"
  run_gate "$dir" "$CFW_URL"
  assert_receipt_hit "$dir" receipt-fail

  dir=$(make_case sg2-block user-visible)
  body_file "$dir" 'Moves the sheet.'
  printf '# trial\nblock\n' > "$dir/home/config/enforce-merge-selftest"
  run_gate "$dir" "$CFW_URL"
  expect_code 1 "$RC" "sg2: block refuses a missing line"
  assert_contains "$ERR" 'refused: no-selftest-line' "sg2: block names the code"
  pass "sg2: each missing or stale piece hits its own code and prints the command"
}

test_sg3_receipt_rules_stay_inside_user_visible_cfw_modules() {
  local dir

  dir=$(make_case sg3-internal)
  body_file "$dir" 'Moves the sheet.'
  run_gate "$dir" "$CFW_URL"
  expect_code 0 "$RC" "sg3: an internal task continues"
  assert_equals '' "$ERR" "sg3: an internal task has no receipt rule"
  assert_equals 0 "$(count_logs "$dir")" "sg3: internal logs nothing"

  dir=$(make_case sg3-internal-phrase internal)
  body_file "$dir" 'Do not merge until the Tester has run.'
  run_gate "$dir" "$CFW_URL"
  assert_contains "$ERR" 'would refuse: phrase body line 1: Do not merge until' "sg3: an internal task still gets the phrase rule"
  assert_not_contains "$ERR" no-selftest-line "sg3: and no receipt hit"

  dir=$(make_case sg3-other-repo user-visible)
  body_file "$dir" "Moves the sheet.
Don't merge before the owner reads it."
  run_gate "$dir" "$OTHER_URL"
  assert_contains "$ERR" "would refuse: phrase body line 2:" "sg3: another repository gets the phrase rule"
  assert_not_contains "$ERR" no-selftest-line "sg3: another repository has no receipt rule"
  assert_equals 1 "$(log_of "$dir" merge-selftest | wc -l | tr -d ' ')" "sg3: one hit logged"

  dir=$(make_case sg3-fence internal)
  cat > "$dir/body.md" <<'MD'
Text before.

```sh
echo "do not merge"
```

~~~
not ready to merge
~~~

> do not merge yet
>> don't merge either

    A normal line.
MD
  set_body "$dir" "$dir/body.md"
  run_gate "$dir" "$CFW_URL"
  assert_equals '' "$ERR" "sg3: a phrase inside a fence or a quote does not hit"
  assert_equals 0 "$(count_logs "$dir")" "sg3: and logs nothing"

  dir=$(make_case sg3-after-fence internal)
  cat > "$dir/body.md" <<'MD'
```
inside
```
Still open? Do NOT Merge this, I don't merge drafts.
MD
  set_body "$dir" "$dir/body.md"
  run_gate "$dir" "$CFW_URL"
  assert_contains "$ERR" 'would refuse: phrase body line 4:' "sg3: the phrase after a closed fence hits, case-insensitive"

  dir=$(make_case sg3-curly internal)
  body_file "$dir" "We don${APOSTROPHE}t merge this one."
  run_gate "$dir" "$CFW_URL"
  assert_contains "$ERR" 'would refuse: phrase body line 1:' "sg3: a curly apostrophe hits"

  dir=$(make_case sg3-unread internal)
  : > "$dir/pr.json"
  run_gate "$dir" "$CFW_URL"
  expect_code 0 "$RC" "sg3: an unreadable body is logged, not refused, in log mode"
  assert_contains "$ERR" 'would refuse: body-unread' "sg3: the unreadable body is named"
  printf 'block\n' > "$dir/home/config/enforce-merge-selftest"
  run_gate "$dir" "$CFW_URL"
  expect_code 1 "$RC" "sg3: an unreadable body is refused under block"
  pass "sg3: the receipt rules stay inside user-visible cfw-modules tasks and the phrase rule skips fences and quotes"
}

test_sg1_pr_1730_body_hits_phrase_on_lines_4_and_16
test_sg2_receipt_at_the_live_head_logs_nothing
test_sg2_each_missing_piece_hits_its_own_code
test_sg3_receipt_rules_stay_inside_user_visible_cfw_modules
