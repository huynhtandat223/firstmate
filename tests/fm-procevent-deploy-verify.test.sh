#!/usr/bin/env bash
# Behavior tests for bin/fm-procevent-deploy-verify.sh.
#
# GitHub is a fake `gh` that serves recorded API answers from files, so every
# case is deterministic and no network is used. The Tester is a real assistance
# home reached through the real `fm-assistance.sh source-event`. Each scenario
# runs against an adapter copy, so the mutation proofs at the end remove one
# guard at a time and show the scenario that guards it go red.
# shellcheck disable=SC2016 # mutation proofs pass literal source patterns to perl
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-deploy-verify)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
REPO=huynhtandat223/cfw-modules
RURL="https://github.com/$REPO"

# A herdr that always fails, so no scenario can reach a real terminal session.
mkdir -p "$TMP_ROOT/fakebin"
printf '#!/usr/bin/env bash\nexit 99\n' > "$TMP_ROOT/fakebin/herdr"
cat > "$TMP_ROOT/fakebin/gh" <<'SH'
#!/usr/bin/env bash
# Serves the recorded answer for `gh api <path>`; a missing file is a failed read.
[ "${1:-}" = api ] || exit 2
[ -z "${FAKE_GH_FAIL:-}" ] || exit 1
f="$FAKE_GH_DIR/$(printf '%s' "$2" | tr '/?&=:' '_____')"
printf '%s\n' "$2" >> "$FAKE_GH_DIR/calls.log"
[ -f "$f" ] || exit 1
cat "$f"
SH
chmod +x "$TMP_ROOT/fakebin/herdr" "$TMP_ROOT/fakebin/gh"
export PATH="$TMP_ROOT/fakebin:$PATH"

# ---- lab ------------------------------------------------------------------

new_lab() {  # <bin-dir>: a firstmate home with a registered Tester
  LAB=$(mktemp -d "$TMP_ROOT/lab.XXXXXX")
  H="$LAB/home"
  TH="$LAB/tester"
  GHD="$LAB/gh"
  BIN=$1
  SEQ=0
  mkdir -p "$H"/{state,data,config} "$TH/data/pending-mentions" "$GHD"
  printf 'tester\n' > "$TH/.fm-assistance-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$H" > "$TH/.fm-assistance-parent"
  register_tester
  : > "$H/data/backlog.md"
  export FM_HOME="$H" FAKE_GH_DIR="$GHD" FM_DEPLOY_VERIFY_POLL_SECONDS=0 FM_DEPLOY_VERIFY_ONCE=1
  unset FAKE_GH_FAIL
}
register_tester() {
  printf -- '- tester - Tester (home: %s; scope: observe; projects: ; added 2026-10-20)\n' "$TH" > "$H/data/assistances.md"
  printf 'kind=assistance\nharness=claude\nbackend=tmux\nwindow=fm-deploy-verify-test-absent:0\nhome=%s\n' "$TH" > "$H/state/tester.meta"
}
unregister_tester() { rm -f "$H/data/assistances.md" "$H/state/tester.meta"; }

# ---- recorded GitHub answers -----------------------------------------------

