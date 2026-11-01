#!/usr/bin/env bash
# fm-task-shadow.sh - write one state change to the task record, in shadow (spec huynhtandat223/cfw-modules#1675, T3).
#
# The old sources stay authoritative: state/<id>.meta, the status files and the steering inbox. The backlog is no longer
# mirrored here: under the cfw5001 tasks-axi backend it lives in the same Dev 5001 rows, and title_of and hold_event
# read a title, a kind and a hold-set occurrence through bin/fm-tasks-axi.sh show. A state
# script that changes one of the old sources calls this hook right after its own change succeeded, and the hook writes the same
# change to the record through bin/fm-task.sh. The hook never changes the script's result: it exits 0 whatever the
# writer answers, and it logs each writer call to state/task-shadow.log (epoch, task, hook event, writer command, exit code).
#
# Off by default. Every producer guards its call with one file test on config/task-shadow, and the hook repeats that
# test, so while the flag is absent no writer runs and no record row is written. The flag file may carry lines
# FM_TASK_BASE_URL=..., FM_TASK_AUTH=... and FM_TASK_TOKEN_FILE=... for the writer; nothing else in it is read.
#
# Usage (the first word is the hook event):
#   fm-task-shadow.sh dispatched <task> <kind> <repo> <harness>      create, assign, start         (bin/fm-spawn.sh)
#   fm-task-shadow.sh status <config> <state>/<task>.status          the last status line          (the worker's status command)
#   fm-task-shadow.sh cleaned-up <task>                              a comment event               (bin/fm-teardown.sh)
#   fm-task-shadow.sh verified <task>                                a comment event               (bin/fm-verify-close.sh)
#   fm-task-shadow.sh held <task> <hold-kind> <reason>               ask (captain) or block        (bin/fm-captain-hold.sh hold)
#   fm-task-shadow.sh answered <task> <released|closed>              unblock or approve            (bin/fm-captain-hold.sh answer)
#   fm-task-shadow.sh deploy-verify <task> <sha> <round> <issue>     a deploy event                (bin/fm-procevent-deploy-verify.sh)
#   fm-task-shadow.sh step-start <task> <generation> <harness> [<model> [<effort> [<account>]]]   (an empty model keeps the setup's)
#                                                                    step start: the current workflow state runs (bin/fm-spawn.sh,
#                                                                    a relaunch too); queued, merge and done have no worker and
#                                                                    the writer refuses it, which is logged like any refusal
#   fm-task-shadow.sh step-end <task> <generation> <reason>          step end, when a state runs     (bin/fm-teardown.sh, fm-control.sh exit)
#
# Status line to writer command: working -> heartbeat (after unblock and start when the record holds the task blocked);
# done -> done (the line is the summary; the other template fields read "-"); needs-decision -> ask with the options
# "Decide now" and "Decide later"; blocked and paused -> block transient (paused keeps its "until"); failed -> block failure;
# resolved -> unblock. A writer rule refusal (a transition the record does not allow) is logged and left to the reconciler.
#
# A task begun after T5 ('record: rows' in data/<task>/verify.md, bin/fm-verify-gate-lib.sh) is verified on check rows,
# which bin/fm-procevent-deploy-verify.sh writes itself before its ask: a verification-pending hold leaves such a task
# as it is while the record holds it in review.
#
# Every writer call carries an idempotency key built from the task, the hook event and the change, so a repeated hook
# call, or two hooks that report one change, store one event.
#
# Environment: FM_HOME, FM_CONFIG_OVERRIDE, FM_STATE_OVERRIDE, FM_DATA_OVERRIDE resolve the home like the other bin/ scripts;
# FM_TASK_SHADOW_WRITER replaces bin/fm-task.sh (the tests use a fake); FM_TASK_SHADOW_TIMEOUT bounds one writer call
# in seconds (default 30).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

