#!/usr/bin/env bash
# Behavior tests for bin/fm-procevent-pr-review.sh.
#
# GitHub is a fake `gh` that serves recorded API answers from files, the ChatGPT reader is a
# fake command, and the Reviewer is a real assistance home reached through the real
# `fm-assistance.sh source-event`. The clock is set by FM_PR_REVIEW_NOW, so the settle window,
# the Reviewer timeout and the 60-second poll are driven by the test, not by sleeping.
# Each scenario runs against an adapter copy, so the mutation proofs at the end remove one
# guard at a time and show the scenario that guards it go red.
# shellcheck disable=SC2016 # mutation proofs pass literal source patterns to perl
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pr-review)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
REPO=huynhtandat223/cfw-modules
RURL="https://github.com/$REPO"
T0=1792000000
SCOPE='A finding is in scope only when it names the line in this PR'"'"'s diff (merge-base..head) that causes it. A problem whose cause is not in that range is pre-existing: list it under PRE-EXISTING, never as a finding.'

# A herdr that always fails, so no scenario can reach a real terminal session.
mkdir -p "$TMP_ROOT/fakebin"
printf '#!/usr/bin/env bash\nexit 99\n' > "$TMP_ROOT/fakebin/herdr"
cat > "$TMP_ROOT/fakebin/gh" <<'SH'
#!/usr/bin/env bash
# Serves the recorded answer for `gh api <path>`; a missing file is a failed read.
[ "${1:-}" = api ] || exit 2
if [ -n "${FAKE_GH_FORBID:-}" ]; then : > "$FAKE_GH_DIR/forbidden"; exit 1; fi
[ -z "${FAKE_GH_FAIL:-}" ] || exit 1
f="$FAKE_GH_DIR/$(printf '%s' "$2" | tr '/?&=:' '_____')"
printf '%s\n' "$2" >> "$FAKE_GH_DIR/calls.log"
[ -f "$f" ] || exit 1
cat "$f"
SH
chmod +x "$TMP_ROOT/fakebin/herdr" "$TMP_ROOT/fakebin/gh"
export PATH="$TMP_ROOT/fakebin:$PATH"

# ---- lab ------------------------------------------------------------------

new_lab() {  # <bin-dir>: a firstmate home with a registered Reviewer, a fake reader and the config
  LAB=$(mktemp -d "$TMP_ROOT/lab.XXXXXX")
  H="$LAB/home"
  RH="$LAB/reviewer"
  GHD="$LAB/gh"
  BIN=$1
  SEQ=0
  NOW=$T0
  mkdir -p "$H"/{state,data,config} "$RH/data/pending-mentions" "$GHD"
  printf 'reviewer\n' > "$RH/.fm-assistance-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$H" > "$RH/.fm-assistance-parent"
  register_reviewer
  cat > "$LAB/reader.sh" <<'SH'
#!/usr/bin/env bash
# The fake reader: <chat-url> <prompt-file> <answer-file>. FAKE_READER_FAIL names a failure line.
printf '%s\n' "$1" >> "$FAKE_READER_LOG"
[ -z "${FAKE_READER_WAIT:-}" ] || while [ ! -e "$FAKE_READER_WAIT" ]; do sleep 0.1; done
[ -z "${FAKE_READER_SLEEP:-}" ] || sleep "$FAKE_READER_SLEEP"
[ -z "${FAKE_READER_FAIL:-}" ] || { echo "$FAKE_READER_FAIL"; exit 1; }
inner=$(jq -Rs . < "$FAKE_READER_ANSWER")
outer=$(printf '%s' "$inner" | jq -Rs .)
printf 'chat: %s\n\nresult: %s\n' "${FAKE_READER_CHAT:-$1}" "$outer" > "$3"
SH
  chmod +x "$LAB/reader.sh"
  default_reader_answer
  export FAKE_READER_LOG="$LAB/reader.log" FAKE_READER_ANSWER="$LAB/reader-answer.txt"
  : > "$FAKE_READER_LOG"
  unset FAKE_READER_FAIL FAKE_READER_CHAT FAKE_READER_SLEEP FAKE_READER_WAIT FAKE_GH_FAIL FAKE_GH_FORBID
  write_config
  export FM_HOME="$H" FAKE_GH_DIR="$GHD" FM_PR_REVIEW_ONCE=1 FM_PR_REVIEW_NOW=$NOW
}
register_reviewer() {
  printf -- '- reviewer - Reviewer (home: %s; scope: observe; projects: ; added 2026-10-22)\n' "$RH" > "$H/data/assistances.md"
  printf 'kind=assistance\nharness=claude\nbackend=tmux\nwindow=fm-pr-review-test-absent:0\nhome=%s\n' "$RH" > "$H/state/reviewer.meta"
}
unregister_reviewer() { rm -f "$H/data/assistances.md" "$H/state/reviewer.meta"; }
write_config() {
  jq -n --arg repo "$REPO" --arg cmd "$LAB/reader.sh" \
    '{enabled: true, repos: [$repo], max_rounds: 3, poll_seconds: 0, settle_seconds: 120, reviewer_timeout_seconds: 1800,
      reviewer: {assistance: "reviewer"}, reader: {command: $cmd, project_url: "https://chatgpt.test/project"}}' > "$H/config/pr-review.json"
}
set_config() { jq "$1" "$H/config/pr-review.json" > "$H/config/pr-review.json.tmp" && mv "$H/config/pr-review.json.tmp" "$H/config/pr-review.json"; }
advance() { NOW=$((NOW + $1)); export FM_PR_REVIEW_NOW=$NOW; }

# ---- recorded GitHub answers -----------------------------------------------

