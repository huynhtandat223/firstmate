#!/usr/bin/env bash
# Built-in process-event adapter that sends the Tester its verify asks.
#
# Usage:
#   fm-procevent-deploy-verify.sh arm
#   fm-procevent-deploy-verify.sh wait
#   fm-procevent-deploy-verify.sh autohandle <source-id> <sequence> <result-file>
#   fm-procevent-deploy-verify.sh classify <result-file>
#   fm-procevent-deploy-verify.sh silent <result-file>
#   fm-procevent-deploy-verify.sh terminal <result-file>
#   fm-procevent-deploy-verify.sh self-announcing
#   fm-procevent-deploy-verify.sh relisten
#
# arm          Register source `deploy-verify` with the runner (bin/fm-procevent.sh).
#              Run it once per home; reconcile keeps the poll alive.
# wait         The blocking child. It polls the project's main CI runs at most once
#              per FM_DEPLOY_VERIFY_POLL_SECONDS (default 60), in run order, past the
#              cursor in data/deploy-verify/state.json. A run whose "Deploy Development
#              host (5001)" job is green deploys its commits since the last green
#              deploy. The merged PRs of those commits map to tasks through state/*.meta
#              `pr=` and the backlog line's PR URL, and to an issue through the PR's
#              closing reference or the backlog line's `<repo> #n`. Open task PRs are
#              also checked for a new head whose issue has `(draft)` acceptance lines.
#              It prints one fm-deploy-verify-result.v1 JSON when there is an ask, a
#              skip to record, a first GitHub failure, or a recovery to clear.
#              A skipped, cancelled or failed deploy asks nothing; the next green
#              deploy carries its commits.
#              The first poll only sets the cursor to the newest finished run; it never
#              asks about history.
# autohandle   Send each ask as an fm-assistance-mentions.v1 record through
#              `fm-assistance.sh source-event <assistance>`, record it in
#              data/deploy-verify/ledger.jsonl, then advance the cursor and
#              acknowledge the result. One ask goes out per task per deploy, and a
#              PR already asked about is never asked again. A refused delivery or an
#              unreadable GitHub leaves the result unacknowledged, so the runner
#              publishes one wake; the next poll retries the same asks, and the same
#              reason stays quiet until a poll succeeds.
# silent       Exit 0 when the result needs no firstmate action: no error and every
#              ask and skip is already in the ledger.
# self-announcing, relisten
#              Exit 0: a delivered ask is announced by the Tester inbox itself, and
#              the runner keeps polling after a fully handled result.
#
# Ledger lines (data/deploy-verify/ledger.jsonl):
#   {type:"ask", round:"deploy"|"draft", key, task, issue, prs, sha, run, lines, record}
#   {type:"skip", pr, task, reason:"no-task"|"internal"|"no-issue"|"no-user-visible-line"}
#   {type:"draft-skip", key, reason}
# Environment: FM_DEPLOY_VERIFY_REPO (default huynhtandat223/cfw-modules), _JOB,
# _WORKFLOW, _ASSISTANCE (default tester), _GH (the gh command), _POLL_SECONDS,
# _ONCE=1 (poll once and exit 1 when nothing is due).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="$FM_HOME/data/deploy-verify"
LEDGER="$DATA/ledger.jsonl"
CURSOR="$DATA/state.json"
LAST_ERROR="$DATA/last-error"
LAST_POLL="$DATA/last-poll"

REPO="${FM_DEPLOY_VERIFY_REPO:-huynhtandat223/cfw-modules}"
JOB="${FM_DEPLOY_VERIFY_JOB:-Deploy Development host (5001)}"
WORKFLOW="${FM_DEPLOY_VERIFY_WORKFLOW:-CI}"
ASSISTANCE="${FM_DEPLOY_VERIFY_ASSISTANCE:-tester}"
GH="${FM_DEPLOY_VERIFY_GH:-gh}"
POLL_SECONDS="${FM_DEPLOY_VERIFY_POLL_SECONDS:-60}"
SOURCE_ID=deploy-verify

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-procevent-ask-lib.sh
. "$SCRIPT_DIR/fm-procevent-ask-lib.sh"

die() { printf 'error: %s\n' "$*" >&2; exit 2; }

READ_ERROR_FILE="$DATA/.read-error"
READ_ERROR=