gh_put() { printf '%s\n' "$2" > "$GHD/$(printf '%s' "$1" | tr '/?&=:' '_____')"; }
sha() { printf '%s%s' "$1" "0000000000000000000000000000000000000000" | cut -c1-40; }
fx_runs() {  # <id:status:conclusion:sha-seed>...
  local spec json='[]' id status conclusion seed
  for spec in "$@"; do
    IFS=: read -r id status conclusion seed <<<"$spec"
    json=$(jq -c --argjson id "$id" --arg s "$status" --arg c "$conclusion" --arg h "$(sha "$seed")" \
      '. + [{id: $id, name: "CI", status: $s, conclusion: (if $c == "" then null else $c end), head_sha: $h, html_url: ("https://example.test/runs/" + ($id | tostring))}]' <<<"$json")
  done
  gh_put "repos/$REPO/actions/runs?branch=main&event=push&per_page=30" "$(jq -c '{workflow_runs: .}' <<<"$json")"
}
fx_jobs() {  # <run-id> <conclusion>
  gh_put "repos/$REPO/actions/runs/$1/jobs?per_page=100" \
    "{\"jobs\":[{\"name\":\"Build\",\"conclusion\":\"success\"},{\"name\":\"Deploy Development host (5001)\",\"conclusion\":\"$2\",\"completed_at\":\"2026-10-20T14:30:20Z\"}]}"
}
fx_compare() {  # <base-seed> <head-seed> <commit-seed>...
  local base=$1 head=$2 c json='[]'
  shift 2
  for c in "$@"; do json=$(jq -c --arg s "$(sha "$c")" '. + [{sha: $s}]' <<<"$json"); done
  gh_put "repos/$REPO/compare/$(sha "$base")...$(sha "$head")" "{\"commits\":$json}"
}
fx_commit_prs() {  # <commit-seed> <pr-number:issue-number>...
  local c=$1 spec json='[]'
  shift
  for spec in "$@"; do
    json=$(jq -c --arg u "$RURL/pull/${spec%%:*}" --arg b "Closes #${spec##*:}" \
      '. + [{html_url: $u, merged_at: "2026-10-20T14:00:00Z", base: {ref: "main"}, body: $b}]' <<<"$json")
  done
  gh_put "repos/$REPO/commits/$(sha "$c")/pulls" "$json"
}
issue_body() {  # <id:surface[:draft]>...
  local spec id surface draft
  printf '## Context\n\nSomething.\n\n## Acceptance\n\n'
  for spec in "$@"; do
    IFS=: read -r id surface draft <<<"$spec"
    printf -- '- [ ] %s WHEN a user acts, THE page SHALL answer.\n' "$id"
    if [ -n "$draft" ]; then printf '  - env/page: `firstmate.board.inbox` (draft)\n'; else printf '  - env/page: `firstmate.board`\n'; fi
    printf '  - surface: %s\n' "$surface"
  done
  printf '\n## Notes\n\n- [ ] A99 not an acceptance line\n  - surface: user-visible\n'
}
fx_issue() {  # <number> <id:surface[:draft]>...
  local n=$1
  shift
  gh_put "repos/$REPO/issues/$n" "$(jq -cn --arg b "$(issue_body "$@")" '{body: $b}')"
}
fx_pr() {  # <number> <state> <head-seed> <issue-number>
  gh_put "repos/$REPO/pulls/$1" "$(jq -cn --arg s "$2" --arg h "$(sha "$3")" --arg b "Part of #$4" '{state: $s, head: {sha: $h}, body: $b}')"
  gh_put "repos/$REPO/commits/$(sha "$3")" '{"commit":{"committer":{"date":"2026-10-20T15:00:00Z"}}}'
}
backlog_task() {  # <task> <pr-number> [issue-number]
  printf -- '- [x] %s - Title%s %s/pull/%s (repo: cfw-modules) (kind: ship) (merged 2026-10-20)\n' \
    "$1" "${3:+ (cfw-modules #$3)}" "$RURL" "$2" >> "$H/data/backlog.md"
}
live_task() {  # <task> <pr-number> [surface]
  printf 'kind=ship\npr=%s/pull/%s\nsurface=%s\n' "$RURL" "$2" "${3:-user-visible}" > "$H/state/$1.meta"
}
set_cursor() { mkdir -p "$H/data/deploy-verify"; printf '{"cursor_run":%s,"last_green_sha":"%s"}\n' "$1" "$(sha "$2")" > "$H/data/deploy-verify/state.json"; }

# ---- drive the adapter as the runner would -----------------------------------