gh_put() { printf '%s\n' "$2" > "$GHD/$(printf '%s' "$1" | tr '/?&=:' '_____')"; }
sha() { printf '%s%s' "$1" "0000000000000000000000000000000000000000" | cut -c1-40; }
PATCH_A=$'@@ -8,2 +8,4 @@\n line8\n line9\n+line10\n+line11\n@@ -30,3 +32,2 @@\n line32\n-removed\n line33'
fx_pulls() {  # <number:ref:head-seed>...: the open PRs
  local spec n ref seed json='[]'
  for spec in "$@"; do
    IFS=: read -r n ref seed <<<"$spec"
    json=$(jq -c --argjson n "$n" --arg u "$RURL/pull/$n" --arg ref "$ref" --arg h "$(sha "$seed")" \
      '. + [{number: $n, html_url: $u, head: {sha: $h, ref: $ref}, base: {ref: "main"}}]' <<<"$json")
  done
  gh_put "repos/$REPO/pulls?state=open&per_page=100" "$json"
}
fx_compare() {  # <head-seed> [<files-json>]: the merge-base..head diff
  local files=${2:-}
  [ -n "$files" ] || files=$(jq -cn --arg p "$PATCH_A" '[{filename: "a.txt", status: "modified", patch: $p}]')
  gh_put "repos/$REPO/compare/main...$(sha "$1")" "$(jq -cn --arg mb "$(sha mb)" --argjson files "$files" \
    '{merge_base_commit: {sha: $mb}, commits: [{commit: {committer: {date: "2026-10-22T10:00:00Z"}}}], files: $files}')"
}

# ---- drive the adapter as the runner would -----------------------------------