# ---- ledger and cursor (ledger_test, ledger_append: bin/fm-procevent-ask-lib.sh) ----

# shellcheck disable=SC2016 # jq variables, not shell
ledger_has_key() { ledger_test '(.type == "ask" or .type == "draft-skip") and .key == $k' --arg k "$1"; }
# shellcheck disable=SC2016 # jq variables, not shell
ledger_pr_final() {  # <pr-url> <task>: asked in a deploy round or skipped already
  ledger_test '.task == $t and ((.type == "ask" and .round == "deploy" and (.prs | index($p))) or (.type == "skip" and .pr == $p))' \
    --arg p "$1" --arg t "$2"
}

state_put() {  # <cursor-run> <last-green-sha>
  jq -cn --argjson r "$1" --arg s "$2" '{cursor_run: $r, last_green_sha: $s}' > "$CURSOR.tmp" \
    && mv -f "$CURSOR.tmp" "$CURSOR"
}

# ---- task and issue mapping ------------------------------------------------

# One |-separated row per PR and task: url, task, surface, issue hint, live (1 for a task
# that still has state/<task>.meta). Live rows come from the endpoint records,
# finished tasks from the PR URL on their backlog line.
build_map() {  # <out-file>
  local f pr task surface backlog
  {
    for f in "$STATE"/*.meta; do
      [ -f "$f" ] && [ ! -L "$f" ] || continue
      grep -qx 'kind=ship' "$f" || continue
      pr=$(sed -n 's/^pr=//p' "$f" | head -1)
      case "$pr" in "https://github.com/$REPO/pull/"[0-9]*) ;; *) continue ;; esac
      task=$(basename "$f" .meta)
      surface=$(sed -n 's/^surface=//p' "$f" | head -1)
      printf '%s|%s|%s||1\n' "$pr" "$task" "$surface"
    done
    backlog="$FM_HOME/data/backlog.md"
    [ ! -f "$backlog" ] || awk -v repo="$REPO" -v short="${REPO##*/}" '
      /^- \[.\] / && /\(kind: ship\)/ {
        line = $0; sub(/^- \[.\] /, "", line)
        task = line; sub(/ .*/, "", task)
        hint = ""
        if (match($0, short " #[0-9]+")) hint = substr($0, RSTART + length(short) + 2, RLENGTH - length(short) - 2)
        rest = $0
        while (match(rest, "https://github.com/" repo "/pull/[0-9]+")) {
          printf "%s|%s||%s|0\n", substr(rest, RSTART, RLENGTH), task, hint
          rest = substr(rest, RSTART + RLENGTH)
        }
      }' "$backlog"
  } | awk -F'|' '
    { k = $1 FS $2; seen[k] = 1; if ($3 != "") s[k] = $3; if ($4 != "") h[k] = $4; if ($5 == 1) l[k] = 1 }
    END { for (k in seen) { split(k, a, FS); printf "%s|%s|%s|%s|%d\n", a[1], a[2], s[k], h[k], l[k] } }' \
    | sort > "$1"
}

resolve_issue() {  # <pr-body> <backlog-hint>: the issue number, or nothing
  local n
  n=$(printf '%s\n' "$1" | grep -oiE "(clos(e|es|ed)|fix(es|ed)?|resolv(e|es|ed)|part of|refs?)[: ]+(${REPO}#|https://github.com/${REPO}/issues/|#)[0-9]+" \
    | grep -oE '[0-9]+$' | head -1)
  printf '%s\n' "${n:-$2}"
}

# The acceptance lines of an issue body: ids of the user-visible lines, or of the
# lines whose env/page names a (draft) row.
issue_lines() {  # <visible|draft> <issue-body>
  printf '%s\n' "$2" | awk -v mode="$1" '
    function flush() { if (id != "" && ((mode == "visible" && vis) || (mode == "draft" && draft))) print id; id = ""; vis = 0; draft = 0 }
    /^## / { flush(); acc = ($0 ~ /^## Acceptance/); next }
    acc && /^- \[.\] A[0-9]+/ { flush(); match($0, /A[0-9]+/); id = substr($0, RSTART, RLENGTH); next }
    acc && /^[ \t]+- surface:/ && /user-visible/ { vis = 1 }
    acc && /^[ \t]+- env\/page:/ && /\(draft\)/ { draft = 1 }
    END { flush() }'
}

