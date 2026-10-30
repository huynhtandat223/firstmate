#!/usr/bin/env bash
# Built-in process-event adapter that starts a review round for each new head of an open pull
# request, asks the Reviewer assistance and the ChatGPT reader about that exact head, labels
# every finding by whether the PR's diff caused it, and hands the round to the worker that owns
# the head: the in-scope findings go straight into the worker's inbox and firstmate is not woken
# for that round. A round with no in-scope finding, or with no live worker, wakes firstmate as
# before. Firstmate reads every round, delivered or not, at the worker's done (see "What firstmate
# keeps" below) and still verifies each finding and gives the verdict.
#
# Usage:
#   fm-procevent-pr-review.sh arm
#   fm-procevent-pr-review.sh wait
#   fm-procevent-pr-review.sh summary [--since <iso-time>]
#   fm-procevent-pr-review.sh autohandle <source-id> <sequence> <result-file>
#   fm-procevent-pr-review.sh classify <result-file>
#   fm-procevent-pr-review.sh silent <result-file>
#   fm-procevent-pr-review.sh terminal <result-file>
#   fm-procevent-pr-review.sh self-announcing
#   fm-procevent-pr-review.sh relisten
#
# arm          Register source `pr-review` with the runner (bin/fm-procevent.sh).
#              Run it once per home; reconcile keeps the poll alive.
# wait         The blocking child. Every poll_seconds it reads config/pr-review.json and, when
#              the file says enabled, the open PRs of each configured repository. A missing
#              file or enabled:false means no GitHub read, no ask and no ledger line.
#              A round is a new head of an open PR of a live task, once the head has stayed the
#              head for settle_seconds. The first poll of a repository records each open PR's head
#              as a baseline, so history is never backfilled. A PR no live task owns is recorded
#              once as skipped (no-task).
# Worker       The live task that owns a PR head is, in this order, the task whose worktree is on
#              the PR's head branch (`git -C <worktree> branch --show-current` for each
#              state/*.meta with a worktree), the task whose meta records `pr=` as that PR, else
#              the task the fm/<task> branch names. A task is live when state/<task>.meta exists.
#              No match: nothing is delivered and firstmate is woken as before.
#              A round asks the Reviewer (one fm-assistance-mentions.v1 record through
#              `fm-assistance.sh source-event`) and the reader (config reader.command, one at a
#              time) about that head. It returns one fm-pr-review-result.v1 JSON when both have
#              answered, or when reviewer_timeout_seconds ends for the Reviewer.
#              After max_rounds rounds of one PR a new head asks no one and returns one result
#              of kind "cap". A Reviewer report that comes after its timeout returns one more
#              result of kind "late". An unreadable GitHub returns one result of kind "error";
#              the same reason stays quiet until a poll succeeds, then a "recovery" result.
#              Rounds already open still finish and time out while GitHub cannot be read.
#              A reader run that passes reader.timeout_seconds (default 1500) is stopped and its
#              status is "failed: timeout".
# The Reviewer's report is data/reviews/<record basename without .json>.md in its home (the
#              name with .json kept is read too), written before it acknowledges the record
#              with `fm-assistance.sh acknowledge-source`. The report counts as given once it
#              is non-empty and the record is acknowledged. It does not `propose` for these asks.
# Findings are the lines `FINDING <blocking|note> <path>:<line> <scenario> | fix: <smallest fix>`
#              of either answer. Each gets one label, and none is dropped:
#                in-scope                     the line is one the diff adds or changes on the head
#                                             side (the head-side line where a deletion sits counts)
#                out-of-scope (pre-existing)  the path or line is outside merge-base..head
#                unlocated                    the finding names no <path>:<line>
#                unchecked                    GitHub gives no patch for that file
#              Lines after a PRE-EXISTING heading are kept apart as pre_existing text.
# summary      Print, per PR and reviewer, the rounds, findings by label, time from push to each
#              answer, timeouts and failures, from the ledger. --since keeps rounds from that time.
# What firstmate keeps
#              A delivered round appends its ledger line with delivered:true and the lines the worker
#              did not get under retained (out-of-scope, pre-existing, unlocated, unchecked), so
#              firstmate reads every round at the worker's done with
#                jq -r 'select(.type=="round" and .task=="<task>") | .delivered, .retained[]?' data/pr-review/ledger.jsonl
#              The reader answer and the Reviewer report stay in the ledger's reader.answer and
#              reviewer.report paths.
# CI result to the worker
#              The same poll reads the checks of an open PR's current head (repos/<repo>/commits/
#              <head>/check-runs). Once every check has finished on that head and the head was not
#              read before, it writes one `ci` event on the worker's task record, which clears a
#              declared `wait --next-actor ci --clears-on ci`. A head with a failed check also sends
#              the worker one message naming each failed check, its URL, and the `gate FAILED` lines
#              of that check's log with the line after each. A green head, and a head replaced before
#              its checks finished, send the worker nothing.
#              state.json holds the head each PR's checks were last read on (.ci).
#              Legacy commit-status contexts are not read; this source handles check runs only.
# autohandle   Apply a captured result after the runner has captured it: write its ledger line and
#              close its round. A round or late result whose in-scope findings reached a live worker's
#              inbox acknowledges itself, so that round wakes nobody. A round, late or cap result that
#              delivered nothing, and every error result, stays unacknowledged: that is the wake.
#              A recovery result clears the error and acknowledges itself and the older error results,
#              never a round. Firstmate acknowledges the rest with `fm-procevent.sh handled pr-review
#              <sequence>` after it has verified the findings.
# silent       Exit 0 for a recovery result only.
# self-announcing, relisten
#              Exit 0: autohandle runs before the wake is published, and the runner keeps polling.
#
# Ledger lines (data/pr-review/ledger.jsonl):
#   {type:"baseline", repo, pr, head, at}
#   {type:"skip", repo, pr, reason:"no-task", at}
#   {type:"round", repo, pr, task, head, round, at, committed, delivered, retained,
#      reviewer:{record, status, report, at, labels}, reader:{status, answer, at, labels}}
#   {type:"late", repo, pr, head, round, at, report, labels}
#   {type:"cap", repo, pr, head, at}
# Other files under data/pr-review/: state.json (first-poll marks, the settle clock of each head,
# and the head each PR's checks were last read on), open/ (the rounds still waiting), last-error,
# last-poll.
# Config: config/pr-review.json (docs/configuration.md "PR review rounds").
# Environment: FM_PR_REVIEW_GH (the gh command), _ONCE=1 (poll once and exit 1 when nothing is
# due), _NOW (the clock, epoch seconds, for tests), _IDLE_SECONDS (the wait while the source is off),
# FM_PR_REVIEW_TASK (the task record writer, default bin/fm-task.sh beside this script),
# FM_PR_REVIEW_SEND (the steer command, default bin/fm-send.sh beside this script).
# shellcheck disable=SC2016 # jq filters and awk programs use $variables that must not expand in the shell
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="$FM_HOME/data/pr-review"
LEDGER="$DATA/ledger.jsonl"
CURSOR="$DATA/state.json"
OPEN="$DATA/open"
LAST_ERROR="$DATA/last-error"
LAST_POLL="$DATA/last-poll"
READ_ERROR_FILE="$DATA/.read-error"
CONFIG="$FM_HOME/config/pr-review.json"

