#!/usr/bin/env bash
# fm-owner-request.sh - firstmate's one answer to an owner request from the Firstmate board (task-checklist-template T5).
#
# The board's Done writes a `close-request` event and its Approve & start a `start-request` event (bin/fm-task-owner.sh);
# bin/fm-task.sh deliver turns each into the wake `owner request <seq>: <task> <kind> - run bin/fm-owner-request.sh
# <task> --seq <seq>`. This command answers that one request and writes its result event, so the board shows the result
# or the refusal text in Việc tiếp theo. A request that is no longer open (already answered) prints so and exits 0.
#
# Usage: fm-owner-request.sh <task> --seq N                              answer a close-request
#        fm-owner-request.sh <task> --seq N -- <project-dir> --mode M --yolo Y [other fm-spawn.sh flags]
#                                                                         answer a start-request
#        fm-owner-request.sh <task> --seq N --refuse REASON               refuse either request with REASON
#
# close-request: `fm-task.sh approve <task> --check` first, so a task approve would refuse stays as it is; then the
# cleanup: bin/fm-teardown.sh <task> when this home records the task (state/<task>.meta), else
# `fm-tasks-axi.sh done <task>` for a backlog item still open (a backlog read that fails other than NOT_FOUND refuses); then approve, then `closed`. The first refusal is written
# as `close-refused` with the refusing command's error text, and nothing after it runs. The cleanup runs before approve
# because a cleanup refusal (unlanded work) must leave the task open in its state.
# start-request: firstmate writes the task's instructions (the brief) first, as for any dispatch, and passes the spawn's
# delivery flags after `--`. The harness, model and effort come from the request's setup step (`fm-task.sh requests`):
# the owner's setup owns them, so --harness, --model and --effort after `--` are refused. A queued task moves to that
# step's state, then bin/fm-spawn.sh runs; its record hook writes `started` (without the hook, this command assigns a
# triage or todo task, then writes it). A refused spawn is written as
# `start-refused` with the spawn's error text (a blocked model, a capacity limit, a missing login).
#
# Prints one line per write and the result: `result=<kind> task=<task> seq=<request seq>`.
# Exit codes: 0 answered (also when the result is a refusal) or nothing open; 2 usage; 3 a result could not be written.
# Environment: FM_HOME selects the home (default this file's home). FM_OWNER_REQUEST_WRITER, _SPAWN, _TEARDOWN and
# _BACKLOG replace bin/fm-task.sh, bin/fm-spawn.sh, bin/fm-teardown.sh and bin/fm-tasks-axi.sh (the tests).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
WRITER="${FM_OWNER_REQUEST_WRITER:-$SCRIPT_DIR/fm-task.sh}"
SPAWN="${FM_OWNER_REQUEST_SPAWN:-$SCRIPT_DIR/fm-spawn.sh}"
TEARDOWN="${FM_OWNER_REQUEST_TEARDOWN:-$SCRIPT_DIR/fm-teardown.sh}"
BACKLOG="${FM_OWNER_REQUEST_BACKLOG:-$SCRIPT_DIR/fm-tasks-axi.sh}"

die() { echo "fm-owner-request: $1" >&2; exit "${2:-2}"; }

TASK=${1:-}
[[ "$TASK" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$ ]] || die 'usage: fm-owner-request.sh <task> --seq N [--refuse REASON | -- <fm-spawn args>]'
shift
SEQ='' REFUSE='' REFUSE_SET=0
SPAWN_ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --seq) [ "$#" -ge 2 ] || die '--seq needs a value'; SEQ=$2; shift 2 ;;
    --refuse) [ "$#" -ge 2 ] || die '--refuse needs a reason'; REFUSE=$2; REFUSE_SET=1; shift 2 ;;
    --) shift; SPAWN_ARGS=("$@"); break ;;
    *) die "unknown argument $1" ;;
  esac
done
[[ "$SEQ" =~ ^[1-9][0-9]*$ ]] || die '--seq must be the request event seq'
[ "$REFUSE_SET" -eq 0 ] || [[ "$REFUSE" =~ [^[:space:]] ]] || die '--refuse needs a nonblank reason'

export FM_TASK_ACTOR="${FM_TASK_ACTOR:-firstmate}" FM_TASK_ROLE=firstmate
unset FM_TASK_ID

open_json=$("$WRITER" requests "$TASK" --json </dev/null) || die "could not read the requests of $TASK" 3
request=$(jq -c --argjson seq "$SEQ" '.requests[] | select(.seq == $seq)' <<<"$open_json")
if [ -z "$request" ]; then
  echo "result=none task=$TASK seq=$SEQ (no open request with that seq)"
  exit 0
fi
KIND=$(jq -r '.kind' <<<"$request")
REFUSED=${KIND%-request}-refused