# ---- planning --------------------------------------------------------------

ASKS='[]'
SKIPS='[]'
add_ask() { ASKS=$(jq -c --argjson a "$1" '. + [$a]' <<<"$ASKS"); }
add_skip() {  # <pr> <task> <reason> <sha>
  SKIPS=$(jq -c --arg pr "$1" --arg t "$2" --arg r "$3" --arg s "$4" '. + [{pr: $pr, task: $t, reason: $r, sha: $s}]' <<<"$SKIPS")
}

issue_ref() { printf '%s#%s\n' "${REPO##*/}" "$1"; }

# Plan the deploy of <sha>: every merged PR in the commits since <base> maps to
# its tasks. A PR already asked about or skipped for a task is left alone.
plan_deploy() {  # <base-sha> <sha> <run-url> <completed-at> <workdir>
  local base=$1 sha=$2 run=$3 completed=$4 w=$5 commits c pulls
  local url body task surface hint issue n rows tasks arrival issue_json lines
  : > "$w/prs.jsonl"
  if [ -n "$base" ] && [ "$base" != "$sha" ]; then
    pulls=$(gh_read "repos/$REPO/compare/$base...$sha") || return 1
    commits=$(jq -r '.commits[].sha' <<<"$pulls")
  elif [ -z "$base" ]; then
    commits=$sha
  else
    commits=
  fi
  for c in $commits; do
    pulls=$(gh_read "repos/$REPO/commits/$c/pulls") || return 1
    jq -c '.[] | select(.merged_at != null and .base.ref == "main") | {url: .html_url, body: (.body // "")}' <<<"$pulls" >> "$w/prs.jsonl"
  done
  : > "$w/rows.psv"
  while IFS= read -r pr_json; do
    url=$(jq -r .url <<<"$pr_json")
    body=$(jq -r .body <<<"$pr_json")
    if ! awk -F'|' -v p="$url" '$1 == p { f = 1 } END { exit !f }' "$w/map.psv"; then
      ledger_pr_final "$url" "" || add_skip "$url" "" no-task "$sha"
      continue
    fi
    while IFS='|' read -r _ task surface hint _; do
      ledger_pr_final "$url" "$task" && continue
      issue=$(resolve_issue "$body" "$hint")
      printf '%s|%s|%s|%s\n' "$task" "$surface" "$url" "$issue" >> "$w/rows.psv"
    done < <(awk -F'|' -v p="$url" '$1 == p' "$w/map.psv")
  done < <(jq -sc 'unique_by(.url) | .[]' "$w/prs.jsonl")
  tasks=$(cut -d'|' -f1 "$w/rows.psv" | sort -u)
  for task in $tasks; do
    rows=$(awk -F'|' -v t="$task" '$1 == t' "$w/rows.psv")
    surface=$(printf '%s\n' "$rows" | head -1 | cut -d'|' -f2)
    if [ "$surface" = internal ]; then
      while IFS='|' read -r _ _ url _; do add_skip "$url" "$task" internal "$sha"; done <<<"$rows"
      continue
    fi
    n=$(printf '%s\n' "$rows" | cut -d'|' -f4 | grep -m1 . || true)
    if [ -z "$n" ]; then
      while IFS='|' read -r _ _ url _; do add_skip "$url" "$task" no-issue "$sha"; done <<<"$rows"
      continue
    fi
    issue_json=$(gh_read "repos/$REPO/issues/$n") || return 1
    lines=$(issue_lines visible "$(jq -r '.body // ""' <<<"$issue_json")")
    if [ -z "$lines" ]; then
      while IFS='|' read -r _ _ url _; do add_skip "$url" "$task" no-user-visible-line "$sha"; done <<<"$rows"
      continue
    fi
    arrival=$(jq -n --arg d "$completed" '$d | fromdateiso8601')
    add_ask "$(jq -cn --arg key "deploy:$task:$sha" --arg task "$task" --arg issue "$(issue_ref "$n")" \
      --arg issue_url "https://github.com/$REPO/issues/$n" --arg sha "$sha" --arg run "$run" --argjson arrival "$arrival" \
      --argjson prs "$(printf '%s\n' "$rows" | cut -d'|' -f3 | jq -R . | jq -sc .)" \
      --argjson lines "$(printf '%s\n' "$lines" | jq -R . | jq -sc .)" \
      '{round: "deploy", key: $key, task: $task, issue: $issue, issue_url: $issue_url, prs: $prs, sha: $sha, run: $run, lines: $lines, arrival: $arrival}')"
  done
}