GH="${FM_PR_REVIEW_GH:-gh}"
TASK_WRITER="${FM_PR_REVIEW_TASK:-$SCRIPT_DIR/fm-task.sh}"
SEND="${FM_PR_REVIEW_SEND:-$SCRIPT_DIR/fm-send.sh}"
POLL_SECONDS=60
SOURCE_ID=pr-review

SCOPE_RULE="A finding is in scope only when it names the line in this PR's diff (merge-base..head) that causes it. A problem whose cause is not in that range is pre-existing: list it under PRE-EXISTING, never as a finding."
FINDING_FORMAT='FINDING <blocking|note> <path>:<line> <scenario> | fix: <smallest fix>'
LABEL_IN='in-scope'
LABEL_OUT='out-of-scope (pre-existing)'

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"
# shellcheck source=bin/fm-procevent-ask-lib.sh
. "$SCRIPT_DIR/fm-procevent-ask-lib.sh"

die() { printf 'error: %s\n' "$*" >&2; exit 2; }
now() { printf '%s\n' "${FM_PR_REVIEW_NOW:-$(date +%s)}"; }

# ---- config ----------------------------------------------------------------

REPOS=
MAX_ROUNDS=3
SETTLE_SECONDS=120
REVIEWER_TIMEOUT=1800
ASSISTANCE=reviewer
READER_CMD=
READER_URL=
READER_TIMEOUT=1500

cfg_num() {  # <field> <default>
  local v
  v=$(jq -r --arg k "$1" '.[$k] // empty' "$CONFIG" 2>/dev/null)
  case "$v" in ''|*[!0-9]*) printf '%s\n' "$2" ;; *) printf '%s\n' "$v" ;; esac
}

# Exit 1 when the source is off: no file, a link, unreadable JSON, or enabled is not true.
load_config() {
  [ -f "$CONFIG" ] && [ ! -L "$CONFIG" ] || return 1
  jq -e '.enabled == true' "$CONFIG" >/dev/null 2>&1 || return 1
  REPOS=$(jq -r '(.repos // [])[] | strings | select(test("^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$"))' "$CONFIG" 2>/dev/null)
  [ -n "$REPOS" ] || return 1
  MAX_ROUNDS=$(cfg_num max_rounds 3)
  POLL_SECONDS=$(cfg_num poll_seconds 60)
  SETTLE_SECONDS=$(cfg_num settle_seconds 120)
  REVIEWER_TIMEOUT=$(cfg_num reviewer_timeout_seconds 1800)
  ASSISTANCE=$(jq -r '.reviewer.assistance // "reviewer"' "$CONFIG")
  READER_CMD=$(jq -r '.reader.command // ""' "$CONFIG")
  READER_URL=$(jq -r '.reader.project_url // ""' "$CONFIG")
  READER_TIMEOUT=$(jq -r '.reader.timeout_seconds // empty' "$CONFIG" 2>/dev/null)
  case "$READER_TIMEOUT" in ''|*[!0-9]*|0) READER_TIMEOUT=1500 ;; esac
}

# ---- state and ledger queries ----------------------------------------------

state_json() { if [ -s "$CURSOR" ]; then cat "$CURSOR"; else echo '{}'; fi; }
state_edit() {  # <jq-filter> [jq args...]
  local filter=$1
  shift
  state_json | jq -c "$@" "$filter" > "$CURSOR.tmp" && mv -f "$CURSOR.tmp" "$CURSOR"
}

key_of() { printf '%s-%s-%s\n' "${1//\//_}" "$2" "${3:0:12}"; }  # <repo> <pr> <head>

