#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# Behavior tests for the merge self-test gate (spec huynhtandat223/firstmate#217,
# ticket #218): bin/fm-selftest-gate-lib.sh, and its call from bin/fm-pr-merge.sh,
# and bin/fm-brief-verify-lib.sh, which bin/fm-brief.sh --check calls.
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
#   SG4  a receipt whose actor is the task hits `author-receipt` on its own
#        check, merge-verifier: only logged without its config file, refused
#        under `block`; an actor such as `tester` logs nothing.
#   SG5  a brief for a cfw-modules issue with user-visible scenarios on
#        `firstmate.board` hits `missing-verify` naming board-task-detail unless
#        it names `verify-cfw run board-task-detail`; a page with no feature file
#        is logged as `unmapped` and never a hit; an internal-only issue logs
#        nothing. Feature files are read with git show from origin/main of a lab
#        clone.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid

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
  TMPDIR="${GATE_TMPDIR:-${TMPDIR:-/tmp}}" PATH="$dir/fakebin:$PATH" \
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
  printf 'Self-test: verify-cfw run board-task-detail --target url:http://127.0.0.1:6123 head=%s PASS\n' "$1"
}

# write_receipt <case> <head> <actor> <result> [failed-check]: a receipt shaped as
# cfw-modules PR 1748 writes it. RECEIPT_FEATURES, RECEIPT_TARGET and RECEIPT_WIDTHS
# (JSON) replace the matching field.
write_receipt() {
  local dir=$1 head=$2 actor=$3 result=$4 failed=${5:-pass}
  jq -n --arg head "$head" --arg actor "$actor" --arg result "$result" --arg failed "$failed" \
    --argjson features "${RECEIPT_FEATURES:-[\"board-task-detail\"]}" \
    --arg target "${RECEIPT_TARGET:-url:http://127.0.0.1:6123}" \
    --argjson widths "${RECEIPT_WIDTHS:-[1440, 390]}" '
    {tool: "verify-cfw", head: $head, target: $target, features: $features,
     widths: $widths, actor: $actor, result: $result,
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
  assert_contains "$ERR" '--target url:<base>' "sg2: the printed command runs against a url: target"

  # Storybook 5010 is the owner's UI/UX review, not a self-test target: a storybook: line is no Self-test line.
  dir=$(make_case sg2-storybook-target user-visible)
  body_file "$dir" "Self-test: verify-cfw run board-task-detail --target storybook:fm/board-fix head=${HEAD:0:12} PASS"
  RECEIPT_TARGET='storybook:fm/board-fix' write_receipt "$dir" "$HEAD" tester PASS
  run_gate "$dir" "$CFW_URL"
  assert_receipt_hit "$dir" no-selftest-line

  # A url: target on port 5010 is the owner's review Storybook again: the gate names the rule.
  for base in http://127.0.0.1:5010 http://100.88.10.58:5010/ 127.0.0.1:5010; do
    dir=$(make_case "sg2-review-port-${base//[^0-9a-z]/-}" user-visible)
    body_file "$dir" "Self-test: verify-cfw run board-task-detail --target url:$base head=${HEAD:0:12} PASS"
    RECEIPT_TARGET="url:$base" write_receipt "$dir" "$HEAD" tester PASS
    run_gate "$dir" "$CFW_URL"
    assert_receipt_hit "$dir" review-storybook
    assert_contains "$ERR" "port 5010 is the owner's UI/UX review Storybook" "sg2: the review-port hit names the rule"
  done
  # Another port that only contains 5010 is not the review Storybook.
  dir=$(make_case sg2-port-50100 user-visible)
  body_file "$dir" "Self-test: verify-cfw run board-task-detail --target url:http://127.0.0.1:50100 head=${HEAD:0:12} PASS"
  RECEIPT_TARGET='url:http://127.0.0.1:50100' write_receipt "$dir" "$HEAD" tester PASS
  run_gate "$dir" "$CFW_URL"
  assert_equals '' "$ERR" "sg2: port 50100 is not the review Storybook"

  dir=$(make_case sg2-stale user-visible)
  body_file "$dir" "$(selftest_line fedcba987)"
  write_receipt "$dir" "$HEAD" tester PASS
  run_gate "$dir" "$CFW_URL"
  assert_receipt_hit "$dir" stale-head
  assert_contains "$ERR" 'head=fedcba987' "sg2 stale-head: the stale sha is named"

  # A body that keeps an older PASS line and adds one for the live head passes, in either order.
  dir=$(make_case sg2-two-lines user-visible)
  body_file "$dir" "$(printf '%s\n%s' "$(selftest_line fedcba987654)" "$(selftest_line "${HEAD:0:12}")")"
  write_receipt "$dir" "$HEAD" tester PASS
  run_gate "$dir" "$CFW_URL"
  assert_equals '' "$ERR" "sg2: the line for the live head is used when an older line comes first"
  body_file "$dir" "$(printf '%s\n%s' "$(selftest_line "${HEAD:0:12}")" "$(selftest_line fedcba987654)")"
  run_gate "$dir" "$CFW_URL"
  assert_equals '' "$ERR" "sg2: and when it comes last"

  # With no line for the live head, the first line gives the stale-head message.
  dir=$(make_case sg2-two-stale user-visible)
  body_file "$dir" "$(printf '%s\n%s' "$(selftest_line fedcba987654)" "$(selftest_line 123456789abc)")"
  write_receipt "$dir" "$HEAD" tester PASS
  run_gate "$dir" "$CFW_URL"
  assert_receipt_hit "$dir" stale-head
  assert_contains "$ERR" 'head=fedcba987654' "sg2: stale-head names the first line"

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

  dir=$(make_case sg3-repo-case user-visible)
  body_file "$dir" 'Moves the sheet.'
  run_gate "$dir" https://github.com/HuynhTanDat223/CFW-Modules/pull/1800
  assert_contains "$ERR" 'would refuse: no-selftest-line' "sg3: the repository name is matched without regard to case"

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

  dir=$(make_case sg3-fence-trailing internal)
  printf '```sh\necho x\n```  \n~~~\nquoted\n~~~\t\nDo not merge this yet.\n' > "$dir/body.md"
  set_body "$dir" "$dir/body.md"
  run_gate "$dir" "$CFW_URL"
  assert_contains "$ERR" 'would refuse: phrase body line 7:' "sg3: a closing fence with trailing whitespace still closes, so the next real line hits"
  dir=$(make_case sg3-fence-trailing-line user-visible)
  printf '```\ncode\n``` \n%s\n' "$(selftest_line "${HEAD:0:12}")" > "$dir/body.md"
  set_body "$dir" "$dir/body.md"
  write_receipt "$dir" "$HEAD" tester PASS
  run_gate "$dir" "$CFW_URL"
  assert_equals '' "$ERR" "sg3: the Self-test line after a fence closed with trailing whitespace is read"

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
  dir=$(make_case sg3-no-tmp internal)
  body_file "$dir" 'Do not merge yet.'
  GATE_TMPDIR="$dir/no-such-dir" run_gate "$dir" "$CFW_URL"
  expect_code 0 "$RC" "sg3: a body that cannot be staged passes while the check is log-only"
  assert_contains "$ERR" 'would refuse: body-unread' "sg3: a failed temp file is a body-unread hit, not a skipped check"
  printf 'block\n' > "$dir/home/config/enforce-merge-selftest"
  GATE_TMPDIR="$dir/no-such-dir" run_gate "$dir" "$CFW_URL"
  expect_code 1 "$RC" "sg3: block refuses when the body cannot be staged"
  pass "sg3: the receipt rules stay inside user-visible cfw-modules tasks and the phrase rule skips fences and quotes"
}

test_sg4_a_receipt_written_by_the_author_hits_author_receipt() {
  local dir

  dir=$(make_case sg4-log user-visible)
  body_file "$dir" "$(selftest_line "${HEAD:0:12}")"
  write_receipt "$dir" "$HEAD" "$TASK" PASS
  run_gate "$dir" "$CFW_URL"
  expect_code 0 "$RC" "sg4: without enforce-merge-verifier the merge continues"
  assert_contains "$ERR" "would refuse: author-receipt" "sg4: the hit is a would-refuse line"
  assert_contains "$ERR" "actor $TASK" "sg4: the actor is named"
  assert_contains "$ERR" "the verifier is not the author: the Tester or a fresh verifier session runs it" "sg4: the rule is stated"
  assert_equals 1 "$(log_of "$dir" merge-verifier | awk -F'\t' '$2 == "would-refuse" && $3 == "author-receipt"' | wc -l | tr -d ' ')" \
    "sg4: one author-receipt line in the merge-verifier log"
  assert_equals 0 "$(log_of "$dir" merge-selftest | wc -l | tr -d ' ')" "sg4: the receipt itself is fine for merge-selftest"

  # Each check has its own switch.
  printf 'block\n' > "$dir/home/config/enforce-merge-selftest"
  run_gate "$dir" "$CFW_URL"
  expect_code 0 "$RC" "sg4: block on merge-selftest does not turn the verifier check on"
  rm "$dir/home/config/enforce-merge-selftest"
  printf 'block\n' > "$dir/home/config/enforce-merge-verifier"
  run_gate "$dir" "$CFW_URL"
  expect_code 1 "$RC" "sg4: block on merge-verifier refuses the merge"
  assert_contains "$ERR" "refused: author-receipt" "sg4: block names the code"

  dir=$(make_case sg4-tester user-visible)
  body_file "$dir" "$(selftest_line "${HEAD:0:12}")"
  write_receipt "$dir" "$HEAD" tester PASS
  printf 'block\n' > "$dir/home/config/enforce-merge-verifier"
  run_gate "$dir" "$CFW_URL"
  expect_code 0 "$RC" "sg4: a receipt from the Tester passes under block"
  assert_equals '' "$ERR" "sg4: and prints nothing"
  assert_equals 0 "$(count_logs "$dir")" "sg4: and logs nothing"

  dir=$(make_case sg4-no-actor user-visible)
  body_file "$dir" "$(selftest_line "${HEAD:0:12}")"
  write_receipt "$dir" "$HEAD" "" PASS
  run_gate "$dir" "$CFW_URL"
  assert_contains "$ERR" "would refuse: no-actor" "sg4: a receipt with no actor cannot show a non-author verifier"
  assert_equals 1 "$(log_of "$dir" merge-verifier | wc -l | tr -d ' ')" "sg4: logged once"

  dir=$(make_case sg4-internal internal)
  body_file "$dir" "$(selftest_line "${HEAD:0:12}")"
  write_receipt "$dir" "$HEAD" "$TASK" PASS
  run_gate "$dir" "$CFW_URL"
  assert_equals '' "$ERR" "sg4: an internal task has no verifier rule"
  pass "sg4: a receipt the author wrote hits author-receipt on the merge-verifier switch alone"
}

# --- SG5: bin/fm-brief.sh --check names the evidence ---------------------------

CFW_ISSUE=https://github.com/huynhtandat223/cfw-modules/issues/1678
BRIEF_TASK=board-task

# make_brief_home <name> [features...]: a lab home, a gh stub that serves
# $FM_TEST_ISSUE_BODY as the issue body, and a lab cfw-modules clone whose
# origin/main holds the named fixture feature files (tests/fixtures/selftest-gate/features/<name>.body, copied as <name>.md) (none: no feature files).
make_brief_home() {
  local name=$1 dir="$TMP_ROOT/$1" feature
  shift
  mkdir -p "$dir/home/data" "$dir/home/state" "$dir/home/config" "$dir/clone"
  printf '#!/usr/bin/env bash\njq -Rs "{body: .}" "$FM_TEST_ISSUE_BODY"\n' > "$dir/gh"
  chmod +x "$dir/gh"
  fm_git_init_commit "$dir/clone"
  if [ "$#" -gt 0 ]; then
    mkdir -p "$dir/clone/.agents/skills/verify-cfw/features"
    cp "$FIXTURE/features/README.body" "$dir/clone/.agents/skills/verify-cfw/features/README.md"
    for feature in "$@"; do
      cp "$FIXTURE/features/$feature.body" "$dir/clone/.agents/skills/verify-cfw/features/$feature.md"
    done
    git -C "$dir/clone" add -A
    git -C "$dir/clone" commit -q -m features
  fi
  git -C "$dir/clone" update-ref refs/remotes/origin/main "$(git -C "$dir/clone" rev-parse HEAD)"
  printf '%s\n' "$dir"
}

# write_brief <home-dir> <issue-url> <spec text>: scaffold a ship brief that
# names the issue, as firstmate does, and fill its two task fields.
write_brief() {
  local dir=$1 url=$2 spec=$3
  FM_HOME="$dir/home" "$ROOT/bin/fm-brief.sh" "$BRIEF_TASK" cfw-modules --mode direct-PR --surface user-visible \
    --issue "$url" > /dev/null 2>&1 || fail "write_brief: scaffold failed"
  sed -i "s/{TASK}/Fix the page./; s|{FIRSTMATE_SPEC}|$spec|" "$dir/home/data/$BRIEF_TASK/brief.md"
}

# check_brief <home-dir> <issue body file>: run fm-brief.sh --check; sets RC and ERR.
check_brief() {
  local dir=$1 body=$2
  RC=0
  FM_HOME="$dir/home" FM_BRIEF_CFW_CLONE="$dir/clone" FM_ACCEPTANCE_GH="$dir/gh" FM_TEST_ISSUE_BODY="$body" \
    "$ROOT/bin/fm-brief.sh" --check "$BRIEF_TASK" > /dev/null 2> "$dir/err" || RC=$?
  ERR=$(cat "$dir/err")
}

brief_log() {  # <home-dir>
  cat "$1/home/state/enforce-brief-verify.log" 2>/dev/null || true
}

test_sg5_a_brief_names_the_verify_run_for_each_mapped_page() {
  local dir

  dir=$(make_brief_home sg5-missing board-task-detail screens-debug-steps)
  write_brief "$dir" "$CFW_ISSUE" "Build the board record."
  check_brief "$dir" "$FIXTURE/cfw-modules-1678.body"
  expect_code 0 "$RC" "sg5: without enforce-brief-verify the brief check passes"
  assert_contains "$ERR" "would refuse: missing-verify" "sg5: the hit is a would-refuse line"
  assert_contains "$ERR" "board-task-detail" "sg5: the mapped feature is named"
  assert_not_contains "$ERR" "screens-debug-steps" "sg5: a feature of a page the issue does not use is not named"
  assert_equals 1 "$(brief_log "$dir" | awk -F'\t' '$2 == "would-refuse" && $3 == "missing-verify"' | wc -l | tr -d ' ')" \
    "sg5: one missing-verify log line"
  printf 'block\n' > "$dir/home/config/enforce-brief-verify"
  check_brief "$dir" "$FIXTURE/cfw-modules-1678.body"
  expect_code 1 "$RC" "sg5: block refuses the brief"
  assert_contains "$ERR" "refused: missing-verify" "sg5: block names the code"

  dir=$(make_brief_home sg5-named board-task-detail screens-debug-steps)
  write_brief "$dir" "$CFW_ISSUE" "Run verify-cfw run board-task-detail at 1440 and 390."
  printf 'block\n' > "$dir/home/config/enforce-brief-verify"
  check_brief "$dir" "$FIXTURE/cfw-modules-1678.body"
  expect_code 0 "$RC" "sg5: a brief that names the run passes under block"
  assert_equals '' "$ERR" "sg5: and prints nothing"
  assert_equals '' "$(brief_log "$dir")" "sg5: and logs nothing"

  dir=$(make_brief_home sg5-npm board-task-detail)
  write_brief "$dir" "$CFW_ISSUE" "Run npm run verify-cfw -- run board-task-detail,screens-debug-steps --target url:http://127.0.0.1:6123."
  check_brief "$dir" "$FIXTURE/cfw-modules-1678.body"
  assert_equals '' "$ERR" "sg5: the npm form with a feature list names the run too"

  dir=$(make_brief_home sg5-prefix board-task-detail)
  write_brief "$dir" "$CFW_ISSUE" "Run verify-cfw run board-task-detail-extra only."
  check_brief "$dir" "$FIXTURE/cfw-modules-1678.body"
  assert_contains "$ERR" "would refuse: missing-verify" "sg5: a longer feature name does not name board-task-detail"
  pass "sg5: a brief names the verify-cfw run for each mapped user-visible page"
}

test_sg5_an_unmapped_page_is_logged_and_never_a_hit() {
  local dir

  dir=$(make_brief_home sg5-nofiles)
  write_brief "$dir" "$CFW_ISSUE" "Build the board record."
  printf 'block\n' > "$dir/home/config/enforce-brief-verify"
  check_brief "$dir" "$FIXTURE/cfw-modules-1678.body"
  expect_code 0 "$RC" "sg5: with no feature files every page is unmapped and nothing refuses, even under block"
  assert_equals '' "$ERR" "sg5: unmapped prints no would-refuse line"
  assert_equals 1 "$(brief_log "$dir" | awk -F'\t' '$2 == "skip" && $3 == "unmapped"' | wc -l | tr -d ' ')" \
    "sg5: firstmate.board is logged once as unmapped"
  assert_contains "$(brief_log "$dir")" "firstmate.board" "sg5: the unmapped page is named"

  dir=$(make_brief_home sg5-other-feature screens-debug-steps)
  write_brief "$dir" "$CFW_ISSUE" "Build the board record."
  check_brief "$dir" "$FIXTURE/cfw-modules-1678.body"
  assert_equals '' "$ERR" "sg5: a feature file for another page leaves firstmate.board unmapped"
  assert_contains "$(brief_log "$dir")" "unmapped" "sg5: and logs it"

  dir=$(make_brief_home sg5-no-clone)
  rm -rf "$dir/clone"
  write_brief "$dir" "$CFW_ISSUE" "Build the board record."
  check_brief "$dir" "$FIXTURE/cfw-modules-1678.body"
  expect_code 0 "$RC" "sg5: a missing clone leaves every page unmapped"
  assert_contains "$(brief_log "$dir")" "unmapped" "sg5: and logs it"
  pass "sg5: an unmapped page is logged as unmapped and is never a hit"
}

test_sg5_internal_issues_and_other_repositories_log_nothing() {
  local dir

  dir=$(make_brief_home sg5-internal board-task-detail)
  write_brief "$dir" "$CFW_ISSUE" "Change the script."
  printf 'block\n' > "$dir/home/config/enforce-brief-verify"
  check_brief "$dir" "$FIXTURE/internal-only.body"
  expect_code 0 "$RC" "sg5: an issue with only internal scenarios passes"
  assert_equals '' "$ERR" "sg5: and prints nothing"
  assert_equals 0 "$(count_logs "$dir")" "sg5: and logs nothing"

  dir=$(make_brief_home sg5-other-repo board-task-detail)
  write_brief "$dir" https://github.com/acme/widgets/issues/163 "Build the board record."
  printf 'block\n' > "$dir/home/config/enforce-brief-verify"
  check_brief "$dir" "$FIXTURE/cfw-modules-1678.body"
  expect_code 0 "$RC" "sg5: an issue of another repository is not checked"
  assert_equals 0 "$(count_logs "$dir")" "sg5: and logs nothing"
  pass "sg5: an internal-only issue and another repository log nothing"
}

test_sg5_an_unreadable_issue_is_logged_and_refuses_under_block() {
  local dir

  dir=$(make_brief_home sg5-unread board-task-detail)
  write_brief "$dir" "$CFW_ISSUE" "Build the board record."
  printf '#!/usr/bin/env bash\necho "gh: could not reach GitHub" >&2\nexit 1\n' > "$dir/gh"
  check_brief "$dir" "$FIXTURE/cfw-modules-1678.body"
  expect_code 0 "$RC" "sg5: an unreadable issue passes while the check is log-only"
  assert_contains "$ERR" "would refuse: issue-unread" "sg5: the unreadable issue is a would-refuse line"
  assert_contains "$ERR" "$CFW_ISSUE" "sg5: and names the issue"
  assert_equals 1 "$(brief_log "$dir" | awk -F'\t' '$2 == "would-refuse" && $3 == "issue-unread"' | wc -l | tr -d ' ')" \
    "sg5: one issue-unread log line"
  printf 'block\n' > "$dir/home/config/enforce-brief-verify"
  check_brief "$dir" "$FIXTURE/cfw-modules-1678.body"
  expect_code 1 "$RC" "sg5: block refuses a brief whose issue cannot be read"
  assert_contains "$ERR" "refused: issue-unread" "sg5: block names the code"

  # An issue the parser reports problems for is unreadable too: it exits 1 with JSON.
  dir=$(make_brief_home sg5-problems board-task-detail)
  write_brief "$dir" "$CFW_ISSUE" "Build the board record."
  check_brief "$dir" "$FIXTURE/user-visible-no-page.body"
  expect_code 0 "$RC" "sg5: an issue with parser problems passes while the check is log-only"
  assert_contains "$ERR" "would refuse: issue-unread" "sg5: parser problems are an unreadable issue"
  assert_contains "$ERR" "needs a page and widths" "sg5: and the problem is quoted"
  printf 'block\n' > "$dir/home/config/enforce-brief-verify"
  check_brief "$dir" "$FIXTURE/user-visible-no-page.body"
  expect_code 1 "$RC" "sg5: block refuses a brief whose issue has parser problems"

  # An answer that is not an issue body is unreadable too.
  dir=$(make_brief_home sg5-garbage board-task-detail)
  write_brief "$dir" "$CFW_ISSUE" "Build the board record."
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/gh"
  check_brief "$dir" "$FIXTURE/cfw-modules-1678.body"
  assert_contains "$ERR" "would refuse: issue-unread" "sg5: an empty answer is unreadable"
  pass "sg5: an unreadable issue is logged as issue-unread and refuses under block"
}

test_sg2_a_receipt_for_another_run_hits_receipt_fail() {
  local dir

  dir=$(make_case sg2-features user-visible)
  body_file "$dir" "$(selftest_line "${HEAD:0:12}")"
  RECEIPT_FEATURES='["screens-debug-steps"]' write_receipt "$dir" "$HEAD" tester PASS
  run_gate "$dir" "$CFW_URL"
  assert_receipt_hit "$dir" receipt-fail
  assert_contains "$ERR" "features screens-debug-steps" "sg2: the receipt's features are named"
  assert_contains "$ERR" "board-task-detail" "sg2: and the Self-test line's features"

  dir=$(make_case sg2-target user-visible)
  body_file "$dir" "$(selftest_line "${HEAD:0:12}")"
  RECEIPT_TARGET='url:http://127.0.0.1:6999' write_receipt "$dir" "$HEAD" tester PASS
  run_gate "$dir" "$CFW_URL"
  assert_receipt_hit "$dir" receipt-fail
  assert_contains "$ERR" "target url:http://127.0.0.1:6999" "sg2: the receipt's target is named"
  assert_contains "$ERR" "names url:http://127.0.0.1:6123" "sg2: and the Self-test line's target"

  dir=$(make_case sg2-target-5001 user-visible)
  body_file "$dir" "$(selftest_line "${HEAD:0:12}")"
  RECEIPT_TARGET='5001' write_receipt "$dir" "$HEAD" tester PASS
  run_gate "$dir" "$CFW_URL"
  assert_receipt_hit "$dir" receipt-fail

  dir=$(make_case sg2-widths-phone user-visible)
  body_file "$dir" "$(selftest_line "${HEAD:0:12}")"
  RECEIPT_WIDTHS='[1440]' write_receipt "$dir" "$HEAD" tester PASS
  run_gate "$dir" "$CFW_URL"
  assert_receipt_hit "$dir" receipt-fail
  assert_contains "$ERR" "widths (1440) lack 390" "sg2: the missing width is named"

  dir=$(make_case sg2-widths-desktop user-visible)
  body_file "$dir" "$(selftest_line "${HEAD:0:12}")"
  RECEIPT_WIDTHS='[390]' write_receipt "$dir" "$HEAD" tester PASS
  run_gate "$dir" "$CFW_URL"
  assert_receipt_hit "$dir" receipt-fail
  assert_contains "$ERR" "widths (390) lack 1440" "sg2: the other missing width is named"

  dir=$(make_case sg2-fields-absent user-visible)
  body_file "$dir" "$(selftest_line "${HEAD:0:12}")"
  write_receipt "$dir" "$HEAD" tester PASS
  jq 'del(.features, .target, .widths)' "$dir/home/data/$TASK/selftest-$HEAD.json" > "$dir/r.json"
  mv "$dir/r.json" "$dir/home/data/$TASK/selftest-$HEAD.json"
  run_gate "$dir" "$CFW_URL"
  assert_receipt_hit "$dir" receipt-fail

  # The same run in another order, with an extra width, is the same run.
  dir=$(make_case sg2-same-run user-visible)
  body_file "$dir" "Self-test: verify-cfw run screens-debug-steps,board-task-detail --target url:http://127.0.0.1:6123 head=${HEAD:0:12} PASS"
  RECEIPT_FEATURES='["board-task-detail","screens-debug-steps"]' RECEIPT_WIDTHS='[768,390,1440]' write_receipt "$dir" "$HEAD" tester PASS
  run_gate "$dir" "$CFW_URL"
  assert_equals '' "$ERR" "sg2: feature order and an extra width do not matter"
  pass "sg2: a PASS receipt for other features, another target or missing widths hits receipt-fail"
}

test_sg1_pr_1730_body_hits_phrase_on_lines_4_and_16
test_sg2_receipt_at_the_live_head_logs_nothing
test_sg2_each_missing_piece_hits_its_own_code
test_sg3_receipt_rules_stay_inside_user_visible_cfw_modules
test_sg4_a_receipt_written_by_the_author_hits_author_receipt
test_sg5_a_brief_names_the_verify_run_for_each_mapped_page
test_sg5_an_unmapped_page_is_logged_and_never_a_hit
test_sg5_internal_issues_and_other_repositories_log_nothing
test_sg5_an_unreadable_issue_is_logged_and_refuses_under_block
test_sg2_a_receipt_for_another_run_hits_receipt_fail