# Ask for the draft lines of each open task PR whose head is new.
plan_drafts() {  # <workdir>
  local w=$1 url task surface hint n pr head key issue body issue_json lines commit pushed arrival
  while IFS='|' read -r url task surface hint live; do
    [ "$live" = 1 ] || continue
    n=${url##*/}
    pr=$(gh_read "repos/$REPO/pulls/$n") || return 1
    [ "$(jq -r .state <<<"$pr")" = open ] || continue
    head=$(jq -r .head.sha <<<"$pr")
    key="draft:$task:$n:$head"
    ledger_has_key "$key" && continue
    if [ "$surface" = internal ]; then
      ledger_append "$(jq -cn --arg k "$key" '{type: "draft-skip", key: $k, reason: "internal"}')"
      continue
    fi
    body=$(jq -r '.body // ""' <<<"$pr")
    issue=$(resolve_issue "$body" "$hint")
    if [ -z "$issue" ]; then
      ledger_append "$(jq -cn --arg k "$key" '{type: "draft-skip", key: $k, reason: "no-issue"}')"
      continue
    fi
    issue_json=$(gh_read "repos/$REPO/issues/$issue") || return 1
    lines=$(issue_lines draft "$(jq -r '.body // ""' <<<"$issue_json")")
    if [ -z "$lines" ]; then
      ledger_append "$(jq -cn --arg k "$key" '{type: "draft-skip", key: $k, reason: "no-draft-lines"}')"
      continue
    fi
    commit=$(gh_read "repos/$REPO/commits/$head") || return 1
    pushed=$(jq -r '.commit.committer.date' <<<"$commit")
    arrival=$(jq -n --arg d "$pushed" '$d | fromdateiso8601')
    add_ask "$(jq -cn --arg key "$key" --arg task "$task" --arg issue "$(issue_ref "$issue")" \
      --arg issue_url "https://github.com/$REPO/issues/$issue" --arg head "$head" --arg pushed "$pushed" \
      --arg pr "$url" --argjson arrival "$arrival" \
      --argjson lines "$(printf '%s\n' "$lines" | jq -R . | jq -sc .)" \
      '{round: "draft", key: $key, task: $task, issue: $issue, issue_url: $issue_url, prs: [$pr], sha: $head, head: $head, pushed: $pushed, run: null, lines: $lines, arrival: $arrival}')"
  done < "$w/map.psv"
}