ledger_head_known() {  # <repo> <pr> <head>: a baseline, round or cap line already names this head
  ledger_test '(.type == "baseline" or .type == "round" or .type == "cap") and .repo == $r and .pr == $n and .head == $h' \
    --arg r "$1" --argjson n "$2" --arg h "$3"
}
ledger_pr_has() {  # <type> <repo> <pr>
  ledger_test '.type == $t and .repo == $r and .pr == $n' --arg t "$1" --arg r "$2" --argjson n "$3"
}
round_count() {  # <repo> <pr>: finished rounds in the ledger plus rounds still open
  local done_n=0 open_n=0 f
  if [ -s "$LEDGER" ]; then
        done_n=$(jq -sc --arg r "$1" --argjson n "$2" '[.[] | select(.type == "round" and .repo == $r and .pr == $n)] | length' "$LEDGER")
  fi
  for f in "$OPEN"/*.round.json; do
    [ -f "$f" ] || continue
        jq -e --arg r "$1" --argjson n "$2" '.repo == $r and .pr == $n' "$f" >/dev/null 2>&1 && open_n=$((open_n + 1))
  done
  printf '%s\n' $((done_n + open_n))
}
open_update() {  # <open-file> <jq-filter> [jq args...]
  local f=$1 filter=$2
  shift 2
  jq -c "$@" "$filter" "$f" > "$f.tmp" && mv -f "$f.tmp" "$f"
}

# ---- the worker that owns a PR head ------------------------------------------

meta_field() { grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true; }
# A task is live when its metadata exists: that is the record a spawn writes and a teardown removes.
live_task() { [ -f "$STATE/$1.meta" ] && [ ! -L "$STATE/$1.meta" ]; }

# The live task that owns a PR head, in this order: the task whose worktree is on the head branch,
# the task whose metadata records this PR, else the task the fm/<task> branch names. Prints nothing
# when no task matches, which is the one case that delivers nothing and keeps firstmate's wake.
resolve_worker_task() {  # <pr-url> <head-ref>
  local url=$1 ref=$2 meta id wt branch origin repo
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    id=${meta##*/}; id=${id%.meta}
    wt=$(meta_field "$meta" worktree)
    [ -n "$wt" ] && [ -d "$wt" ] || continue
    origin=$(git -C "$wt" remote get-url origin 2>/dev/null) || continue
    origin=${origin%.git}; origin=${origin%/}
    repo=${url#https://github.com/}; repo=${repo%/pull/*}
    case "$origin" in "https://github.com/$repo"|"git@github.com:$repo"|"ssh://git@github.com/$repo") ;; *) continue ;; esac
    branch=$(git -C "$wt" branch --show-current 2>/dev/null) || continue
    [ "$branch" = "$ref" ] || continue
    printf '%s\n' "$id"
    return 0
  done
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    id=${meta##*/}; id=${id%.meta}
    [ "$(meta_field "$meta" pr)" = "$url" ] || continue
    printf '%s\n' "$id"
    return 0
  done
  case "$ref" in fm/*) id=${ref#fm/} ;; *) return 1 ;; esac
  case "$id" in ''|*[!A-Za-z0-9._-]*|.*|*..*) return 1 ;; esac
  printf '%s\n' "$id"
}

# Send one message to a live task's steering inbox. The durable inbox record is the delivery
# (bin/fm-send.sh), so an untyped doorbell still counts, and an exact repeat is dropped: a replayed
# autohandle sends nothing twice.
steer_worker() {  # <task> <text-file>
  local task=$1 text=$2
  live_task "$task" || return 1
  [ -s "$text" ] || return 1
  FM_SEND_IDEMPOTENT=1 "$SEND" "$task" "$(cat "$text")" >/dev/null 2>&1
}

# The message a worker gets for one round: the in-scope findings verbatim, in the order the answers
# give them, then the instruction to check each one in source.
findings_message() {  # <result-file> <out-file> <headline>
  local f=$1 out=$2 headline=$3 lines
  lines=$(jq -r --arg l "$LABEL_IN" '[.reviewer.findings[]?, .reader.findings[]?] | map(select(.label == $l)) | .[].source' "$f" 2>/dev/null) || return 1
  [ -n "$lines" ] || return 1
  {
    printf '%s\n\n' "$headline"
    printf '%s\n' "$lines"
    printf '\nverify each in source; fix it, or answer with the evidence that it does not hold.\n'
  } > "$out"
}

# Deliver one round's in-scope findings to the worker that owns the head. Exit 0 when a live
# worker's inbox got the message; that is what lets the round go unacknowledged and wake nobody.
deliver_round() {  # <result-file> <task>
  local f=$1 task=$2 repo n head round count tmp rc=1
  repo=$(jq -r '.repo // ""' "$f"); n=$(jq -r '.pr // 0' "$f")
  head=$(jq -r '.head // ""' "$f"); round=$(jq -r '.round // 0' "$f")
  [ -n "$repo" ] && [ -n "$head" ] || return 1
  count=$(jq -r --arg l "$LABEL_IN" '[.reviewer.findings[]?, .reader.findings[]?] | map(select(.label == $l)) | length' "$f" 2>/dev/null) || return 1
  [ "${count:-0}" -gt 0 ] || return 1
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-pr-review-msg.XXXXXX") || return 1
  if findings_message "$f" "$tmp" "Review round $round on https://github.com/$repo/pull/$n at head $head has these in-scope findings:"; then
    steer_worker "$task" "$tmp" && rc=0
  fi
  rm -f "$tmp"
  return "$rc"
}

# ---- the CI result on the current head ----------------------------------------

# A GitHub read that never announces itself: a check or log read that fails is retried by the next
# poll instead of becoming a "GitHub could not be read" wake.
gh_quiet() { "$GH" api "$1" 2>/dev/null; }

# The lines of a failed job's log that say `gate FAILED`, each with the line after it. GitHub puts an
# ISO timestamp in front of a log line; that is dropped. A log that cannot be read adds nothing.
gate_failed_lines() {  # <repo> <job-id>
  local repo=$1 id=$2 log
  case "$id" in ''|*[!0-9]*) return 0 ;; esac
  log=$(gh_quiet "repos/$repo/actions/jobs/$id/logs") || return 0
  [ -n "$log" ] || return 0
  printf '%s\n' "$log" | awk '
    { line = $0; sub(/^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9:.]+Z /, "", line) }
    line ~ /gate FAILED/ { print line; want = 1; next }
    want { print line; want = 0 }'
}

# The checks that did not pass on a head, one record per check: severity-free, the name, the job URL
# and the job id whose log carries the gate's own reasons.
failed_checks() {  # <check-runs-json>
  jq -r '.check_runs[]? | select(.status == "completed") | select(.conclusion | IN("failure", "timed_out", "cancelled", "action_required", "startup_failure")) | (.details_url // .html_url // "") as $url | [.name, $url, (try ($url | capture("/job/(?<id>[0-9]+)").id) catch "-")] | @tsv' "$1" 2>/dev/null
}

# One CI result for one PR's current head, once every check on it has finished. The result is one ci
# event on the worker's task record, which clears a declared `wait --next-actor ci --clears-on ci`,
# and for a failed head one message naming each failed check and its gate lines. A green head sends
# the worker nothing, and a head replaced before its checks finished is never read.
handle_ci() {  # <repo> <pr-row> <task>
  local repo=$1 row=$2 task=$3 n url head key runs total current page=1 part count
  n=$(jq -r .number <<<"$row"); url=$(jq -r .html_url <<<"$row"); head=$(jq -r .head.sha <<<"$row")
  key="$repo#$n"
  [ "$(state_json | jq -r --arg k "$key" '.ci[$k].head // ""')" != "$head" ] || return 0
  runs=$(gh_quiet "repos/$repo/commits/$head/check-runs?per_page=100") || return 0
  [ -n "$runs" ] || return 0
  count=$(jq '.check_runs | length' <<<"$runs")
  while [ "$count" -lt "$(jq '.total_count // 0' <<<"$runs")" ]; do
    page=$((page + 1))
    part=$(gh_quiet "repos/$repo/commits/$head/check-runs?per_page=100&page=$page") || return 0
    [ "$(jq '.check_runs | length' <<<"$part")" -gt 0 ] || return 0
    runs=$(jq -cn --argjson a "$runs" --argjson b "$part" '$a | .check_runs += $b.check_runs') || return 0
    count=$(jq '.check_runs | length' <<<"$runs")
  done
  total=$(jq -r '.total_count // 0' <<<"$runs" 2>/dev/null) || return 0
  [ "${total:-0}" -gt 0 ] || return 0
  [ "$(jq -r '.check_runs | length' <<<"$runs")" = "$total" ] || return 0
  [ "$(jq -r '[.check_runs[]? | select(.status != "completed")] | length' <<<"$runs" 2>/dev/null)" = 0 ] || return 0
  current=$(gh_quiet "repos/$repo/pulls/$n") || return 0
  [ "$(jq -r '.head.sha // ""' <<<"$current")" = "$head" ] || return 0
  ci_result "$repo" "$n" "$url" "$head" "$runs" "$task" || return 0
  state_edit '.ci[$k] = {head: $h, at: $t}' --arg k "$key" --arg h "$head" --argjson t "$(now)"
}

# Record one finished head: the ci event, then the worker's message when a check failed.
ci_result() {  # <repo> <pr> <pr-url> <head> <check-runs-json> <task>
  local repo=$1 n=$2 url=$3 head=$4 runs=$5 task=$6 tmp probe state_note name link job lines block='' failing=0
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-pr-review-ci.XXXXXX") || return 1
  printf '%s\n' "$runs" > "$tmp.runs"
  while IFS=$'\t' read -r name link job; do
    [ -n "$name" ] || continue
    failing=$((failing + 1))
    lines=$(gate_failed_lines "$repo" "$job")
    block+="FAILED $name"$'\n'
    [ -z "$link" ] || block+="$link"$'\n'
    [ -z "$lines" ] || block+="$lines"$'
'
  done < <(failed_checks "$tmp.runs")
  rm -f "$tmp" "$tmp.runs"
  if live_task "$task"; then
    state_note="CI green on $url at head $head"
    [ "$failing" -eq 0 ] || state_note="CI failed on $url at head $head: $failing check(s) did not pass"
    if [ "$failing" -gt 0 ]; then
      probe=$(mktemp "${TMPDIR:-/tmp}/fm-pr-review-cimsg.XXXXXX") || return 0
      {
        printf 'CI on %s at head %s failed: %s check(s) did not pass.\n\n' "$url" "$head" "$failing"
        printf '%s' "$block"
        printf '\nFix each failure in source and push, or answer firstmate with the evidence that it is not yours.\n'
      } > "$probe"
      if ! steer_worker "$task" "$probe"; then rm -f "$probe"; return 1; fi
      rm -f "$probe"
    fi
    "$TASK_WRITER" event "$task" ci --head "$head" --note "$state_note" --key "pr-review:ci:$repo:$n:$head" --actor pr-review --role system >/dev/null 2>&1 || return 1
  else
    return 1
  fi
  return 0
}

# ---- findings and the scope check --------------------------------------------

# The reader's answer text. reader-round.sh saves "chat: <url>", a blank line, then
# `result: "<json string>"`, whose value is itself quoted JSON; a plain text answer is read as is.
answer_text() {  # <answer-file>
  local raw t
  raw=$(sed -n 's/^result: //p' "$1" | head -1)
  if [ -z "$raw" ]; then
    grep -v '^chat: ' "$1"
    return 0
  fi
  t=$(jq -r 'if type == "string" then . else tostring end' <<<"$raw" 2>/dev/null) || t=$raw
  case "$t" in '"'*) t=$(jq -r 'if type == "string" then . else tostring end' <<<"$t" 2>/dev/null || printf '%s' "$t") ;; esac
  printf '%s\n' "$t"
}

# One row per FINDING line (F, severity, path, first line, last line, text) and per line kept under a
# PRE-EXISTING heading (P, text). Fields are split by the unit separator (octal 037), which is not
# whitespace, so an empty path or line field stays a field and the text is never shifted.
extract_rows() {
  tr '\t\037' '  ' | awk '
    function trim(s) { gsub(/^ +| +$/, "", s); return s }
    BEGIN { pre = 0 }
    {
      line = $0
      sub(/^[ >*_`-]+/, "", line)
      if (line ~ /^FINDING( |$)/) {
        pre = 0
        rest = trim(substr(line, 8))
        sev = "unknown"
        if (match(rest, /^(blocking|note)( |$)/)) {
          sev = trim(substr(rest, 1, RLENGTH))
          rest = trim(substr(rest, RLENGTH + 1))
        }
        tok = rest
        sub(/ .*/, "", tok)
        loc = tok
        gsub(/^[`(\[]+|[`)\],.;]+$/, "", loc)
        path = ""; ls = ""; le = ""
        if (match(loc, /:[0-9]+((-|–)[0-9]+)?$/)) {
          path = substr(loc, 1, RSTART - 1)
          range = substr(loc, RSTART + 1)
          ls = range
          sub(/(-|–).*/, "", ls)
          le = ls
          if (range ~ /(-|–)/) { le = range; sub(/^[0-9]+(-|–)/, "", le) }
          rest = trim(substr(rest, length(tok) + 1))
        }
        printf "F\037%s\037%s\037%s\037%s\037%s\037%s\n", sev, path, ls, le, rest, line
        next
      }
      if (line ~ /^PRE-EXISTING/) { pre = 1; next }
      if (pre && line != "") printf "P\037%s\n", line
    }'
}