# The error text of a refusing command: its error lines, else its last lines, at most 1900 characters for the note.
refusal_text() {  # <file>
  local text
  text=$(grep -iE 'error|refus|fail|cannot|not ' "$1" | head -n 8)
  [ -n "$text" ] || text=$(tail -n 8 "$1")
  [ -n "$text" ] || text='refused with no message'
  text=${text//fm-task: /}
  printf '%s' "${text:0:1900}"
}

result() {  # <kind> [note]: write the result event; a write that fails exits 3
  local note_args=()
  [ -z "${2:-}" ] || note_args=(--note "$2")
  "$WRITER" event "$TASK" "$1" "${note_args[@]}" --key "owner-request:$TASK:$SEQ:result" </dev/null || die "could not write $1 for request $SEQ" 3
  echo "result=$1 task=$TASK seq=$SEQ"
  exit 0
}

refuse() { result "$REFUSED" "$1"; }

[ "$REFUSE_SET" -eq 0 ] || refuse "$REFUSE"

ERR=$(mktemp "${TMPDIR:-/tmp}/fm-owner-request.XXXXXX") || die 'no temporary file' 3
trap 'rm -f "$ERR"' EXIT
try() {  # run one step; its stderr lands in ERR and is shown after it
  local rc
  "$@" </dev/null 2>"$ERR"
  rc=$?
  cat "$ERR" >&2
  return "$rc"
}

case "$KIND" in
  close-request)
    [ "${#SPAWN_ARGS[@]}" -eq 0 ] || die 'a close-request takes no spawn arguments'
    # a run stopped after its approve only has the result left to write
    [ "$(jq -r '.state' <<<"$open_json")" != "done" ] || result closed 'Approved and cleaned up.'
    try "$WRITER" approve "$TASK" --check || refuse "$(refusal_text "$ERR")"
    if [ -f "$STATE/$TASK.meta" ]; then
      try "$TEARDOWN" "$TASK" || refuse "$(refusal_text "$ERR")"
    else
      # a task no worker ran: its cleanup is closing the backlog item, when this home holds one still open
      # only a read that says NOT_FOUND means there is no item; any other failed read refuses the close
      if backlog_out=$("$BACKLOG" show "$TASK" </dev/null 2>&1); then
        backlog_state=$(sed -n 's/^  state: //p' <<<"$backlog_out" | head -n 1)
      elif grep -q 'code: NOT_FOUND' <<<"$backlog_out"; then
        backlog_state=''
      else
        printf '%s\n' "$backlog_out" >"$ERR"
        refuse "The backlog item could not be read: $(refusal_text "$ERR")"
      fi
      if [ -n "$backlog_state" ] && [ "$backlog_state" != "done" ]; then
        try "$BACKLOG" "done" "$TASK" || refuse "$(refusal_text "$ERR")"
      fi
    fi
    try "$WRITER" approve "$TASK" --key "owner-request:$TASK:$SEQ:approve" || refuse "$(refusal_text "$ERR")"
    result closed 'Approved and cleaned up.'
    ;;
  start-request)
    if [ "${#SPAWN_ARGS[@]}" -eq 0 ]; then
      die "a start-request needs the spawn: write data/$TASK/brief.md, then run fm-owner-request.sh $TASK --seq $SEQ -- <project-dir> --mode M --yolo Y (step: $(jq -c '.step' <<<"$request"))"
    fi
    for arg in "${SPAWN_ARGS[@]}"; do
      case "$arg" in --harness|--model|--effort|--harness=*|--model=*|--effort=*) die "the owner's setup names the runtime: drop $arg" ;; esac
    done
    harness=$(jq -r '.step.harness // ""' <<<"$request")
    model=$(jq -r '.step.model // ""' <<<"$request")
    effort=$(jq -r '.step.effort // ""' <<<"$request")
    state=$(jq -r '.step.state // ""' <<<"$request")
    [ -n "$harness" ] || refuse 'The task has no setup step with a harness: set it up, then press Start again.'
    if [ "$(jq -r '.workflowState // "queued"' <<<"$open_json")" = queued ]; then
      try "$WRITER" move "$TASK" --to "$state" --key "owner-request:$TASK:$SEQ:move" || refuse "$(refusal_text "$ERR")"
    fi
    runtime=(--harness "$harness")
    [ -z "$model" ] || runtime+=(--model "$model")
    [ -z "$effort" ] || runtime+=(--effort "$effort")
    try "$SPAWN" "$TASK" "${SPAWN_ARGS[@]}" "${runtime[@]}" || refuse "$(refusal_text "$ERR")"
    # the spawn's record hook writes `started`; without it (task record off) this write does
    after_json=$("$WRITER" requests "$TASK" --json </dev/null) || die "the worker started but its requests could not be read for request $SEQ" 3
    if [ -n "$(jq -r '.requests[] | select(.kind == "start-request") | .seq' <<<"$after_json")" ]; then
      # start needs a ready task: a triage or todo task is assigned to its worker first, as the record hook does
      case "$(jq -r '.state' <<<"$after_json")" in
        triage|todo) "$WRITER" assign "$TASK" --to "$TASK" --key "owner-request:$TASK:$SEQ:assign" </dev/null || die "the worker started but the record could not assign $TASK for request $SEQ" 3 ;;
      esac
      "$WRITER" start "$TASK" --key "owner-request:$TASK:$SEQ:started" </dev/null || die "the worker started but the record could not write started for request $SEQ" 3
    fi
    echo "result=started task=$TASK seq=$SEQ"
    ;;
  *) die "unknown request kind $KIND" 3 ;;
esac