CURSOR_RUN=
CURSOR_SHA=
# One poll. Exit 0: a result is ready in ASKS, SKIPS and the cursor variables.
# Exit 1: nothing is due. Exit 2: GitHub could not be read (READ_ERROR).
poll_once() {
  local w runs baseline run_id sha status run_url completed jobs conclusion cursor_run base
  ASKS='[]'
  SKIPS='[]'
  CURSOR_RUN=
  CURSOR_SHA=
  w=$(mktemp -d "${TMPDIR:-/tmp}/fm-deploy-verify.XXXXXX") || return 2
  build_map "$w/map.psv"
  runs=$(gh_read "repos/$REPO/actions/runs?branch=main&event=push&per_page=30") || { rm -rf "$w"; return 2; }
  runs=$(jq -c --arg wf "$WORKFLOW" '[.workflow_runs[] | select(.name == $wf)] | sort_by(.id)' <<<"$runs")
  if [ ! -s "$CURSOR" ]; then
    # First poll: start after the newest finished run, never backfill history.
    baseline=$(jq -c '[.[] | select(.status == "completed")] | last // empty' <<<"$runs")
    [ -z "$baseline" ] || state_put "$(jq -r .id <<<"$baseline")" "$(jq -r .head_sha <<<"$baseline")"
    rm -rf "$w"
    return 1
  fi
  cursor_run=$(jq -r .cursor_run "$CURSOR")
  base=$(jq -r '.last_green_sha // ""' "$CURSOR")
  CURSOR_RUN=$cursor_run
  CURSOR_SHA=$base
  while IFS= read -r run; do
    status=$(jq -r .status <<<"$run")
    [ "$status" = completed ] || break
    run_id=$(jq -r .id <<<"$run")
    sha=$(jq -r .head_sha <<<"$run")
    run_url=$(jq -r .html_url <<<"$run")
    jobs=$(gh_read "repos/$REPO/actions/runs/$run_id/jobs?per_page=100") || { rm -rf "$w"; return 2; }
    conclusion=$(jq -r --arg j "$JOB" '[.jobs[] | select(.name == $j)] | first | .conclusion // ""' <<<"$jobs")
    if [ "$conclusion" = success ]; then
      completed=$(jq -r --arg j "$JOB" '[.jobs[] | select(.name == $j)] | first | .completed_at' <<<"$jobs")
      plan_deploy "$base" "$sha" "$run_url" "$completed" "$w" || { rm -rf "$w"; return 2; }
      CURSOR_RUN=$run_id
      CURSOR_SHA=$sha
      if [ "$ASKS" != '[]' ] || [ "$SKIPS" != '[]' ]; then
        break
      fi
      base=$sha
    else
      CURSOR_RUN=$run_id
    fi
  done < <(jq -c --argjson c "$cursor_run" '.[] | select(.id > $c)' <<<"$runs")
  if [ "$ASKS" = '[]' ] && [ "$SKIPS" = '[]' ]; then
    [ "$CURSOR_RUN" = "$cursor_run" ] && [ "$CURSOR_SHA" = "$(jq -r '.last_green_sha // ""' "$CURSOR")" ] \
      || state_put "$CURSOR_RUN" "$CURSOR_SHA"
  fi
  plan_drafts "$w" || { rm -rf "$w"; return 2; }
  rm -rf "$w"
  [ "$ASKS" != '[]' ] || [ "$SKIPS" != '[]' ]
}

# ---- wait ------------------------------------------------------------------

emit_result() {  # <error-or-empty> <recovered 0|1>
  jq -cn --arg error "$1" --argjson recovered "$2" --argjson asks "$ASKS" --argjson skips "$SKIPS" \
    --arg run "$CURSOR_RUN" --arg sha "$CURSOR_SHA" '
    {schema: "fm-deploy-verify-result.v1", asks: $asks, skips: $skips, recovered: ($recovered == 1),
     error: (if $error == "" then null else $error end),
     cursor: (if $run == "" or ($asks | length) + ($skips | length) == 0 then null else {cursor_run: ($run | tonumber), last_green_sha: $sha} end)}'
}

cmd_wait() {
  local rc previous
  command -v jq >/dev/null 2>&1 || die 'jq is required'
  mkdir -p "$DATA"
  while :; do
    throttle
    date +%s > "$LAST_POLL"
    poll_once
    rc=$?
    previous=
    [ ! -f "$LAST_ERROR" ] || previous=$(<"$LAST_ERROR")
    case "$rc" in
      0)
        emit_result '' 0
        return 0
        ;;
      2)
        # A failure is announced once; the same reason stays quiet while the
        # polls go on, and a poll that succeeds clears it below.
        READ_ERROR=$(<"$READ_ERROR_FILE")
        if [ "$previous" != "$READ_ERROR" ]; then
          printf '%s\n' "$READ_ERROR" > "$LAST_ERROR"
          ASKS='[]'
          SKIPS='[]'
          emit_result "$READ_ERROR" 0
          return 0
        fi
        ;;
      *)
        if [ -n "$previous" ]; then
          ASKS='[]'
          SKIPS='[]'
          emit_result '' 1
          return 0
        fi
        ;;
    esac
    [ "${FM_DEPLOY_VERIFY_ONCE:-0}" != 1 ] || return 1
  done
}

# ---- delivery --------------------------------------------------------------