# Label one located finding against the stored merge-base..head diff.
label_for() {  # <compare-file> <path> <first-line> <last-line>
  local cmpf=$1 path=${2#./} ls=$3 le=$4 kind patch
  { [ -n "$path" ] && [ -n "$ls" ]; } || { echo unlocated; return 0; }
  [ -f "$cmpf" ] || { echo unchecked; return 0; }
    kind=$(jq -r --arg p "$path" '[.files[] | select(.filename == $p)] | first // null | if . == null then "none" elif .patch == null then "nopatch" else "patch" end' "$cmpf")
  case "$kind" in
    none) echo "$LABEL_OUT" ;;
    nopatch) echo unchecked ;;
    *)
            patch=$(jq -r --arg p "$path" '[.files[] | select(.filename == $p)] | first | .patch' "$cmpf")
      if printf '%s\n' "$patch" | awk -v a="$ls" -v b="$le" '
        BEGIN { if (b + 0 < a + 0) { t = a; a = b; b = t } }
        # A hunk that ends in a deletion ends the file: anchor it to the last line the head still has.
        function eof_anchor() { if (lastminus && h - 1 >= a + 0 && h - 1 <= b + 0) hit = 1; lastminus = 0 }
        /^@@/ {
          eof_anchor()
          s = $0; sub(/^@@ -[0-9]+(,[0-9]+)? \+/, "", s)
          c = s; sub(/[^0-9].*/, "", c)
          d = 1
          if (s ~ /^[0-9]+,[0-9]+/) { d = s; sub(/^[0-9]+,/, "", d); sub(/[^0-9].*/, "", d) }
          h = c + 0
          if (h == 0) hit = 1   # the whole file is deleted: there is no head side to point at
          if (d + 0 == 0) h = h + 1
          next
        }
        /^\+/ { if (h >= a + 0 && h <= b + 0) hit = 1; h++; lastminus = 0; next }
        /^-/ { if (h >= a + 0 && h <= b + 0) hit = 1; lastminus = 1; next }
        /^\\/ { next }
        { h++; lastminus = 0 }
        END { eof_anchor(); exit !hit }'; then
        echo "$LABEL_IN"
      else
        echo "$LABEL_OUT"
      fi
      ;;
  esac
}

# {findings:[...], pre_existing:[...], labels:{...}} for an answer text.
scan_findings() {  # <text-file> <compare-file>
  local text=$1 cmpf=$2 kind sev path ls le rest src label findings='[]' pre='[]'
  while IFS=$'\037' read -r kind sev path ls le rest src; do
    case "$kind" in
      F)
        label=$(label_for "$cmpf" "$path" "$ls" "$le")
        findings=$(jq -c --arg sev "$sev" --arg path "$path" --arg ls "$ls" --arg le "$le" --arg text "$rest" --arg src "$src" --arg label "$label" \
          '. + [{severity: $sev, path: (if $path == "" then null else $path end), line: (if $ls == "" then null else ($ls | tonumber) end),
                 line_end: (if $le == "" then null else ($le | tonumber) end), text: $text, source: $src, label: $label}]' <<<"$findings")
        ;;
      P) pre=$(jq -c --arg t "$sev" '. + [$t]' <<<"$pre") ;;
    esac
  done < <(extract_rows < "$text")
  jq -cn --argjson f "$findings" --argjson p "$pre" \
    '{findings: $f, pre_existing: $p, labels: ($f | reduce .[] as $x ({}; .[$x.label] += 1))}'
}