CYCLE_AUTO=none
CYCLE_SILENT=none
LAST_RESULT=
cycle() {  # one wait; when it returns a result, capture it, ask silent, then autohandle it
  local out inbox="$H/state/procevent-inbox"
  mkdir -p "$H/data/pr-review"
  if ! out=$("$BIN/fm-procevent-pr-review.sh" wait 2>/dev/null); then
    CYCLE_AUTO=none
    CYCLE_SILENT=none
    LAST_RESULT=
    return 0
  fi
  SEQ=$((SEQ + 1))
  mkdir -p "$inbox"
  printf '%s\n' "$out" > "$inbox/pr-review.$SEQ.result"
  printf 'pr-review\n' > "$inbox/pr-review.$SEQ.adapter"
  "$BIN/fm-procevent-pr-review.sh" silent "$inbox/pr-review.$SEQ.result" >/dev/null 2>&1
  CYCLE_SILENT=$?
  "$BIN/fm-procevent-pr-review.sh" autohandle pr-review "$SEQ" "$inbox/pr-review.$SEQ.result" >/dev/null 2>&1
  CYCLE_AUTO=$?
  LAST_RESULT=$out
}
ledger() { cat "$H/data/pr-review/ledger.jsonl" 2>/dev/null; }
ledger_count() {  # <jq-filter>
  [ -s "$H/data/pr-review/ledger.jsonl" ] || { echo 0; return; }
  jq -sc "[.[] | select($1)] | length" "$H/data/pr-review/ledger.jsonl"
}
inbox_count() { find "$H/state/reviewer.inbox" -maxdepth 1 -name '*.msg' 2>/dev/null | wc -l | tr -d ' '; }
reader_calls() { wc -l < "$FAKE_READER_LOG" | tr -d ' '; }
pending_base() {  # <head-seed>: the basename of the Reviewer's pending record for that head
  local f
  for f in "$RH"/data/pending-mentions/*.json; do
    [ -f "$f" ] || continue
    if jq -e --arg h "$(sha "$1")" '.messages[0].content | fromjson | .head == $h' "$f" >/dev/null 2>&1; then basename "$f"; return 0; fi
  done
  return 1
}
# The Reviewer's part: write the report named by the record, then acknowledge the record.
reviewer_answers() {  # <head-seed> [<report-text>]
  local base text=${2:-}
  base=$(pending_base "$1") || { echo "no pending record for $1" >&2; return 1; }
  [ -n "$text" ] || text='FINDING note a.txt:10 the new line is never read | fix: remove it'
  mkdir -p "$RH/data/reviews"
  printf '%s\n' "$text" > "$RH/data/reviews/${base%.json}.md"
  rm -f "$RH/data/pending-mentions/$base"
}
default_reader_answer() { printf 'ChatGPT said:\nFINDING note a.txt:11 reader sees a stale value | fix: refresh it\n' > "$LAB/reader-answer.txt"; }
# Push a head, let it settle, and start its round (both reviewers asked, no result yet).
start_round() {  # <number> <ref> <head-seed> [<files-json>]
  fx_pulls "$1:$2:$3"
  fx_compare "$3" "${4:-}"
  cycle
  advance 130
  cycle
}
finish_round() {  # <head-seed> [<report>]: the Reviewer answers; the next poll returns the round
  reviewer_answers "$1" "${2:-}" || return 1
  advance 60
  cycle
}
baseline() {  # <number> <ref> <head-seed>
  fx_pulls "$1:$2:$3"
  fx_compare "$3"
  cycle
}

# ---- scenarios: each returns 0 when the behavior holds ------------------------

# P2: rounds 1 to 3 ask both reviewers once per head; the 4th head asks nobody and wakes once;
# a head replaced inside the settle window is not a round.
scenario_rounds() {
  new_lab "$1"
  baseline 7 fm/alpha h0
  [ "$(ledger_count '.type == "baseline"')" = 1 ] || { echo 'no baseline line'; ledger; return 1; }
  [ "$CYCLE_AUTO" = none ] && [ "$(inbox_count)" = 0 ] && [ "$(reader_calls)" = 0 ] || { echo 'the baseline head was asked'; return 1; }
  # h1 is replaced by h1b 60 seconds later: only h1b settles, and only once.
  fx_pulls 7:fm/alpha:h1; fx_compare h1
  advance 10; cycle
  fx_pulls 7:fm/alpha:h1b; fx_compare h1b
  advance 60; cycle
  advance 100; cycle
  [ "$(inbox_count)" = 0 ] && [ "$(reader_calls)" = 0 ] || { echo 'a head asked before it stayed 120 seconds'; return 1; }
  advance 30; cycle
  [ "$(inbox_count)" = 1 ] && [ "$(reader_calls)" = 1 ] || { echo "settled head: inbox $(inbox_count), reader $(reader_calls)"; return 1; }
  pending_base h1 >/dev/null 2>&1 && { echo 'the replaced head was asked'; return 1; }
  finish_round h1b || return 1
  [ "$CYCLE_AUTO" = 1 ] || { echo "round result autohandle=$CYCLE_AUTO (want 1: left for the wake)"; return 1; }
  [ "$CYCLE_SILENT" != 0 ] || { echo 'a round result was silent'; return 1; }
  jq -e --arg h "$(sha h1b)" '.kind == "round" and .round == 1 and .task == "alpha" and .pr == 7 and .head == $h and .reviewer.status == "answered" and .reader.status == "answered"' \
    <<<"$LAST_RESULT" >/dev/null || { echo "round 1 result: $LAST_RESULT"; return 1; }
  [ "$(ledger_count '.type == "round" and .round == 1')" = 1 ] || { echo 'round 1 not in the ledger'; return 1; }
  local seed n=0
  for seed in h2 h3; do
    n=$((n + 1))
    start_round 7 fm/alpha "$seed"
    finish_round "$seed" || return 1
    jq -e --argjson r $((n + 1)) '.kind == "round" and .round == $r' <<<"$LAST_RESULT" >/dev/null || { echo "round for $seed: $LAST_RESULT"; return 1; }
  done
  [ "$(inbox_count)" = 3 ] && [ "$(reader_calls)" = 3 ] || { echo "three rounds: inbox $(inbox_count), reader $(reader_calls)"; return 1; }
  # The 4th head: nobody is asked, one cap wake.
  start_round 7 fm/alpha h4
  [ "$(inbox_count)" = 3 ] && [ "$(reader_calls)" = 3 ] || { echo 'the 4th head was asked'; return 1; }
  jq -e '.kind == "cap" and .pr == 7 and (.message | test("round cap reached"))' <<<"$LAST_RESULT" >/dev/null || { echo "cap result: $LAST_RESULT"; return 1; }
  [ "$CYCLE_SILENT" != 0 ] || { echo 'the cap result was silent'; return 1; }
  [ "$(ledger_count '.type == "cap" and .pr == 7')" = 1 ] || { echo 'no cap line'; return 1; }
  # A 5th head after the cap: no ask and no second wake.
  start_round 7 fm/alpha h5
  [ "$CYCLE_AUTO" = none ] && [ "$(inbox_count)" = 3 ] || { echo 'a head after the cap woke or asked'; return 1; }
  [ "$(ledger_count '.type == "cap"')" = 1 ] || { echo 'a second cap line'; return 1; }
  # A branch that is not fm/<task> is recorded once and never asked.
  fx_pulls 7:fm/alpha:h5 8:feature/x:k1
  cycle; cycle
  [ "$(ledger_count '.type == "skip" and .reason == "no-task" and .pr == 8')" = 1 ] || { echo 'no-task skip not recorded once'; ledger; return 1; }
}

# P3: each finding of either reviewer carries one label; none is dropped.
scenario_scope() {
  new_lab "$1"
  baseline 7 fm/alpha h0
  local files report
  files=$(jq -cn --arg p "$PATCH_A" '[{filename: "a.txt", status: "modified", patch: $p}, {filename: "big.bin", status: "added"}]')
  report=$'FINDING blocking a.txt:11 the added branch never resets | fix: reset it\nFINDING note `a.txt:33` the deletion drops the guard | fix: keep the guard\nFINDING note a.txt:20 an old helper leaks | fix: close it\nFINDING blocking gone.txt:3 file outside the diff | fix: none\nFINDING note big.bin:4 binary content | fix: none\nFINDING note the whole module is unclear | fix: split it\nPRE-EXISTING\nlegacy.txt:9 always null'
  printf 'ChatGPT said:\nFINDING note a.txt:9-10 range that touches an added line | fix: x\nFINDING blocking a.txt:32 context line only | fix: y\n' > "$LAB/reader-answer.txt"
  start_round 7 fm/alpha h1 "$files"
  finish_round h1 "$report" || return 1
  local labels
  labels=$(jq -r '.reviewer.findings | map(.label) | join(",")' <<<"$LAST_RESULT")
  [ "$labels" = 'in-scope,in-scope,out-of-scope (pre-existing),out-of-scope (pre-existing),unchecked,unlocated' ] || { echo "reviewer labels: $labels"; return 1; }
  [ "$(jq -r '.reader.findings | map(.label) | join(",")' <<<"$LAST_RESULT")" = 'in-scope,out-of-scope (pre-existing)' ] || { echo "reader labels: $(jq -c '.reader.findings' <<<"$LAST_RESULT")"; return 1; }
  [ "$(jq -r '.reviewer.pre_existing | length' <<<"$LAST_RESULT")" = 1 ] || { echo 'the PRE-EXISTING line was dropped'; return 1; }
  jq -e '.reviewer.findings[0] | .path == "a.txt" and .line == 11 and .severity == "blocking"' <<<"$LAST_RESULT" >/dev/null || { echo 'finding fields'; return 1; }
  jq -e '.reviewer.findings[5] | .path == null and .severity == "note" and .text == "the whole module is unclear | fix: split it"' <<<"$LAST_RESULT" >/dev/null \
    || { echo "unlocated finding lost its text: $(jq -c '.reviewer.findings[5]' <<<"$LAST_RESULT")"; return 1; }
  grep -q 'auto: 2 findings, 1 in scope' "$H/data/alpha/reader-session.md" || { echo 'reader-session line lacks the counts'; cat "$H/data/alpha/reader-session.md"; return 1; }
}

# P4 (the text the reviewers read) and the reader chat: an existing session's last chat is used;
# with none, the project URL opens a new chat and its chat line is written first.
scenario_ask() {
  new_lab "$1"
  baseline 7 fm/alpha h0
  mkdir -p "$H/data/alpha"
  printf 'chat: https://chatgpt.test/c/old\nround 1 (PR 7): head 11111111, answer x\nchat: https://chatgpt.test/c/new\n' > "$H/data/alpha/reader-session.md"
  start_round 7 fm/alpha h1
  [ "$(tail -1 "$FAKE_READER_LOG")" = 'https://chatgpt.test/c/new' ] || { echo "reader chat: $(tail -1 "$FAKE_READER_LOG")"; return 1; }
  local f content prompt head8
  f="$RH/data/pending-mentions/$(pending_base h1)"
  jq -e '.schema == "fm-assistance-mentions.v1" and .messages[0].id == "pr-review:alpha:7:'"$(sha h1 | cut -c1-12)"'"' "$f" >/dev/null || { echo 'record id'; return 1; }
  content=$(jq -r '.messages[0].content' "$f")
  jq -e --arg h "$(sha h1)" --arg mb "$(sha mb)" --arg s "$SCOPE" \
    '.schema == "fm-reviewer-ask.v1" and .task == "alpha" and .pr == "'"$RURL"'/pull/7" and .head == $h and .merge_base == $mb and .round == 1 and .scope == $s and (.report_format | contains("FINDING <blocking|note> <path>:<line> <scenario> | fix: <smallest fix>"))' \
    <<<"$content" >/dev/null || { echo "ask content: $content"; return 1; }
  head8=$(sha h1 | cut -c1-8)
  prompt=$(cat "$H/data/alpha/reader-prompt-$head8.txt") || return 1
  for want in "$RURL/pull/7" "$(sha h1)" "$(sha mb)" "$SCOPE" 'FINDING <blocking|note> <path>:<line> <scenario> | fix: <smallest fix>' 'PRE-EXISTING'; do
    case "$prompt" in *"$want"*) ;; *) echo "prompt lacks: $want"; return 1 ;; esac
  done
  [ -s "$H/data/alpha/reader-gpt-$head8.md" ] || { echo 'reader answer not saved'; return 1; }
  finish_round h1 || return 1
  grep -q "^round 1 (PR 7): head $head8, answer data/alpha/reader-gpt-$head8.md (auto: 1 findings, 1 in scope)\$" "$H/data/alpha/reader-session.md" \
    || { echo 'reader-session round line'; cat "$H/data/alpha/reader-session.md"; return 1; }
  # No session file: a new chat at the project URL, its chat line first.
  baseline 9 fm/beta k0
  start_round 9 fm/beta k1
  [ "$(tail -1 "$FAKE_READER_LOG")" = 'https://chatgpt.test/project' ] || { echo "new chat url: $(tail -1 "$FAKE_READER_LOG")"; return 1; }
  [ "$(head -1 "$H/data/beta/reader-session.md")" = 'chat: https://chatgpt.test/project' ] || { echo 'chat line not first'; cat "$H/data/beta/reader-session.md"; return 1; }
}

# P5: one failing reviewer never stops the other; each round wakes once; no ask is sent twice.
scenario_failures() {
  new_lab "$1"
  baseline 7 fm/alpha h0
  # The Reviewer is not registered: the reader's answer still comes back in the one wake.
  unregister_reviewer
  start_round 7 fm/alpha h1
  [ "$CYCLE_AUTO" = 1 ] || { echo "reviewer failure autohandle=$CYCLE_AUTO"; return 1; }
  jq -e '.kind == "round" and (.reviewer.status | startswith("failed: ")) and .reader.status == "answered"' <<<"$LAST_RESULT" >/dev/null \
    || { echo "unregistered reviewer: $LAST_RESULT"; return 1; }
  cycle
  [ "$CYCLE_AUTO" = none ] || { echo 'the failed round woke twice'; return 1; }
  register_reviewer
  # The reader fails: the Reviewer's answer still comes back.
  export FAKE_READER_FAIL='CHAT NOT FOUND: https://chatgpt.test/c/old'
  start_round 7 fm/alpha h2
  reviewer_answers h2 || return 1
  advance 60; cycle
  jq -e '.kind == "round" and .reviewer.status == "answered" and (.reader.status | startswith("failed: CHAT NOT FOUND"))' <<<"$LAST_RESULT" >/dev/null \
    || { echo "reader failure: $LAST_RESULT"; return 1; }
  [ "$(inbox_count)" = 1 ] || { echo "asks after two failures: $(inbox_count)"; return 1; }
  unset FAKE_READER_FAIL
  # No Reviewer report in 30 minutes: a timeout in the one wake, then one late wake.
  start_round 7 fm/alpha h3
  advance 1700; cycle
  [ "$CYCLE_AUTO" = none ] || { echo 'woke before the timeout'; return 1; }
  advance 200; cycle
  jq -e '.kind == "round" and .reviewer.status == "timeout" and .reader.status == "answered"' <<<"$LAST_RESULT" >/dev/null \
    || { echo "timeout: $LAST_RESULT"; return 1; }
  cycle
  [ "$CYCLE_AUTO" = none ] || { echo 'the timeout woke twice'; return 1; }
  reviewer_answers h3 'FINDING note a.txt:10 late catch | fix: z' || return 1
  advance 60; cycle
  jq -e '.kind == "late" and .round == 3 and .reviewer.status == "answered" and (.reviewer.findings | length) == 1' <<<"$LAST_RESULT" >/dev/null \
    || { echo "late report: $LAST_RESULT"; return 1; }
  [ "$CYCLE_SILENT" != 0 ] || { echo 'the late result was silent'; return 1; }
  cycle
  [ "$CYCLE_AUTO" = none ] || { echo 'the late report woke twice'; return 1; }
  [ "$(inbox_count)" = 2 ] || { echo "asks: $(inbox_count) (want 2: rounds 2 and 3; round 1 had no Reviewer)"; return 1; }
  # GitHub unreadable: one wake naming it, quiet while it lasts, a silent recovery that closes it.
  export FAKE_GH_FAIL=1
  local before=$SEQ
  advance 60; cycle
  [ "$CYCLE_AUTO" = 1 ] && [ "$SEQ" = $((before + 1)) ] || { echo "GitHub failure: autohandle=$CYCLE_AUTO seq=$SEQ"; return 1; }
  jq -e '.kind == "error" and .error != null' <<<"$LAST_RESULT" >/dev/null || { echo "failure result: $LAST_RESULT"; return 1; }
  advance 60; cycle
  [ "$CYCLE_AUTO" = none ] || { echo 'the same GitHub failure woke twice'; return 1; }
  unset FAKE_GH_FAIL
  advance 60; cycle
  [ "$CYCLE_SILENT" = 0 ] || { echo 'the recovery was not silent'; return 1; }
  [ -e "$H/state/procevent-inbox/pr-review.$before.handled" ] || [ -e "$H/state/procevent-inbox/pr-review.$((before + 1)).handled" ] \
    || { echo 'the GitHub failure stayed open after recovery'; return 1; }
}

# P6: off means no GitHub read, no ask, no ledger line; on starts with a baseline, not a round.
scenario_disabled() {
  new_lab "$1"
  export FAKE_GH_FORBID=1
  fx_pulls 7:fm/alpha:h0; fx_compare h0
  rm -f "$H/config/pr-review.json"
  cycle
  write_config; set_config '.enabled = false'
  cycle
  [ ! -e "$GHD/forbidden" ] || { echo 'GitHub was read while the source was off'; return 1; }
  [ ! -e "$H/data/pr-review/ledger.jsonl" ] && [ "$(inbox_count)" = 0 ] && [ "$(reader_calls)" = 0 ] || { echo 'the source left traces while off'; return 1; }
  unset FAKE_GH_FORBID
  set_config '.enabled = true'
  cycle
  [ "$(ledger_count '.type == "baseline" and .pr == 7')" = 1 ] || { echo 'the first poll wrote no baseline'; ledger; return 1; }
  [ "$(ledger_count '.type == "round"')" = 0 ] && [ "$(inbox_count)" = 0 ] && [ "$(reader_calls)" = 0 ] || { echo 'the baseline head was asked'; return 1; }
  start_round 7 fm/alpha h1
  [ "$(inbox_count)" = 1 ] && [ "$(reader_calls)" = 1 ] || { echo 'the first later head was not a round'; return 1; }
}

# A pure deletion at the end of a file anchors to the last line the head still has; a deleted file
# has no head side, so any line named in it is the diff's own.
scenario_eof() {
  new_lab "$1"
  baseline 7 fm/alpha h0
  local files report
  files=$(jq -cn '[{filename: "x.txt", status: "modified", patch: "@@ -5,3 +5,1 @@\n line5\n-gone6\n-gone7"},
    {filename: "gone.txt", status: "removed", patch: "@@ -1,2 +0,0 @@\n-a\n-b"}]')
  report=$'FINDING note x.txt:5 the file now ends early | fix: restore the tail\nFINDING note x.txt:3 above the hunk | fix: none\nFINDING note gone.txt:1 the caller still reads it | fix: update it\nFINDING note gone.txt:2 same | fix: update it'
  start_round 7 fm/alpha h1 "$files"
  finish_round h1 "$report" || return 1
  [ "$(jq -r '.reviewer.findings | map(.label) | join(",")' <<<"$LAST_RESULT")" = "in-scope,out-of-scope (pre-existing),in-scope,in-scope" ] \
    || { echo "labels: $(jq -c '.reviewer.findings | map(.label)' <<<"$LAST_RESULT")"; return 1; }
}

# P6 again: heads pushed while the source was off are not rounds after it is enabled again.
scenario_reenable() {
  new_lab "$1"
  baseline 7 fm/alpha h0
  set_config '.enabled = false'
  fx_pulls 7:fm/alpha:h1; fx_compare h1
  cycle
  advance 300
  set_config '.enabled = true'
  cycle; advance 130; cycle
  [ "$(ledger_count ".type == \"baseline\" and .head == \"$(sha h1)\"")" = 1 ] || { echo 'the head pushed while off got no fresh baseline'; ledger; return 1; }
  [ "$(inbox_count)" = 0 ] && [ "$(reader_calls)" = 0 ] || { echo 'a head pushed while off became a round'; return 1; }
  start_round 7 fm/alpha h2
  [ "$(inbox_count)" = 1 ] && [ "$(reader_calls)" = 1 ] || { echo 'the first head after the baseline was not a round'; return 1; }
}

# Rounds already open finish and time out while GitHub cannot be read; the failure is then announced once.
scenario_pollfail() {
  new_lab "$1"
  baseline 7 fm/alpha h0
  start_round 7 fm/alpha h1
  export FAKE_GH_FAIL=1
  reviewer_answers h1 || return 1
  advance 60; cycle
  jq -e '.kind == "round" and .reviewer.status == "answered"' <<<"$LAST_RESULT" >/dev/null || { echo "round not finished while GitHub failed: ${LAST_RESULT:-none}"; return 1; }
  cycle
  jq -e '.kind == "error"' <<<"$LAST_RESULT" >/dev/null || { echo "GitHub failure not announced after the round: ${LAST_RESULT:-none}"; return 1; }
  unset FAKE_GH_FAIL
  start_round 7 fm/alpha h2
  export FAKE_GH_FAIL=1
  advance 1900; cycle
  jq -e '.kind == "round" and .reviewer.status == "timeout"' <<<"$LAST_RESULT" >/dev/null || { echo "round not timed out while GitHub failed: ${LAST_RESULT:-none}"; return 1; }
}

# A recovery closes the GitHub failures and nothing else: a round still waiting for firstmate stays open.
scenario_recovery() {
  new_lab "$1"
  baseline 7 fm/alpha h0
  start_round 7 fm/alpha h1
  finish_round h1 || return 1
  local round_seq=$SEQ
  jq -e '.kind == "round"' <<<"$LAST_RESULT" >/dev/null || { echo 'no round result'; return 1; }
  export FAKE_GH_FAIL=1
  advance 60; cycle
  local error_seq=$SEQ
  jq -e '.kind == "error"' <<<"$LAST_RESULT" >/dev/null || { echo 'no error result'; return 1; }
  unset FAKE_GH_FAIL
  advance 60; cycle
  [ -e "$H/state/procevent-inbox/pr-review.$error_seq.handled" ] || { echo 'the error result stayed open after recovery'; return 1; }
  [ ! -e "$H/state/procevent-inbox/pr-review.$round_seq.handled" ] || { echo 'the recovery acknowledged a round nobody handled'; return 1; }
  # error, then a round that finishes on the first poll that reads GitHub, then quiet: no recovery may follow.
  start_round 7 fm/alpha h2
  export FAKE_GH_FAIL=1
  advance 60; cycle
  jq -e '.kind == "error"' <<<"$LAST_RESULT" >/dev/null || { echo 'no second error result'; return 1; }
  local second_error=$SEQ
  reviewer_answers h2 || return 1
  unset FAKE_GH_FAIL
  advance 60; cycle
  jq -e '.kind == "round"' <<<"$LAST_RESULT" >/dev/null || { echo 'the round did not finish'; return 1; }
  local second_round=$SEQ
  # The poll that read GitHub again ended the failure episode, so that error result is closed; the round is not.
  [ -e "$H/state/procevent-inbox/pr-review.$second_error.handled" ] || { echo 'the error result stayed open after a round ended the failure'; return 1; }
  [ ! -e "$H/state/procevent-inbox/pr-review.$second_round.handled" ] || { echo 'the round was acknowledged with the error'; return 1; }
  cycle
  [ ! -e "$H/state/procevent-inbox/pr-review.$second_round.handled" ] || { echo 'a later pass acknowledged the round'; return 1; }
  [ "$CYCLE_AUTO" = none ] || { echo 'a recovery followed the round'; return 1; }
}

# A reader that never answers is stopped after reader.timeout_seconds and the round goes on without it.
scenario_readertimeout() {
  new_lab "$1"
  baseline 7 fm/alpha h0
  set_config '.reader.timeout_seconds = 1'
  export FAKE_READER_SLEEP=30
  start_round 7 fm/alpha h1
  finish_round h1 || return 1
  jq -e '.kind == "round" and .reviewer.status == "answered" and (.reader.status | startswith("failed: timeout"))' <<<"$LAST_RESULT" >/dev/null \
    || { echo "reader timeout: $LAST_RESULT"; return 1; }
}

# Two rounds whose readers wait are both asked in one pass instead of one after the other.
scenario_readerconcurrency() {
  new_lab "$1"
  fx_pulls 7:fm/alpha:h0 8:fm/beta:g0
  fx_compare h0
  fx_compare g0
  cycle
  start_round 7 fm/alpha h1
  start_round 8 fm/beta g1
  local f task
  for f in "$H"/data/pr-review/open/*.round.json; do
    [ -f "$f" ] || continue
    task=$(jq -r .task "$f")
    rm -f "$H/data/$task/reader-gpt-$(jq -r .head "$f" | cut -c1-8).md"
    jq '.reader = {status: "pending", answer: null, at: null, findings: [], pre_existing: [], labels: {}}' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  done
  local rounds
  rounds=$(find "$H/data/pr-review/open" -name '*.round.json' | wc -l | tr -d ' ')
  [ "$rounds" = 2 ] || { echo "want two open rounds, got $rounds"; return 1; }
  : > "$FAKE_READER_LOG"
  export FAKE_READER_WAIT="$LAB/reader-release"
  ( sleep 3; : > "$LAB/reader-release" ) &
  advance 60
  cycle
  wait 2>/dev/null || true
  unset FAKE_READER_WAIT
  [ "$(reader_calls)" = 2 ] || { echo "one pass asked the reader $(reader_calls) time(s), want 2 before either answered"; return 1; }
}

# An emitted result starts the next poll generation instead of leaving the source down.
scenario_rearm() {
  new_lab "$1"
  baseline 7 fm/alpha h0
  start_round 7 fm/alpha h1
  reviewer_answers h1 || return 1
  cp -a "$ROOT/bin" "$LAB/bin"
  cat > "$LAB/bin/fm-procevent.sh" <<SH
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> "$LAB/rearm.log"
exit 0
SH
  chmod +x "$LAB/bin/fm-procevent.sh"
  : > "$LAB/rearm.log"
  local out2
  out2=$(FM_PR_REVIEW_ONCE=0 FM_PR_REVIEW_REARM_DELAY_SECONDS=0 "$LAB/bin/fm-procevent-pr-review.sh" wait 2>/dev/null)
  printf '%s\n' "$out2" | jq -e '.schema == "fm-pr-review-result.v1" and .kind == "round"' >/dev/null \
    || { echo "rearm run: $out2"; return 1; }
  local tries=0
  while [ "$tries" -lt 50 ] && ! grep -q 'start pr-review' "$LAB/rearm.log" 2>/dev/null; do
    sleep 0.1; tries=$((tries + 1))
  done
  grep -q 'start pr-review' "$LAB/rearm.log" || { echo "no re-arm call: $(cat "$LAB/rearm.log" 2>/dev/null)"; return 1; }
}

# P7: the summary reads the ledger: rounds, findings by label, commit-to-answer time, timeouts, failures.
scenario_summary() {
  new_lab "$1"
  mkdir -p "$H/data/pr-review"
  local url="$RURL/pull/7" l="$H/data/pr-review/ledger.jsonl"
  {
    jq -cn --arg repo "$REPO" '{type: "baseline", repo: $repo, pr: 7, head: "aaa", at: 1792000000}'
    jq -cn --arg repo "$REPO" '{type: "round", repo: $repo, pr: 7, task: "alpha", head: "bbb", round: 1, at: 1792000500, committed: 1792000100,
      reviewer: {record: "r1.json", status: "answered", report: "x", at: 1792000400, labels: {"in-scope": 2, "out-of-scope (pre-existing)": 1, "unlocated": 0, "unchecked": 0}},
      reader: {status: "answered", answer: "y", at: 1792000250, labels: {"in-scope": 1, "out-of-scope (pre-existing)": 0, "unlocated": 1, "unchecked": 0}}}'
    jq -cn --arg repo "$REPO" '{type: "round", repo: $repo, pr: 7, task: "alpha", head: "ccc", round: 2, at: 1792003000, committed: 1792001000,
      reviewer: {record: "r2.json", status: "timeout", report: null, at: null, labels: {}},
      reader: {status: "failed: CHAT NOT FOUND: x", answer: null, at: null, labels: {}}}'
    jq -cn --arg repo "$REPO" '{type: "late", repo: $repo, pr: 7, head: "ccc", round: 2, at: 1792003600, report: "x", labels: {"in-scope": 1}}'
  jq -cn --arg repo "$REPO" '{type: "cap", repo: $repo, pr: 7, head: "ddd", at: 1792004000}'
    jq -cn --arg repo "$REPO" '{type: "round", repo: $repo, pr: 8, task: "beta", head: "eee", round: 1, at: 1792009000, committed: 1792008900,
      reviewer: {record: "r3.json", status: "answered", report: "x", at: 1792008950, labels: {"in-scope": 3}},
      reader: {status: "answered", answer: "y", at: 1792008960, labels: {}}}'
  } >> "$l"
  local out
  out=$("$BIN/fm-procevent-pr-review.sh" summary 2>&1) || { echo "summary failed: $out"; return 1; }
  case "$out" in *"$url"*) ;; *) echo "no PR 7 section: $out"; return 1 ;; esac
  printf '%s\n' "$out" | grep -q 'reviewer: rounds 2, findings in-scope 3, out-of-scope (pre-existing) 1, unlocated 0, unchecked 0, commit-to-answer 300s/2600s, timeouts 1, failures 0' \
    || { echo "reviewer line for PR 7: $out"; return 1; }
  printf '%s\n' "$out" | grep -q 'reader: rounds 2, findings in-scope 1, out-of-scope (pre-existing) 0, unlocated 1, unchecked 0, commit-to-answer 150s, timeouts 0, failures 1' \
    || { echo "reader line for PR 7: $out"; return 1; }
  printf '%s\n' "$out" | grep -q 'round cap reached: 1' || { echo "cap line: $out"; return 1; }
  out=$("$BIN/fm-procevent-pr-review.sh" summary --since 2026-10-22T00:00:00Z 2>&1)
  case "$out" in *"$url"*) echo 'an old PR survived --since'; return 1 ;; esac
}

# The real runner: a finished round wakes firstmate once and is not applied away.
scenario_runner() {
  new_lab "$1"
  baseline 7 fm/alpha h0
  start_round 7 fm/alpha h1
  reviewer_answers h1 || return 1
  advance 60
  fm_test_track_procevent_home "$H"
  "$BIN/fm-procevent-pr-review.sh" arm >/dev/null 2>&1 || { echo 'arm failed'; return 1; }
  local out
  out=$("$BIN/fm-procevent.sh" start pr-review 2>&1)
  case "$out" in *'not-autohandled: pr-review'*) ;; *) echo "runner: $out"; return 1 ;; esac
  [ "$(grep -c 'procevent pr-review pr-review' "$H/state/.wake-queue" 2>/dev/null || echo 0)" = 1 ] \
    || { echo 'want exactly one wake row'; cat "$H/state/.wake-queue" 2>&1; return 1; }
}

SCENARIOS=${FM_PR_REVIEW_TEST_SCENARIOS:-rounds scope eof ask failures pollfail recovery disabled reenable readertimeout readerconcurrency rearm summary runner}

# ---- real adapter -----------------------------------------------------------

for s in $SCENARIOS; do
  out=$(scenario_"$s" "$ROOT/bin" 2>&1) || fail "scenario $s failed on the real adapter: $out"
  pass "pr-review $s"
done

# ---- mutation proofs: remove one guard, the scenario guarding it goes red ------

MBIN="$TMP_ROOT/mbin"
mkdir -p "$MBIN"
cp "$ROOT"/bin/*.sh "$MBIN/"
ADAPTER="$MBIN/fm-procevent-pr-review.sh"
cp "$ADAPTER" "$TMP_ROOT/adapter.orig"

mutate() {  # <label> <scenario> <perl-substitution>
  cp "$TMP_ROOT/adapter.orig" "$ADAPTER"
  perl -0pi -e "$3" "$ADAPTER"
  cmp -s "$TMP_ROOT/adapter.orig" "$ADAPTER" && fail "mutation '$1' changed nothing"
  if out=$(scenario_"$2" "$MBIN" 2>&1); then
    fail "removing the guard '$1' left scenario $2 green"
  fi
  pass "guard '$1' is needed: scenario $2 goes red without it"
}

mutate 'the round cap' rounds \
  's/if \[ "\$count" -ge "\$MAX_ROUNDS" \]; then/if false; then/'
mutate 'a head must settle' rounds \
  's/\[ \$\(\( \$\(now\) - since \)\) -ge "\$SETTLE_SECONDS" \] \|\| return 0//'
mutate 'a replaced head restarts the settle clock' rounds \
  's/\{head: \$h, since: \$s, handled: false\}/{head: \$h, since: (.heads[\$k].since \/\/ \$s), handled: false}/'
mutate 'the first poll is a baseline' disabled \
  's/if \[ -z "\$first" \]; then\n    ledger_append/if false; then\n    ledger_append/'
mutate 'enabled false reads nothing' disabled \
  's/jq -e .\.enabled == true. "\$CONFIG" >\/dev\/null 2>&1 \|\| return 1/:/'
mutate 'a branch that is not fm/<task> is skipped' rounds \
  's/case "\$ref" in fm\/\*\) task=\$\{ref#fm\/\} ;; esac/task=\${ref##*\/}/'
mutate 'a pure deletion counts as a changed line' scope \
  's/\/\^-\/ \{ if \(h >= a \+ 0 && h <= b \+ 0\) hit = 1; lastminus = 1; next \}/\/^-\/ { lastminus = 1; next }/'
mutate 'a context line is not a changed line' scope \
  's/\{ h\+\+; lastminus = 0 \}\n        END/{ h++; lastminus = 0; if (h - 1 >= a + 0 \&\& h - 1 <= b + 0) hit = 1 }\n        END/'
mutate 'a file with no patch is unchecked' scope \
  's/nopatch\) echo unchecked ;;/nopatch) echo "\$LABEL_OUT" ;;/'
mutate 'a finding with no location is unlocated' scope \
  's/\{ \[ -n "\$path" \] && \[ -n "\$ls" \]; \} \|\| \{ echo unlocated; return 0; \}//'
mutate 'a file outside the diff is pre-existing' scope \
  's/none\) echo "\$LABEL_OUT" ;;/none) echo "\$LABEL_IN" ;;/'
mutate 'the scope rule is word for word' ask \
  's/A finding is in scope only when/A finding is in scope when/'
mutate 'a late Reviewer report wakes once more' failures \
  's/poll_late\n  rc=\$\?\n  \[ "\$rc" -eq 10 \] && return 0/return 1/'
mutate 'the Reviewer times out' failures \
  's/-ge "\$REVIEWER_TIMEOUT"/-ge 99999999/'
mutate 'a repeated GitHub failure stays quiet' failures \
  's/if \[ "\$previous" != "\$READ_ERROR" \]; then/if true; then/'
mutate 'a recovery closes the old failure' failures \
  's/rm -f "\$LAST_ERROR"\n      mark_errors_handled "\$seq"/rm -f "\$LAST_ERROR"/'
mutate 'commit-to-answer time' summary \
  's/\\\(\.\[\$who\]\.at - \.committed\)s/\\(.[\$who].at + .committed)s/'
mutate 'a deletion at the end of a file anchors to its last line' eof \
  's/function eof_anchor\(\) \{ if \(lastminus/function eof_anchor() { if (0 \&\& lastminus/'
mutate 'a deleted file has no head side' eof \
  's/if \(h == 0\) hit = 1/if (0) hit = 1/'
mutate 'finding fields keep empty parts' scope \
  's/IFS=\$.\\037. read -r kind/IFS=\$\x27\\t\x27 read -r kind/'
mutate 'off forgets the first-poll marks' reenable \
  's/state_edit .del\(\.started\) \| del\(\.heads\). *$/:/m'
mutate 'open rounds finish while GitHub fails' pollfail \
  's/2\) POLL_FAILED=1 ;; 10\) return 0 ;; esac/2) return 2 ;; 10) return 0 ;; esac/'
mutate 'a recovery closes only error results' recovery \
  's/mark_errors_handled "\$seq"/mark_handled "\$seq"/'
mutate 'a round that ends a failure episode closes its error results' recovery \
  's/\[ -z "\$previous" \] \|\| mark_errors_handled 999999999999/:/'
mutate 'a poll that reads GitHub ends the failure episode' recovery \
  's/if \[ "\$POLL_FAILED" -eq 0 \]; then\n          rm -f "\$LAST_ERROR"/if false; then\n          rm -f "\$LAST_ERROR"/'
mutate 'a reader that never answers is stopped' readertimeout \
  's/if \[ "\$rc" -eq 124 \]; then/if false; then/'
mutate 'a late report joins its round in the summary' summary \
  's/else \.reviewer \|= \(\. \+ \{labels: \$l\.labels, at: \$l\.at\}\) end/else . end/'
mutate 'every pending reader round runs in one pass' readerconcurrency \
  's/    run_reader "\$f" &/    run_reader "\$f"; break/'
pass 'every guarded behavior has a red mutation proof'