EVENT=${1:-}
[ -n "$EVENT" ] || { echo 'usage: fm-task-shadow.sh <hook-event> <args...>' >&2; exit 0; }
shift
if [ "$EVENT" = status ]; then
  # the worker's status command names the config because a worker has no firstmate environment
  CONFIG=${1:-$CONFIG}
  [ "$#" -ge 2 ] || exit 0
  STATUS_FILE=$2
  STATE=$(dirname "$STATUS_FILE")
  set -- "$(basename "$STATUS_FILE" .status)" "$STATUS_FILE"
fi
FLAG="$CONFIG/task-shadow"
[ -e "$FLAG" ] || exit 0

# the writer's own settings, from the flag file
# shellcheck source=bin/fm-task-shadow-config-lib.sh
. "$SCRIPT_DIR/fm-task-shadow-config-lib.sh"
fm_task_shadow_config "$FLAG"

WRITER=${FM_TASK_SHADOW_WRITER:-$SCRIPT_DIR/fm-task.sh}
TIMEOUT=${FM_TASK_SHADOW_TIMEOUT:-30}
LOG="$STATE/task-shadow.log"
TASK=${1:-}
case "$TASK" in ''|.*|*[!A-Za-z0-9._-]*) exit 0 ;; esac

short() { printf '%s' "$1" | cksum | awk '{ printf "%x", $1 }'; }  # a short stable digest for a key
oneline() { printf '%s' "$1" | tr '\n\r\t' '   ' | sed 's/  */ /g; s/^ //; s/ $//'; }
cut_to() { local text; text=$(oneline "$1"); printf '%s' "${text:0:$2}"; }

# w <key-suffix> <writer command words...>: one writer call, never fatal. The words carry the task where the command
# wants it; --key, --actor and --role are added here.
w() {
  local suffix=$1 out rc
  shift
  # The shadow create follows dispatch, so it skips the intake identity check (bin/fm-task-identity-check.sh).
  local -a run=(env FM_TASK_IDENTITY_SKIP=1 "$WRITER" "$@" --key "shadow:$TASK:$suffix" --actor shadow --role system)
  if command -v timeout >/dev/null 2>&1; then run=(timeout "$TIMEOUT" "${run[@]}"); fi
  out=$("${run[@]}" 2>&1 </dev/null)
  rc=$?
  mkdir -p "$STATE" 2>/dev/null
  printf '%s %s %s %s rc=%s %s\n' "$(date +%s)" "$TASK" "$EVENT" "$1" "$rc" "$(cut_to "$out" 160)" >> "$LOG" 2>/dev/null
  return "$rc"
}

# The task's title and kind come from the backlog through bin/fm-tasks-axi.sh show; the backlog file is never read.
backlog_field() {  # <field>: one top-level field of `fm-tasks-axi.sh show <task>`, empty when absent
  FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-tasks-axi.sh" show "$TASK" --full 2>/dev/null \
    | sed -n "s/^  $1: //p" | head -1 | jq -Rr 'if startswith("\"") then fromjson else . end | if . == "-" then "" else . end'
}

title_of() {
  local title
  title=$(backlog_field title | sed -E 's# https?://.*##')
  printf '%s' "$(cut_to "${title:-$TASK}" 300)"
}

rows_task() { grep -qx 'record: rows' "$DATA/$TASK/verify.md" 2>/dev/null; }

record_kind() {
  case "$1" in ship|scout|assistance|secondmate|plan) printf '%s' "$1" ;; *) printf other ;; esac
}

# approve, or done then approve when the record still holds the task running
close_task() {
  local current snapshot assignee
  snapshot=$("$WRITER" show "$TASK" --json 2>/dev/null) || return 0
  current=$(printf '%s' "$snapshot" | jq -r '.state')
  assignee=$(printf '%s' "$snapshot" | jq -r '.assignee // "-"')
  [ "$assignee" != '-' ] || assignee=$TASK
  case "$current" in
    blocked|triage) w "$1-unblock" unblock "$TASK" || return 0; w "$1-start" start "$TASK" || return 0 ;;
    ready) w "$1-start" start "$TASK" || return 0 ;;
    todo) w "$1-assign" assign "$TASK" --to "$assignee" || return 0
          w "$1-start" start "$TASK" || { w "$1-archive" archive "$TASK" --note 'closed by the old source'; return 0; } ;;
  esac
  case "$current" in
    review) w "$1-approve" approve "$TASK"; return $? ;;
    done|archived) return 0 ;;
  esac
  w "$1-done" "done" "$TASK" --summary "closed by the old source" --changed-files - --verification - --residual-risk - || return 1
  w "$1-approve" approve "$TASK"
}