# ---- the ask text ------------------------------------------------------------

reader_prompt() {  # <pr-url> <head> <merge-base> <round>
  cat <<EOF
Review $1 at head $2 (round $4).
Merge base: $3
Review merge-base..head only.

$SCOPE_RULE

Report one line per finding, in exactly this form:
$FINDING_FORMAT
List pre-existing problems apart, under a PRE-EXISTING heading, never as FINDING lines.
EOF
}

reviewer_content() {  # <task> <pr-url> <head> <merge-base> <round>
  jq -cn --arg task "$1" --arg pr "$2" --arg head "$3" --arg mb "$4" --argjson round "$5" --arg scope "$SCOPE_RULE" \
    --arg fmt "One line per finding: $FINDING_FORMAT. List pre-existing problems apart, under a PRE-EXISTING heading, never as FINDING lines." \
    '{schema: "fm-reviewer-ask.v1", task: $task, pr: $pr, head: $head, merge_base: $mb, round: $round, scope: $scope, report_format: $fmt}'
}

# ---- starting a round --------------------------------------------------------

# Exit 2: GitHub could not be read (READ_ERROR_FILE says what).
start_round() {  # <repo> <pr> <pr-url> <task> <head> <base-ref> <round>
  local repo=$1 n=$2 url=$3 task=$4 head=$5 base=$6 round=$7 cmp merge_base committed started key f content record
  cmp=$(gh_read "repos/$repo/compare/$base...$head") || return 2
  merge_base=$(jq -r '.merge_base_commit.sha // empty' <<<"$cmp")
  if [ -z "$merge_base" ]; then
    printf 'GitHub could not be read: repos/%s/compare (no merge base)\n' "$repo" > "$READ_ERROR_FILE"
    return 2
  fi
  started=$(now)
  committed=$(jq -r '.commits[-1].commit.committer.date // empty | fromdateiso8601? // empty' <<<"$cmp" 2>/dev/null)
  [ -n "$committed" ] || committed=$started
  key=$(key_of "$repo" "$n" "$head")
  f="$OPEN/$key.round.json"
  mkdir -p "$OPEN" "$FM_HOME/data/$task"
  jq -c '{files: [.files[]? | {filename, status, patch: (.patch // null)}]}' <<<"$cmp" > "$OPEN/$key.compare.json"
  reader_prompt "$url" "$head" "$merge_base" "$round" > "$FM_HOME/data/$task/reader-prompt-${head:0:8}.txt"
  jq -cn --arg repo "$repo" --argjson pr "$n" --arg url "$url" --arg task "$task" --arg head "$head" --arg mb "$merge_base" \
    --argjson round "$round" --argjson started "$started" --argjson committed "$committed" --arg a "$ASSISTANCE" \
    '{repo: $repo, pr: $pr, pr_url: $url, task: $task, head: $head, merge_base: $mb, round: $round, started: $started, committed: $committed,
      reviewer: {assistance: $a, record: null, status: "pending", report: null, at: null, findings: [], pre_existing: [], labels: {}},
      reader: {status: "pending", answer: null, at: null, findings: [], pre_existing: [], labels: {}}}' > "$f"
  content=$(reviewer_content "$task" "$url" "$head" "$merge_base" "$round")
  record=$(jq -cn --arg id "pr-review:$task:$n:${head:0:12}" --argjson at "$started" --arg c "$content" \
    '{schema: "fm-assistance-mentions.v1", messages: [{id: $id, arrival: $at, content: $c}]}')
  if deliver_record Reviewer "$ASSISTANCE" "$record"; then
    open_update "$f" '.reviewer.record = $b' --arg b "$DELIVER_BASE"
  else
    open_update "$f" '.reviewer.status = $s' --arg s "failed: ${DELIVER_ERROR#*ask not delivered: }"
  fi
}

# ---- the two reviewers -------------------------------------------------------

reviewer_report() {  # <record-basename>: the report path once the Reviewer has finished
  local home f
  home=$(secondmate_registry_field "$FM_HOME/data/assistances.md" "$ASSISTANCE" home 2>/dev/null) || return 1
  [ -n "$home" ] || return 1
  [ ! -e "$home/data/pending-mentions/$1" ] || return 1
  for f in "$home/data/reviews/${1%.json}.md" "$home/data/reviews/$1.md"; do
    if [ -s "$f" ]; then printf '%s\n' "$f"; return 0; fi
  done
  return 1
}

# Run a command with its output in <outfile>; stop it with TERM, then KILL, after <seconds>.
# Exit 124 means it was stopped. (`timeout` is not on every platform firstmate runs on.)
run_with_timeout() {  # <seconds> <outfile> <command> [args...]
  local secs=$1 outf=$2 pid wd rc flag
  shift 2
  flag="$outf.timeout"
  rm -f "$flag"
  "$@" > "$outf" 2>&1 &
  pid=$!
  {
    sp=
    trap 'kill "$sp" 2>/dev/null; exit 0' TERM
    sleep "$secs" & sp=$!
    wait "$sp" || exit 0
    : > "$flag"
    kill -TERM "$pid" 2>/dev/null
    sleep 10 & sp=$!
    wait "$sp" || exit 0
    kill -KILL "$pid" 2>/dev/null
  } &
  wd=$!
  wait "$pid"
  rc=$?
  kill "$wd" 2>/dev/null
  wait "$wd" 2>/dev/null
  [ ! -e "$flag" ] || { rm -f "$flag"; return 124; }
  return "$rc"
}