deliver_ask() {  # <ask-json>
  local ask=$1 content record
  content=$(jq -c 'del(.arrival, .key) + {schema: "fm-tester-verify.v1"} | {schema, round, task, issue, issue_url, prs, sha, run, head, pushed, lines}
    | with_entries(select(.value != null))' <<<"$ask")
  record=$(jq -cn --arg id "$(jq -r .key <<<"$ask")" --argjson at "$(jq -r .arrival <<<"$ask")" --arg c "$content" \
    '{schema: "fm-assistance-mentions.v1", messages: [{id: $id, arrival: $at, content: $c}]}')
  deliver_record Tester "$ASSISTANCE" "$record" || return 1
  ledger_append "$(jq -c --arg r "$DELIVER_BASE" --argjson at "$(date +%s)" 'del(.arrival) + {type: "ask", record: $r, at: $at}' <<<"$ask")"
}

cmd_autohandle() {  # <source-id> <sequence> <result-file>
  local sid=${1:-} seq=${2:-} result=${3:-} ask failed=0 reason='' previous='' pr task
  [ "$sid" = "$SOURCE_ID" ] && [ -f "$result" ] || return 1
  case "$seq" in ''|*[!0-9]*) return 1 ;; esac
  jq -e '.schema == "fm-deploy-verify-result.v1"' "$result" >/dev/null 2>&1 || return 1
  # A GitHub failure is left unacknowledged on purpose: that is the one wake.
  jq -e '.error == null' "$result" >/dev/null 2>&1 || return 1
  mkdir -p "$DATA"
  while IFS='|' read -r pr task reason; do
    [ -n "$pr" ] || continue
    ledger_pr_final "$pr" "$task" && continue
    ledger_append "$(jq -cn --arg pr "$pr" --arg t "$task" --arg r "$reason" --argjson at "$(date +%s)" \
      '{type: "skip", pr: $pr, task: $t, reason: $r, at: $at}')"
  done < <(jq -r '.skips[] | [.pr, .task, .reason] | join("|")' "$result")
  reason=
  while IFS= read -r ask; do
    [ -n "$ask" ] || continue
    ledger_has_key "$(jq -r .key <<<"$ask")" && continue
    if ! deliver_ask "$ask"; then
      failed=1
      [ -n "$reason" ] || reason=$DELIVER_ERROR
    fi
  done < <(jq -c '.asks[]' "$result")
  if [ "$failed" -eq 1 ]; then
    [ ! -f "$LAST_ERROR" ] || previous=$(<"$LAST_ERROR")
    printf '%s\n' "$reason" > "$LAST_ERROR"
    # The same failure was announced already: stay quiet and retry next poll.
    [ "$previous" = "$reason" ] || return 1
    "$SCRIPT_DIR/fm-procevent.sh" handled "$SOURCE_ID" "$seq" >/dev/null 2>&1 || true
    return 0
  fi
  if jq -e '.cursor != null' "$result" >/dev/null 2>&1; then
    state_put "$(jq -r .cursor.cursor_run "$result")" "$(jq -r .cursor.last_green_sha "$result")"
  fi
  rm -f "$LAST_ERROR"
  mark_handled "$seq"
}

cmd_silent() {  # <result-file>
  local result=${1:-} ask pr task
  jq -e '.schema == "fm-deploy-verify-result.v1" and .error == null' "$result" >/dev/null 2>&1 || return 1
  while IFS= read -r ask; do
    ledger_has_key "$(jq -r .key <<<"$ask")" || return 1
  done < <(jq -c '.asks[]' "$result")
  while IFS='|' read -r pr task; do
    ledger_pr_final "$pr" "$task" || return 1
  done < <(jq -r '.skips[] | [.pr, .task] | join("|")' "$result")
}

cmd_classify() {  # <result-file>
  local result=${1:-}
  if jq -e '.error != null' "$result" >/dev/null 2>&1; then
    printf 'error\n'
  elif jq -e '(.asks | length) > 0' "$result" >/dev/null 2>&1; then
    printf 'asks\n'
  else
    printf 'record\n'
  fi
}

cmd_arm() {
  "$SCRIPT_DIR/fm-procevent.sh" register deploy-verify "$SOURCE_ID" -- "$SCRIPT_DIR/fm-procevent-deploy-verify.sh" wait
}

case "${1:-}" in
  arm) shift; cmd_arm "$@" ;;
  wait) shift; cmd_wait "$@" ;;
  autohandle) shift; [ "$#" -eq 3 ] || die 'usage: autohandle <source-id> <sequence> <result-file>'; cmd_autohandle "$@" ;;
  classify) shift; cmd_classify "$@" ;;
  silent) shift; cmd_silent "$@" ;;
  terminal) exit 1 ;;
  self-announcing|relisten) exit 0 ;;
  *) echo 'error: expected arm, wait, autohandle, classify, silent, terminal, self-announcing or relisten' >&2; exit 2 ;;
esac