CYCLE_AUTO=none
cycle() {  # one wait; when it returns a result, capture it and autohandle it
  local out inbox="$H/state/procevent-inbox"
  mkdir -p "$H/data/deploy-verify"
  if ! out=$("$BIN/fm-procevent-deploy-verify.sh" wait 2>/dev/null); then
    CYCLE_AUTO=none
    return 0
  fi
  SEQ=$((SEQ + 1))
  mkdir -p "$inbox"
  printf '%s\n' "$out" > "$inbox/deploy-verify.$SEQ.result"
  printf 'deploy-verify\n' > "$inbox/deploy-verify.$SEQ.adapter"
  "$BIN/fm-procevent-deploy-verify.sh" autohandle deploy-verify "$SEQ" "$inbox/deploy-verify.$SEQ.result" >/dev/null 2>&1
  CYCLE_AUTO=$?
  LAST_RESULT=$out
}
ledger() { cat "$H/data/deploy-verify/ledger.jsonl" 2>/dev/null; }
ledger_count() {  # <jq-filter>
  [ -s "$H/data/deploy-verify/ledger.jsonl" ] || { echo 0; return; }
  jq -sc "[.[] | select($1)] | length" "$H/data/deploy-verify/ledger.jsonl"
}
inbox_count() { find "$H/state/tester.inbox" -maxdepth 1 -name '*.msg' 2>/dev/null | wc -l | tr -d ' '; }
asked() {  # the content of every pending ask, one JSON per line
  local f
  for f in "$TH"/data/pending-mentions/*.json; do [ -f "$f" ] && jq -c '.messages[0].content | fromjson' "$f"; done
}

# ---- scenarios: each returns 0 when the behavior holds ------------------------

# Mapping and ledger: two PRs of one task in one deploy give one ask; the next
# deploy that still contains a PR already asked about asks nothing.
scenario_ledger() {
  new_lab "$1"
  backlog_task alpha 11 500; backlog_task alpha 12 500; backlog_task beta 13 600
  fx_issue 500 V1:user-visible A2:internal; fx_issue 600 E10:user-visible
  fx_runs "1:completed:success:s0" "2:completed:success:s2"
  fx_jobs 2 success
  fx_compare s0 s2 c1 c2 c3
  fx_commit_prs c1 11:500; fx_commit_prs c2 12:500; fx_commit_prs c3 13:600
  set_cursor 1 s0
  cycle
  [ "$CYCLE_AUTO" = 0 ] || { echo "autohandle=$CYCLE_AUTO"; return 1; }
  jq -e '(.asks | length) == 2' <<<"$LAST_RESULT" >/dev/null || { echo 'the deploy result is not one ask per task'; return 1; }
  [ "$(ledger_count '.type == "ask"')" = 2 ] || { echo "asks: $(ledger_count '.type == "ask"')"; return 1; }
  [ "$(inbox_count)" = 2 ] || { echo "inbox: $(inbox_count)"; return 1; }
  [ "$(ledger_count '.type == "ask" and .task == "alpha" and (.prs | length) == 2 and .lines == ["V1"] and .issue == "cfw-modules#500"')" = 1 ] \
    || { echo 'task alpha ask is not one ask with both PRs and its one user-visible line'; return 1; }
  # A later green deploy whose range returns PR 11 again.
  fx_runs "1:completed:success:s0" "2:completed:success:s2" "3:completed:success:s3"
  fx_jobs 3 success
  fx_compare s2 s3 c4
  fx_commit_prs c4 11:500
  cycle
  [ "$(ledger_count '.type == "ask"')" = 2 ] || { echo "repeat ask recorded: $(ledger_count '.type == "ask"')"; return 1; }
  [ "$(inbox_count)" = 2 ] || { echo "repeat reached the Tester: $(inbox_count)"; return 1; }
}

# Skips: internal task, no user-visible line, and no task each send nothing and
# leave a reason in the ledger.
scenario_skips() {
  new_lab "$1"
  live_task inner 21 internal
  fx_pr 21 closed h0 800
  backlog_task plain 22 700; backlog_task noissue 24
  fx_issue 700 A1:internal
  fx_runs "1:completed:success:s0" "2:completed:success:s1"
  fx_jobs 2 success
  fx_compare s0 s1 c1 c2 c3 c4
  fx_commit_prs c1 21:800; fx_commit_prs c2 22:700; fx_commit_prs c3 23:900
  gh_put "repos/$REPO/commits/$(sha c4)/pulls" "[{\"html_url\":\"$RURL/pull/24\",\"merged_at\":\"2026-10-20T14:00:00Z\",\"base\":{\"ref\":\"main\"},\"body\":\"No reference.\"}]"
  set_cursor 1 s0
  cycle
  [ "$CYCLE_AUTO" = 1 ] || { echo "skip did not request attention: $CYCLE_AUTO"; return 1; }
  [ "$(jq -r .cursor_run "$H/data/deploy-verify/state.json")" = 2 ] || return 1
  "$BIN/fm-procevent-deploy-verify.sh" silent "$H/state/procevent-inbox/deploy-verify.$SEQ.result" && return 1
  [ "$(inbox_count)" = 0 ] || { echo "an ask was sent: $(inbox_count)"; ledger; ls "$H/state/tester.inbox"; return 1; }
  [ "$(ledger_count '.type == "ask"')" = 0 ] || return 1
  local reason
  for reason in internal no-user-visible-line no-task no-issue; do
    [ "$(ledger_count ".type == \"skip\" and .reason == \"$reason\"")" = 1 ] || { echo "missing skip reason $reason"; return 1; }
  done
}

# A skipped, cancelled or failed deploy asks nothing; the next green deploy
# carries the commits of every run since the last green one.
scenario_not_deployed() {
  new_lab "$1"
  backlog_task alpha 31 500; backlog_task beta 32 600
  fx_issue 500 A1:user-visible; fx_issue 600 A1:user-visible
  fx_runs "1:completed:success:s0" "2:completed:cancelled:s1" "3:completed:success:s2"
  fx_jobs 2 skipped; fx_jobs 3 success
  fx_compare s0 s2 c1 c2
  fx_commit_prs c1 31:500; fx_commit_prs c2 32:600
  # The cancelled run's own commit must never be asked on its own.
  fx_compare s0 s1 c1
  set_cursor 1 s0
  cycle
  [ "$CYCLE_AUTO" = 0 ] || { echo "autohandle=$CYCLE_AUTO"; return 1; }
  [ "$(ledger_count '.type == "ask"')" = 2 ] || { echo "asks: $(ledger_count '.type == "ask"')"; return 1; }
  [ "$(ledger_count ".type == \"ask\" and .sha == \"$(sha s2)\"")" = 2 ] || { echo 'asks do not name the green deploy'; return 1; }
  # A run still in progress holds the cursor.
  fx_runs "1:completed:success:s0" "2:completed:cancelled:s1" "3:completed:success:s2" "4:in_progress::s3"
  fx_jobs 4 in_progress
  cycle
  [ "$(jq -r .cursor_run "$H/data/deploy-verify/state.json")" = 3 ] || { echo 'cursor moved past a run in progress'; return 1; }
}

# Draft round: each new head of a task PR whose issue has (draft) lines gets one
# ask for those lines; the same head asks nothing; a later head asks again.
scenario_draft() {
  new_lab "$1"
  live_task gamma 41
  fx_issue 900 E10:user-visible:draft A2:user-visible C14:internal:draft
  fx_runs "1:completed:success:s0"
  set_cursor 1 s0
  fx_pr 41 open h1 900
  cycle
  [ "$CYCLE_AUTO" = 0 ] || { echo "autohandle=$CYCLE_AUTO"; return 1; }
  [ "$(ledger_count '.type == "ask" and .round == "draft"')" = 1 ] || { echo "draft asks: $(ledger_count '.type == "ask" and .round == "draft"')"; return 1; }
  [ "$(ledger_count ".type == \"ask\" and .head == \"$(sha h1)\" and .lines == [\"E10\",\"C14\"] and .task == \"gamma\" and .issue == \"cfw-modules#900\"")" = 1 ] \
    || { echo 'draft ask does not name the task, issue, head and draft lines'; ledger; return 1; }
  cycle
  [ "$CYCLE_AUTO" = none ] || { echo 'the same head produced a second ask'; return 1; }
  [ "$(ledger_count '.type == "ask"')" = 1 ] || { echo 'the same head asked twice'; return 1; }
  fx_pr 41 open h2 900
  cycle
  [ "$(ledger_count '.type == "ask" and .round == "draft"')" = 2 ] || { echo 'the new head was not asked'; return 1; }
  [ "$(ledger_count ".type == \"ask\" and .head == \"$(sha h2)\"")" = 1 ] || return 1
  [ "$(inbox_count)" = 2 ] || { echo "inbox: $(inbox_count)"; return 1; }
  # An issue with no draft line asks nothing, and is remembered for that head.
  live_task delta 42
  fx_issue 901 A1:user-visible
  fx_pr 42 open h3 901
  cycle
  [ "$(inbox_count)" = 2 ] || { echo 'a PR without draft lines was asked'; return 1; }
  [ "$(ledger_count '.type == "draft-skip" and .reason == "no-draft-lines"')" = 1 ] || return 1
  # A closed PR is not asked.
  live_task eps 43
  fx_pr 43 closed h4 900
  cycle
  [ "$(inbox_count)" = 2 ] || { echo 'a closed PR was asked'; return 1; }
}

# The ask is a source record the Tester can read and acknowledge.
scenario_record() {
  new_lab "$1"
  backlog_task alpha 51 500
  fx_issue 500 A1:user-visible
  fx_runs "1:completed:success:s0" "2:completed:success:s2"
  fx_jobs 2 success
  fx_compare s0 s2 c1
  fx_commit_prs c1 51:500
  set_cursor 1 s0
  cycle
  local f base content
  f=$(find "$TH/data/pending-mentions" -name '*.json' | head -1)
  [ -n "$f" ] || { echo 'no pending record'; return 1; }
  base=$(basename "$f")
  jq -e '.schema == "fm-assistance-mentions.v1" and (.messages | length) == 1' "$f" >/dev/null || { echo 'record shape'; return 1; }
  [ "$(jq -c '.messages | map([.id,.arrival])' "$f" | sha256sum | cut -d' ' -f1).json" = "$base" ] || { echo 'basename is not the content digest'; return 1; }
  content=$(jq -r '.messages[0].content' "$f")
  jq -e --arg sha "$(sha s2)" '.schema == "fm-tester-verify.v1" and .round == "deploy" and .task == "alpha" and .issue == "cfw-modules#500" and .sha == $sha and (.prs == ["'"$RURL"'/pull/51"]) and .run == "https://example.test/runs/2"' <<<"$content" >/dev/null \
    || { echo "ask content: $content"; return 1; }
  grep -q "$base" "$H/state/tester.inbox/001.msg" || { echo 'inbox message does not name the record'; return 1; }
  # After the Tester handles the inbox message, it acknowledges the record.
  mkdir -p "$H/state/tester.inbox/handled"
  mv "$H/state/tester.inbox/001.msg" "$H/state/tester.inbox/handled/001.msg"
  FM_HOME="$TH" "$BIN/fm-assistance.sh" acknowledge-source "$base" >/dev/null 2>&1 || { echo 'acknowledge-source refused'; return 1; }
  [ ! -e "$f" ] || { echo 'record still pending'; return 1; }
}

# An undeliverable ask and an unreadable GitHub each leave one result for the
# wake, retry without sending twice, and stay quiet while the same reason holds.
scenario_failures() {
  new_lab "$1"
  backlog_task alpha 61 500
  fx_issue 500 A1:user-visible
  fx_runs "1:completed:success:s0" "2:completed:success:s2"
  fx_jobs 2 success
  fx_compare s0 s2 c1
  fx_commit_prs c1 61:500
  set_cursor 1 s0
  unregister_tester
  cycle
  [ "$CYCLE_AUTO" = 1 ] || { echo "first failure autohandle=$CYCLE_AUTO (want 1: left for the wake)"; return 1; }
  [ ! -e "$H/state/procevent-inbox/deploy-verify.1.handled" ] || { echo 'the failed result was acknowledged'; return 1; }
  [ "$(ledger_count '.type == "ask"')" = 0 ] || return 1
  [ "$(jq -r .cursor_run "$H/data/deploy-verify/state.json")" = 1 ] || { echo 'cursor advanced past an undelivered ask'; return 1; }
  cycle
  [ "$CYCLE_AUTO" = 0 ] || { echo "same reason again autohandle=$CYCLE_AUTO (want 0: already announced)"; return 1; }
  register_tester
  cycle
  [ "$CYCLE_AUTO" = 0 ] || { echo "recovery autohandle=$CYCLE_AUTO"; return 1; }
  [ "$(ledger_count '.type == "ask"')" = 1 ] || { echo "asks after recovery: $(ledger_count '.type == "ask"')"; return 1; }
  [ "$(inbox_count)" = 1 ] || { echo "inbox after recovery: $(inbox_count)"; return 1; }
  [ "$(jq -r .cursor_run "$H/data/deploy-verify/state.json")" = 2 ] || { echo 'cursor did not advance after delivery'; return 1; }
  [ -e "$H/state/procevent-inbox/deploy-verify.1.handled" ] || { echo 'the old failed result stayed open after recovery'; return 1; }
  cycle
  [ "$(inbox_count)" = 1 ] || { echo 'a further poll sent the ask again'; return 1; }
  # GitHub unreadable: one result for the wake, then quiet, then a recovery record.
  fx_runs "1:completed:success:s0" "2:completed:success:s2" "3:completed:success:s3"
  fx_jobs 3 success
  fx_compare s2 s3 c9
  fx_commit_prs c9 62:501
  export FAKE_GH_FAIL=1
  local before=$SEQ
  cycle
  [ "$CYCLE_AUTO" = 1 ] && [ "$SEQ" = $((before + 1)) ] || { echo "GitHub failure: autohandle=$CYCLE_AUTO"; return 1; }
  jq -e '.error != null and (.asks | length) == 0' "$H/state/procevent-inbox/deploy-verify.$SEQ.result" >/dev/null || { echo 'failure result carries no reason'; return 1; }
  cycle
  [ "$CYCLE_AUTO" = none ] || { echo 'the same GitHub failure produced a second result'; return 1; }
  unset FAKE_GH_FAIL
  cycle
  [ -e "$H/state/procevent-inbox/deploy-verify.$SEQ.handled" ] || { echo 'the GitHub failure result stayed open after recovery'; return 1; }
  [ ! -e "$H/data/deploy-verify/last-error" ] || { echo 'the failure reason was not cleared'; return 1; }
}

# The real runner: a delivered ask wakes nobody, an undeliverable one wakes once.
scenario_runner() {
  new_lab "$1"
  backlog_task alpha 71 500
  fx_issue 500 A1:user-visible
  fx_runs "1:completed:success:s0" "2:completed:success:s2"
  fx_jobs 2 success
  fx_compare s0 s2 c1
  fx_commit_prs c1 71:500
  set_cursor 1 s0
  fm_test_track_procevent_home "$H"
  "$BIN/fm-procevent-deploy-verify.sh" arm >/dev/null 2>&1 || { echo 'arm failed'; return 1; }
  local out
  out=$("$BIN/fm-procevent.sh" start deploy-verify 2>&1)
  case "$out" in *'autohandled: deploy-verify'*) ;; *) echo "runner: $out"; return 1 ;; esac
  [ "$(inbox_count)" = 1 ] || { echo "inbox: $(inbox_count)"; return 1; }
  if [ -s "$H/state/.wake-queue" ]; then echo 'a delivered ask woke firstmate'; return 1; fi
  # A visible skip advances the cursor but publishes one real runner wake.
  fx_runs "1:completed:success:s0" "2:completed:success:s2" "3:completed:success:s3"
  fx_jobs 3 success
  fx_compare s2 s3 cskip
  fx_commit_prs cskip 73:501 74:502 75:503
  backlog_task visible 73 501
  live_task internal 74 internal
  fx_pr 74 closed h0 502
  fx_issue 501 A1:internal
  out=$("$BIN/fm-procevent.sh" start deploy-verify 2>&1)
  case "$out" in *'not-autohandled: deploy-verify'*) ;; *) echo "skip runner: $out"; return 1 ;; esac
  [ "$(grep -c 'procevent deploy-verify deploy-verify' "$H/state/.wake-queue")" = 1 ] || return 1
  [ "$(jq -r .cursor_run "$H/data/deploy-verify/state.json")" = 3 ] || return 1
  "$BIN/fm-procevent.sh" handled deploy-verify 2 >/dev/null 2>&1 || return 1
  : > "$H/state/.wake-queue"
  "$BIN/fm-procevent.sh" start deploy-verify >/dev/null 2>&1
  [ ! -s "$H/state/.wake-queue" ] || { echo 'skip woke twice'; return 1; }
  # An undeliverable ask: one wake row naming the source.
  fx_runs "1:completed:success:s0" "2:completed:success:s2" "3:completed:success:s3" "4:completed:success:s4"
  fx_jobs 4 success
  fx_compare s3 s4 c2
  fx_commit_prs c2 72:500
  backlog_task beta 72 500
  unregister_tester
  out=$("$BIN/fm-procevent.sh" start deploy-verify 2>&1)
  case "$out" in *'not-autohandled: deploy-verify'*) ;; *) echo "runner failure: $out"; return 1 ;; esac
  [ "$(grep -c 'procevent deploy-verify deploy-verify' "$H/state/.wake-queue" 2>/dev/null || echo 0)" = 1 ] \
    || { echo 'want exactly one wake row'; cat "$H/state/.wake-queue" 2>&1; return 1; }
}

scenario_replay() {
  new_lab "$1"
  set_cursor 2 s2
  local n before dry
  for n in 81 82 83 84 86; do
    backlog_task "replay$((n / 2))" "$n" 500
    gh_put "repos/$REPO/pulls/$n" "$(jq -cn --arg m "$(sha "m$n")" '{body:"Closes #500", merge_commit_sha:$m}')"
    gh_put "repos/$REPO/compare/$(sha "m$n")...$(sha s2)" '{"status":"ahead"}'
    jq -cn --arg p "$RURL/pull/$n" --arg t "replay$((n / 2))" '{type:"skip", reason:"no-user-visible-line", pr:$p, task:$t}' >> "$H/data/deploy-verify/ledger.jsonl"
  done
  gh_put "repos/$REPO/compare/$(sha m81)...$(sha s2)" '{"status":"behind"}'
  gh_put "repos/$REPO/pulls/84" "$(jq -cn --arg m "$(sha m84)" '{body:"Closes #501", merge_commit_sha:$m}')"
  fx_issue 500 V1:user-visible; fx_issue 501 A1:internal
  jq -cn --arg k "replay:replay43:$(sha s2)" '{type:"ask", round:"deploy", key:$k, prs:[]}' >> "$H/data/deploy-verify/ledger.jsonl"
  # An ask for another task must not hide this task's skip of the same PR.
  jq -cn --arg p "$RURL/pull/82" '{type:"ask", round:"deploy", key:"other-task", task:"other", prs:[$p]}' >> "$H/data/deploy-verify/ledger.jsonl"
  before=$(ledger)
  dry=$("$BIN/fm-procevent-deploy-verify.sh" replay-skips --dry-run) || return 1
  [ "$before" = "$(ledger)" ] && [ "$(inbox_count)" = 0 ] || return 1
  jq -se 'length == 1 and .[0].lines == ["V1"] and (.[0].prs | length) == 2' <<<"$dry" >/dev/null || { echo "bad replay plan: $dry"; return 1; }
  "$BIN/fm-procevent-deploy-verify.sh" replay-skips >/dev/null || return 1
  [ "$(inbox_count)" = 1 ] || return 1
  before=$(ledger)
  [ -z "$("$BIN/fm-procevent-deploy-verify.sh" replay-skips)" ] || return 1
  [ "$before" = "$(ledger)" ] && [ "$(inbox_count)" = 1 ] || return 1
}

run_scenarios() {  # <bin-dir>
  local s rc=0
  for s in ledger skips not_deployed draft record failures runner replay; do
    out=$(scenario_"$s" "$1" 2>&1) || { printf 'scenario %s: %s\n' "$s" "$out"; rc=1; }
  done
  return $rc
}

# ---- real adapter -----------------------------------------------------------

for s in ledger skips not_deployed draft record failures runner replay; do
  out=$(scenario_"$s" "$ROOT/bin" 2>&1) || fail "scenario $s failed on the real adapter: $out"
  pass "deploy-verify $s"
done

# ---- mutation proofs: remove one guard, the scenario guarding it goes red ------

MBIN="$TMP_ROOT/mbin"
mkdir -p "$MBIN"
cp "$ROOT"/bin/*.sh "$MBIN/"
ADAPTER="$MBIN/fm-procevent-deploy-verify.sh"
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

mutate 'replay dedupe is task scoped' replay \
  's/ and \.task == \$t and \(\.prs/ and (.prs/'
mutate 'replay ancestry' replay \
  's/jq -e .\.status == "ahead" or \.status == "identical". <<<"\$comparison" >\/dev\/null \|\| continue/:/'
mutate 'replay dry run' replay \
  's/if \[ "\$dry" -eq 1 \]; then/if false; then/'
mutate 'replay visible lines' replay \
  's/\[ -n "\$lines" \] \|\| continue/:/'
mutate 'replay grouping' replay \
  's/cut -d.\|. -f1 "\$w\/rows" \| sort -u/cut -d"|" -f1 "\$w\/rows"/'
mutate 'replay idempotency' replay \
  's/ledger_has_key "replay:\$task:\$sha" && continue/:/; s/ledger_test .\.type == "ask" and \.round == "deploy" and \.task == \$t and \(\.prs \| index\(\$p\)\). --arg p "\$pr" --arg t "\$task" && continue/:/'
mutate 'non-A acceptance ids' ledger \
  's/\[A-Z\]\+/A/g'
mutate 'non-A draft ids' draft \
  's/\[A-Z\]\+/A/g'
mutate 'visible skips need attention' skips \
  's/attention_skip "\$result" && return 1/:/g'
mutate 'ledger: a PR already asked is skipped' ledger \
  's/ledger_pr_final "\$url" "\$task" && continue//'
mutate 'one ask per task' ledger \
  's/tasks=\$\(cut -d.\|. -f1 "\$w\/rows.psv" \| sort -u\)/tasks=\$(cut -d"|" -f1 "\$w\/rows.psv")/'
mutate 'internal tasks are skipped' skips \
  's/if \[ "\$surface" = internal \]; then\n      while/if false; then\n      while/'
mutate 'issues with no user-visible line are skipped' skips \
  's/if \[ -z "\$lines" \]; then\n      while/if false; then\n      while/'
mutate 'only a green deploy job asks' not_deployed \
  's/if \[ "\$conclusion" = success \]; then/if true; then/'
mutate 'a run in progress holds the cursor' not_deployed \
  's/\[ "\$status" = completed \] \|\| break/:/'
mutate 'draft asks once per head' draft \
  's/ledger_has_key "\$key" && continue//'
mutate 'draft asks name only the draft lines' draft \
  's/issue_lines draft/issue_lines visible/'
mutate 'a repeated failure stays quiet' failures \
  's/\[ "\$previous" = "\$reason" \] \|\| return 1//'
mutate 'a failed delivery keeps the cursor' failures \
  's/if \[ "\$failed" -eq 1 \]; then/if false; then/'
mutate 'an unread GitHub is left for the wake' failures \
  's/jq -e .\.error == null. "\$result" >\/dev\/null 2>&1 \|\| return 1/:/'
pass 'every guarded behavior has a red mutation proof'