# The reader's turn for one open round. A failure is a status, never a retry.
run_reader() {  # <open-file>
  local f=$1 task head round n head8 session chat newchat=0 answer prompt rel out outf rc reason text scan in_scope count first
  task=$(jq -r .task "$f"); head=$(jq -r .head "$f"); round=$(jq -r .round "$f"); n=$(jq -r .pr "$f")
  head8=${head:0:8}
  session="$FM_HOME/data/$task/reader-session.md"
  chat=
  [ ! -f "$session" ] || chat=$(grep '^chat: ' "$session" | tail -1 | sed 's/^chat: //')
  if [ -z "$chat" ]; then chat=$READER_URL; newchat=1; fi
  rel="data/$task/reader-gpt-$head8.md"
  answer="$FM_HOME/$rel"
  prompt="$FM_HOME/data/$task/reader-prompt-$head8.txt"
  if [ -z "$READER_CMD" ] || [ ! -x "$READER_CMD" ]; then
    reason='failed: reader.command is not set or not executable'
  elif [ -z "$chat" ]; then
    reason='failed: no chat in reader-session.md and no reader.project_url'
  else
    rm -f "$answer"
    outf=$(mktemp "${TMPDIR:-/tmp}/fm-pr-review-reader.XXXXXX") || return 1
    run_with_timeout "$READER_TIMEOUT" "$outf" "$READER_CMD" "$chat" "$prompt" "$answer"
    rc=$?
    out=$(cat "$outf")
    rm -f "$outf"
    if [ "$rc" -eq 124 ]; then
      reason="failed: timeout after ${READER_TIMEOUT}s"
    elif [ "$rc" -ne 0 ] || [ ! -s "$answer" ]; then
      reason=$(printf '%s\n' "$out" | grep -m1 -E 'FAILED|NOT FOUND' || printf '%s\n' "$out" | grep -m1 . || true)
      reason="failed: ${reason:-reader exited $rc}"
      reason=${reason:0:200}
    else
      reason=
    fi
  fi
  if [ -n "$reason" ]; then
    open_update "$f" '.reader.status = $s | .reader.at = $t' --arg s "$reason" --argjson t "$(now)"
    return 0
  fi
  text=$(mktemp "${TMPDIR:-/tmp}/fm-pr-review.XXXXXX") || return 1
  answer_text "$answer" > "$text"
  scan=$(scan_findings "$text" "$OPEN/$(key_of "$(jq -r .repo "$f")" "$n" "$head").compare.json")
  rm -f "$text"
  count=$(jq -r '.findings | length' <<<"$scan")
  in_scope=$(jq -r --arg l "$LABEL_IN" '[.findings[] | select(.label == $l)] | length' <<<"$scan")
  if [ "$newchat" = 1 ]; then
    first=$(grep -m1 '^chat: ' "$answer" || true)
    [ -z "$first" ] || printf '%s\n' "$first" >> "$session"
  fi
  printf 'round %s (PR %s): head %s, answer %s (auto: %s findings, %s in scope)\n' "$round" "$n" "$head8" "$rel" "$count" "$in_scope" >> "$session"
  open_update "$f" '.reader = {status: "answered", answer: $a, at: $t, findings: $s.findings, pre_existing: $s.pre_existing, labels: $s.labels}' \
    --arg a "$rel" --argjson t "$(now)" --argjson s "$scan"
}

# Move the Reviewer part of an open round on: answered, or timeout.
check_reviewer() {  # <open-file>
  local f=$1 base report started scan
  [ "$(jq -r .reviewer.status "$f")" = pending ] || return 0
  base=$(jq -r .reviewer.record "$f")
  if report=$(reviewer_report "$base"); then
    scan=$(scan_findings "$report" "$OPEN/$(key_of "$(jq -r .repo "$f")" "$(jq -r .pr "$f")" "$(jq -r .head "$f")").compare.json")
    open_update "$f" '.reviewer |= (. + {status: "answered", report: $r, at: $t, findings: $s.findings, pre_existing: $s.pre_existing, labels: $s.labels})' \
      --arg r "$report" --argjson t "$(now)" --argjson s "$scan"
    return 0
  fi
  started=$(jq -r .started "$f")
  if [ $(( $(now) - started )) -ge "$REVIEWER_TIMEOUT" ]; then
    open_update "$f" '.reviewer.status = "timeout"'
  fi
}

# ---- results -----------------------------------------------------------------

EMIT=
emit_error() { EMIT=$(jq -cn --arg e "$1" '{schema: "fm-pr-review-result.v1", kind: "error", error: $e, recovered: false}'); }
emit_recovery() { EMIT='{"schema":"fm-pr-review-result.v1","kind":"recovery","error":null,"recovered":true}'; }

# A new head of an open PR of a live task: baseline, wait for it to settle, then cap or start a round.
# Exit 0: carry on. Exit 2: GitHub unreadable. Exit 10: EMIT holds a cap result.
handle_pr() {  # <repo> <pr-json> <first-poll-epoch-or-empty> <task>
  local repo=$1 row=$2 first=$3 task=$4 n url head base hkey tracked since count
  n=$(jq -r .number <<<"$row"); url=$(jq -r .html_url <<<"$row"); head=$(jq -r .head.sha <<<"$row")
  base=$(jq -r .base.ref <<<"$row")
  if [ -z "$task" ]; then
    ledger_pr_has skip "$repo" "$n" \
      || ledger_append "$(jq -cn --arg r "$repo" --argjson n "$n" --argjson at "$(now)" '{type: "skip", repo: $r, pr: $n, reason: "no-task", at: $at}')"
    return 0
  fi
  [ ! -e "$OPEN/$(key_of "$repo" "$n" "$head").round.json" ] || return 0
  ledger_head_known "$repo" "$n" "$head" && return 0
  if [ -z "$first" ]; then
    ledger_append "$(jq -cn --arg r "$repo" --argjson n "$n" --arg h "$head" --argjson at "$(now)" '{type: "baseline", repo: $r, pr: $n, head: $h, at: $at}')"
    return 0
  fi
  hkey="$repo#$n"
  tracked=$(state_json | jq -c --arg k "$hkey" '.heads[$k] // {}')
  if [ "$(jq -r '.head // ""' <<<"$tracked")" != "$head" ]; then
    since=$(now)
    state_edit '.heads[$k] = {head: $h, since: $s, handled: false}' --arg k "$hkey" --arg h "$head" --argjson s "$since"
  else
    [ "$(jq -r '.handled' <<<"$tracked")" != true ] || return 0
    since=$(jq -r .since <<<"$tracked")
  fi
  [ $(( $(now) - since )) -ge "$SETTLE_SECONDS" ] || return 0
  count=$(round_count "$repo" "$n")
  if [ "$count" -ge "$MAX_ROUNDS" ]; then
    if ledger_pr_has cap "$repo" "$n"; then
      state_edit '.heads[$k].handled = true' --arg k "$hkey"
      return 0
    fi
    EMIT=$(jq -cn --arg r "$repo" --argjson n "$n" --arg u "$url" --arg t "$task" --arg h "$head" --argjson max "$MAX_ROUNDS" \
      '{schema: "fm-pr-review-result.v1", kind: "cap", error: null, recovered: false, repo: $r, pr: $n, pr_url: $u, task: $t, head: $h,
        round: $max, message: "round cap reached: no review was asked for this head"}')
    return 10
  fi
  start_round "$repo" "$n" "$url" "$task" "$head" "$base" $((count + 1)) || return $?
  state_edit '.heads[$k].handled = true' --arg k "$hkey"
}

poll_prs() {
  local repo prs row first rc task
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    prs=$(gh_read "repos/$repo/pulls?state=open&per_page=100") || return 2
    first=$(state_json | jq -r --arg r "$repo" '.started[$r] // empty')
    while IFS= read -r row; do
      task=
      task=$(resolve_worker_task "$(jq -r .html_url <<<"$row")" "$(jq -r .head.ref <<<"$row")") || task=
      # The first poll of a repository is a baseline, so a head that was there before the source was
      # enabled gets no CI result either; an existing CI failure is not news a worker must act on.
      [ -z "$first" ] || handle_ci "$repo" "$row" "$task"
      handle_pr "$repo" "$row" "$first" "$task"
      rc=$?
      [ "$rc" -eq 0 ] || return "$rc"
    done < <(jq -c '.[] | {number, html_url, head: {sha: .head.sha, ref: .head.ref}, base: {ref: .base.ref}}' <<<"$prs")
    [ -n "$first" ] || state_edit '.started[$r] = $t' --arg r "$repo" --argjson t "$(now)"
  done <<<"$REPOS"
  return 0
}