status_event() {
  local line state text key until
  line=$(grep -a '.' "$2" 2>/dev/null | tail -n 1)
  [ -n "$line" ] || return 0
  state=$(printf '%s' "$line" | sed -nE 's/^([a-z][a-z-]*)[ :].*/\1/p')
  text=$(printf '%s' "$line" | sed -E 's/^[a-z][a-z-]*( \[[a-z]+=[^]]*\])*:? ?//')
  key=$(short "$line")
  [ -n "$text" ] || text=$state
  text=$(cut_to "$text" 1500)
  case "$state" in
    working)
      w "status-$key" heartbeat "$TASK" --note "$text" \
        || {
          local current
          current=$("$WRITER" show "$TASK" --json 2>/dev/null | jq -r '.state') || return 0
          case "$current" in
            blocked|triage) w "status-$key-unblock" unblock "$TASK" || return 0 ;;
            ready) ;;
            *) return 0 ;;
          esac
          w "status-$key-start" start "$TASK" && w "status-$key" heartbeat "$TASK" --note "$text"
        } ;;
    done)
      local -a pr=()
      local url
      url=$(printf '%s' "$line" | grep -Eo 'https://[^ ]+/pull/[0-9]+' | head -n 1)
      [ -z "$url" ] || pr=(--pr-url "$url")
      w "status-$key" "done" "$TASK" --summary "$text" --changed-files - --verification - --residual-risk - ${pr[@]+"${pr[@]}"} ;;
    needs-decision)
      w "status-$key" ask "$TASK" --question "$text" --option 'Decide now' --option 'Decide later' --recommendation - --why 'a needs-decision status line' ;;
    blocked)
      w "status-$key" block transient "$TASK" --reason "$text" --next-actor firstmate ;;
    paused)
      until=$(printf '%s' "$line" | sed -nE 's/.*until ([0-9]{4}-[0-9]{2}-[0-9]{2}(T[0-9:]+Z?)?).*/\1/p')
      if [ -n "$until" ]; then
        w "status-$key" block transient "$TASK" --reason "$text" --next-actor firstmate --until "$until"
      else
        w "status-$key" block transient "$TASK" --reason "$text" --next-actor firstmate
      fi ;;
    failed)
      w "status-$key" block failure "$TASK" --reason "$text" --next-actor firstmate ;;
    resolved)
      w "status-$key" unblock "$TASK" ;;
  esac
  return 0
}