# A Reviewer report that came after its timeout: one more result for that round.
poll_late() {
  local row base report repo n head scan
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    base=$(jq -r .reviewer.record <<<"$row")
    report=$(reviewer_report "$base") || continue
    repo=$(jq -r .repo <<<"$row"); n=$(jq -r .pr <<<"$row"); head=$(jq -r .head <<<"$row")
    scan=$(scan_findings "$report" "$OPEN/$(key_of "$repo" "$n" "$head").compare.json")
    EMIT=$(jq -c --arg r "$report" --argjson s "$scan" \
      '{schema: "fm-pr-review-result.v1", kind: "late", error: null, recovered: false, repo, pr, task, head, round,
        reviewer: {status: "answered", record: .reviewer.record, report: $r, findings: $s.findings, pre_existing: $s.pre_existing, labels: $s.labels}}' <<<"$row")
    return 10
  done < <([ -s "$LEDGER" ] && jq -c -s '. as $all | .[] | select(.type == "round" and .reviewer.status == "timeout")
    | select(. as $r | $all | any(.[]; .type == "late" and .repo == $r.repo and .pr == $r.pr and .head == $r.head) | not)' "$LEDGER")
  return 0
}

# One pass. Exit 0: EMIT holds a result. Exit 1: nothing is due. Exit 2: GitHub unreadable and
# nothing else is due. POLL_FAILED says whether this pass could read GitHub.
POLL_FAILED=0
pass() {
  local rc f pid
  local -a reader_pids=()
  EMIT=
  POLL_FAILED=0
  poll_prs
  rc=$?
  case "$rc" in 2) POLL_FAILED=1 ;; 10) return 0 ;; esac
  # Rounds already open finish and time out even when GitHub cannot be read.
  # Each round's reader opens its own tab and bridge session, so every pending
  # round is asked in this pass, at most READER_JOBS at once.
  for f in "$OPEN"/*.round.json; do
    [ -f "$f" ] || continue
    [ "$(jq -r .reader.status "$f")" = pending ] || continue
    run_reader "$f" &
    reader_pids+=("$!")
    if [ "${#reader_pids[@]}" -ge "${FM_PR_REVIEW_READER_JOBS:-3}" ]; then
      wait "${reader_pids[0]}" 2>/dev/null || true
      reader_pids=("${reader_pids[@]:1}")
    fi
  done
  for pid in ${reader_pids[@]+"${reader_pids[@]}"}; do
    wait "$pid" 2>/dev/null || true
  done
  for f in "$OPEN"/*.round.json; do
    [ -f "$f" ] || continue
    check_reviewer "$f"
    if [ "$(jq -r .reviewer.status "$f")" != pending ] && [ "$(jq -r .reader.status "$f")" != pending ]; then
      EMIT=$(jq -c '{schema: "fm-pr-review-result.v1", kind: "round", error: null, recovered: false} + .' "$f")
      return 0
    fi
  done
  poll_late
  rc=$?
  [ "$rc" -eq 10 ] && return 0
  [ "$POLL_FAILED" -eq 0 ] || return 2
  return 1
}

# ---- wait --------------------------------------------------------------------

# The runner ends after one published result, so a home would lose its poller
# until the next reconcile. Emitting starts the next generation here; the delay
# lets this runner release its claim, and a start that loses the claim lock
# leaves the source to that generation or to reconcile.
rearm_source() {
  [ "${FM_PR_REVIEW_ONCE:-0}" != 1 ] || return 0
  ( sleep "${FM_PR_REVIEW_REARM_DELAY_SECONDS:-5}"
    exec "$SCRIPT_DIR/fm-procevent.sh" start "$SOURCE_ID" ) >/dev/null 2>&1 &
}

cmd_wait() {
  local rc previous
  command -v jq >/dev/null 2>&1 || die 'jq is required'
  while :; do
    if ! load_config; then
      # Off forgets the first-poll marks: heads pushed meanwhile get a fresh baseline when it is on again.
      [ ! -s "$CURSOR" ] || state_edit 'del(.started) | del(.heads)'
      [ "${FM_PR_REVIEW_ONCE:-0}" != 1 ] || return 1
      sleep "${FM_PR_REVIEW_IDLE_SECONDS:-60}"
      continue
    fi
    mkdir -p "$DATA" "$OPEN"
    throttle
    date +%s > "$LAST_POLL"
    pass
    rc=$?
    previous=
    [ ! -f "$LAST_ERROR" ] || previous=$(<"$LAST_ERROR")
    case "$rc" in
      0)
        # A poll that read GitHub ends the failure episode, so the same reason is announced again later,
        # and the error results of that episode are closed here: no recovery result follows a round.
        if [ "$POLL_FAILED" -eq 0 ]; then
          rm -f "$LAST_ERROR"
          [ -z "$previous" ] || mark_errors_handled 999999999999
        fi
        printf '%s\n' "$EMIT"
        rearm_source
        return 0
        ;;
      2)
        # A failure is announced once; the same reason stays quiet while the polls go on.
        READ_ERROR=$(<"$READ_ERROR_FILE")
        if [ "$previous" != "$READ_ERROR" ]; then
          printf '%s\n' "$READ_ERROR" > "$LAST_ERROR"
          emit_error "$READ_ERROR"
          printf '%s\n' "$EMIT"
          rearm_source
          return 0
        fi
        ;;
      *)
        if [ -n "$previous" ]; then
          emit_recovery
          printf '%s\n' "$EMIT"
          rearm_source
          return 0
        fi
        ;;
    esac
    [ "${FM_PR_REVIEW_ONCE:-0}" != 1 ] || return 1
  done
}

# ---- autohandle, silent, classify ----------------------------------------------

# A recovery closes itself and the older error results. A round, late or cap result waits for firstmate.
mark_errors_handled() {  # <sequence>
  local seq=$1 pending s
  while IFS= read -r pending; do
    [ -n "$pending" ] || continue
    s=${pending%.result}
    s=${s##*.}
    case "$s" in ''|*[!0-9]*) continue ;; esac
    [ "$s" -le "$seq" ] || continue
    jq -e '.kind == "error" or .kind == "recovery"' "$pending" >/dev/null 2>&1 || continue
    "$SCRIPT_DIR/fm-procevent.sh" handled "$SOURCE_ID" "$s" >/dev/null 2>&1 || true
  done < <(fm_procevent_pending "$STATE" | grep "/$SOURCE_ID\.")
}

cmd_autohandle() {  # <source-id> <sequence> <result-file>
  local sid=${1:-} seq=${2:-} result=${3:-} kind key repo n head task delivered=0 retained
  [ "$sid" = "$SOURCE_ID" ] && [ -f "$result" ] || return 1
  case "$seq" in ''|*[!0-9]*) return 1 ;; esac
  jq -e '.schema == "fm-pr-review-result.v1"' "$result" >/dev/null 2>&1 || return 1
  kind=$(jq -r .kind "$result")
  mkdir -p "$DATA"
  repo=$(jq -r '.repo // ""' "$result"); n=$(jq -r '.pr // 0' "$result"); head=$(jq -r '.head // ""' "$result")
  task=$(jq -r '.task // ""' "$result")
  # A round whose in-scope findings reach a live worker's inbox wakes nobody: the worker is the one that
  # changes the code, so firstmate hears about that round at the worker's done instead.
  case "$kind" in
    round|late) deliver_round "$result" "$task" && delivered=1 ;;
  esac
  case "$kind" in
    recovery)
      rm -f "$LAST_ERROR"
      mark_errors_handled "$seq"
      return 0
      ;;
    round)
      # What the worker did not get stays with firstmate (the script header owns how it is read).
      retained=$(jq -c --arg l "$LABEL_IN" '([.reviewer.findings[]?, .reader.findings[]?] | map(select(.label != $l)) | map(.source)) + [.reviewer.pre_existing[]?, .reader.pre_existing[]?]' "$result" 2>/dev/null) || retained='[]'
      ledger_test '.type == "round" and .repo == $r and .pr == $n and .head == $h' --arg r "$repo" --argjson n "$n" --arg h "$head" \
        || ledger_append "$(jq -c --argjson at "$(now)" --argjson delivered "$delivered" --argjson retained "$retained" '{type: "round", repo, pr, task, head, round, at: $at, committed,
             delivered: ($delivered == 1), retained: $retained,
             reviewer: {record: .reviewer.record, status: .reviewer.status, report: .reviewer.report, at: .reviewer.at, labels: .reviewer.labels},
             reader: {status: .reader.status, answer: .reader.answer, at: .reader.at, labels: .reader.labels}}' "$result")"
      key=$(key_of "$repo" "$n" "$head")
      rm -f "$OPEN/$key.round.json"
      [ "$(jq -r .reviewer.status "$result")" = timeout ] || rm -f "$OPEN/$key.compare.json"
      ;;
    late)
      ledger_test '.type == "late" and .repo == $r and .pr == $n and .head == $h' --arg r "$repo" --argjson n "$n" --arg h "$head" \
        || ledger_append "$(jq -c --argjson at "$(now)" --argjson delivered "$delivered" '{type: "late", repo, pr, head, round, at: $at, delivered: ($delivered == 1), report: .reviewer.report, labels: .reviewer.labels}' "$result")"
      rm -f "$OPEN/$(key_of "$repo" "$n" "$head").compare.json"
      ;;
    cap)
      ledger_pr_has cap "$repo" "$n" \
        || ledger_append "$(jq -c --argjson at "$(now)" '{type: "cap", repo, pr, head, at: $at}' "$result")"
      ;;
  esac
  if [ "$delivered" -eq 1 ]; then
    "$SCRIPT_DIR/fm-procevent.sh" handled "$SOURCE_ID" "$seq" >/dev/null 2>&1 || return 1
    return 0
  fi
  return 1
}

cmd_silent() {  # <result-file>
  jq -e '.schema == "fm-pr-review-result.v1" and .kind == "recovery"' "${1:-}" >/dev/null 2>&1
}

cmd_classify() {  # <result-file>
  local kind
  kind=$(jq -r '.kind // empty' "${1:-}" 2>/dev/null)
  case "$kind" in error|round|late|cap|recovery) printf '%s\n' "$kind" ;; *) printf 'record\n' ;; esac
}

# ---- summary -----------------------------------------------------------------

cmd_summary() {
  local since=0
  if [ "${1:-}" = --since ]; then
    since=$(jq -rn --arg d "${2:-}" '$d | fromdateiso8601' 2>/dev/null) || die 'summary --since needs a UTC time such as 2026-10-22T06:00:00Z'
  fi
  [ -s "$LEDGER" ] || { echo 'no rounds recorded'; return 0; }
  jq -rs --argjson since "$since" '
    def cnt($rs; $who; $l): [$rs[] | (.[$who].labels // {})[$l] // 0] | add // 0;
    def times($rs; $who): [$rs[] | select(.[$who].at != null and .committed != null) | "\(.[$who].at - .committed)s"] | join("/");
    def part($rs; $who):
      "  \($who): rounds \($rs | length), findings "
      + (["in-scope", "out-of-scope (pre-existing)", "unlocated", "unchecked"] | map("\(.) \(cnt($rs; $who; .))") | join(", "))
      + ", commit-to-answer " + (times($rs; $who) | if . == "" then "none" else . end)
      + ", timeouts \([$rs[] | select(.[$who].status == "timeout")] | length)"
      + ", failures \([$rs[] | select((.[$who].status | tostring) | startswith("failed"))] | length)";
    . as $all
    | def late($r): first($all[] | select(.type == "late" and .repo == $r.repo and .pr == $r.pr and .head == $r.head)) // null;
    [.[] | select(.at >= $since and (.type == "round" or .type == "cap"))
      | if .type == "round" then (late(.) as $l | if $l == null then . else .reviewer |= (. + {labels: $l.labels, at: $l.at}) end) else . end]
    | group_by([.repo, .pr]) | .[]
    | . as $g | [$g[] | select(.type == "round")] as $rs | [$g[] | select(.type == "cap")] as $caps
    | "PR https://github.com/\($g[0].repo)/pull/\($g[0].pr) (task \($rs[0].task // "?")): \($rs | length) rounds",
      part($rs; "reviewer"), part($rs; "reader"),
      (if ($caps | length) > 0 then "  round cap reached: \($caps | length)" else empty end)' "$LEDGER"
}

cmd_arm() {
  "$SCRIPT_DIR/fm-procevent.sh" register pr-review "$SOURCE_ID" -- "$SCRIPT_DIR/fm-procevent-pr-review.sh" wait
}

case "${1:-}" in
  arm) shift; cmd_arm "$@" ;;
  wait) shift; cmd_wait "$@" ;;
  summary) shift; cmd_summary "$@" ;;
  autohandle) shift; [ "$#" -eq 3 ] || die 'usage: autohandle <source-id> <sequence> <result-file>'; cmd_autohandle "$@" ;;
  classify) shift; cmd_classify "$@" ;;
  silent) shift; cmd_silent "$@" ;;
  terminal) exit 1 ;;
  self-announcing|relisten) exit 0 ;;
  *) echo 'error: expected arm, wait, summary, autohandle, classify, silent, terminal, self-announcing or relisten' >&2; exit 2 ;;
esac