hold_event() {  # <hold-kind> <reason>: make the record capable of taking this old-source hold
  local kind=$1 reason key plain current occurrence
  reason=$2
  case "$reason" in
    fm-hold-v1:*) plain=$(printf '%s' "${reason#fm-hold-v1:}" | base64 -d 2>/dev/null) && reason=$plain ;;
  esac
  reason=$(cut_to "$reason" 1500)
  [ -n "$reason" ] || reason="held ($kind)"
  # Captain hold-set is the source transition identity, not a whole-file mtime.
  occurrence=${3:-}
  if [ -z "$occurrence" ]; then
    occurrence=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-tasks-axi.sh" show "$TASK" --full 2>/dev/null \
      | grep -o 'Captain hold set: [^"\\]*' | head -1 | sed 's/^Captain hold set: //')
    [ -n "$occurrence" ] || occurrence=legacy
  fi
  key=$(short "$kind|$reason|$occurrence")
  current=$("$WRITER" show "$TASK" --json 2>/dev/null) || current=''
  if [ -z "$current" ]; then
    w "hold-$key-create" create "$TASK" --title "$(title_of)" --kind "$(record_kind "$(backlog_field kind)")" || return 0
    current='{"state":"triage"}'
  fi
  current=$(printf '%s' "$current" | jq -r '.state // "running"' 2>/dev/null) || current=running
  if [ "$current" = blocked ]; then
    local prior
    prior=$("$WRITER" show "$TASK" --json 2>/dev/null)
    local mapped_kind=transient mapped_actor=firstmate
    case "$kind" in captain) mapped_kind=needs-decision; mapped_actor=owner ;; external) mapped_kind=external ;; esac
    if [ "$(printf '%s' "$prior" | jq -r '.blockReason')" = "$reason" ] \
      && [ "$(printf '%s' "$prior" | jq -r '.blockKind')" = "$mapped_kind" ] \
      && [ "$(printf '%s' "$prior" | jq -r '.nextActor')" = "$mapped_actor" ]; then
      return 0
    fi
  fi
  if [ "$current" = review ] && rows_task && printf '%s' "$reason" | grep -qi 'verification pending'; then
    return 0
  fi
  case "$current" in
    review) w "hold-$key-changes" changes "$TASK" --note 'old source holds the task' || return 0 ;;
    blocked) w "hold-$key-unblock" unblock "$TASK" || return 0 ;;
    done|archived) return 0 ;;
  esac
  case "$current" in
    running) ;;
    *) w "hold-$key-assign" assign "$TASK" --to "$TASK" || return 0
       w "hold-$key-start" start "$TASK" || return 0 ;;
  esac
  if printf '%s' "$reason" | grep -qi 'verification pending'; then
    w "hold-$key-review" "done" "$TASK" --summary "$reason" --changed-files - --verification 'old source verification pending' --residual-risk - --next-actor tester
    return 0
  fi
  case "$kind" in
    captain)
      w "hold-$key" ask "$TASK" --question "$reason" --option 'Decide now' --option 'Decide later' --recommendation - --why 'a captain hold' --next-actor owner ;;
    external)
      w "hold-$key" block external "$TASK" --reason "$reason" --next-actor firstmate ;;
    *)
      w "hold-$key" block transient "$TASK" --reason "$reason" --next-actor firstmate ;;
  esac || w "hold-$key-comment" event "$TASK" comment --note "held ($kind): $reason"
}

case "$EVENT" in
  dispatched)
    kind=$(record_kind "${2:-}")
    repo=${3:-}
    w create create "$TASK" --title "$(title_of)" --kind "$kind" ${repo:+--repo "$repo"}
    w assign assign "$TASK" --to "$TASK"
    w start start "$TASK"
    ;;
  status) status_event "$@" ;;
  started) w "manual-start-${2:?start occurrence required}" start "$TASK" ;;
  cleaned-up) w cleaned-up event "$TASK" comment --note 'cleaned up by bin/fm-teardown.sh' ;;
  verified) w verified event "$TASK" comment --note 'verification record complete (bin/fm-verify-close.sh)' ;;
  held) hold_event "${2:-hold}" "${3:-}" "${4:-}" ;;
  answered)
    case "${2:-}" in
      released) w answered-released unblock "$TASK" || w answered-released-comment event "$TASK" comment --note 'captain hold released' ;;
      *) close_task answered ;;
    esac
    ;;
  deploy-verify)
    w "deploy-$(short "${2:-}|${3:-}")" event "$TASK" deploy --note "deploy ${3:-} at ${2:-}: verify ask sent (${4:-})"
    ;;
  step-start)
    # a spawn on the harness default model names none: the writer keeps the setup's model for the state
    w "step-start-${2:-none}" step "$TASK" start --generation "${2:-}" --harness "${3:-}" ${4:+--model "$4"} ${5:+--effort "$5"} ${6:+--account "$6"}
    ;;
  step-end)
    w "step-end-${2:-none}-$(short "${3:-}")" step "$TASK" end --generation "${2:-}" --reason "${3:-cleanup}"
    ;;
esac
exit 0
