#!/usr/bin/env bash
# Firstmate-owed waits (firstmate#192). A worker's `done`, `needs-decision` or
# `blocked` line waits on firstmate; past this home's limit that wait is owed,
# and bin/fm-wake-drain.sh refuses its acknowledgement until the task moves.
# A `paused` line waits on something outside firstmate and keeps the
# config/wait-over-minutes alarm instead.
# FM_FIRSTMATE_WAIT_DEFAULT_MINUTES is the threshold when the file is absent.
# fm_firstmate_wait_limit <config-dir> sets FM_FIRSTMATE_WAIT_LIMIT (minutes or off).
# fm_firstmate_wait_owed <state> <config> sets FM_FIRSTMATE_WAIT_ROWS to
# "<task><TAB><verb><TAB><minutes><TAB><note>" lines, newest line per task.
FM_FIRSTMATE_WAIT_DEFAULT_MINUTES=${FM_FIRSTMATE_WAIT_DEFAULT_MINUTES:-10}
FM_FIRSTMATE_WAIT_VERBS='done needs-decision blocked'

. "$(dirname "${BASH_SOURCE[0]}")/fm-wake-lib.sh"
. "$(dirname "${BASH_SOURCE[0]}")/fm-classify-lib.sh"

fm_firstmate_wait_limit() {  # <config-dir>
  local dir=$1 raw
  FM_FIRSTMATE_WAIT_LIMIT=$FM_FIRSTMATE_WAIT_DEFAULT_MINUTES
  [ -n "$dir" ] && [ -f "$dir/firstmate-wait-minutes" ] || return 0
  raw=$(head -n 1 "$dir/firstmate-wait-minutes" 2>/dev/null | tr -d '[:space:]')
  case "$raw" in
    '') return 0 ;;
    off) FM_FIRSTMATE_WAIT_LIMIT=off ;;
    *[!0-9]*) return 1 ;;
    *) FM_FIRSTMATE_WAIT_LIMIT=$raw ;;
  esac
}

# A task is owed only while nothing firstmate-owned is newer than its line: a
# steering-inbox message (fm-send), a captain hold, or a merge touch the same
# acknowledgement marker this reads.
fm_firstmate_wait_cleared() {  # <state> <task> <line-start-epoch>
  local state=$1 task=$2 start=$3 f mtime
  for f in "$state/$task.firstmate-ack" "$state/$task".inbox/*.msg; do
    [ -e "$f" ] || continue
    mtime=$(stat -c %Y "$f" 2>/dev/null) || continue
    [ "$mtime" -lt "$start" ] || return 0
  done
  return 1
}

# firstmate's own action on a wait clears it: a steering message, a captain hold,
# or a proof of merge touch this marker, and the age starts from its line again.
fm_firstmate_wait_ack() {  # <state> <task>
  local state=$1 task=$2
  case "$task" in ''|*[!A-Za-z0-9._-]*) return 0 ;; esac
  [ -d "$state" ] || return 0
  : > "$state/$task.firstmate-ack" 2>/dev/null || true
}

fm_firstmate_wait_owed() {  # <state> <config>
  local state=$1 config=$2 meta task kind status row offset line verb stamp start turn now elapsed note
  FM_FIRSTMATE_WAIT_ROWS=
  fm_firstmate_wait_limit "$config" || return 1
  [ "$FM_FIRSTMATE_WAIT_LIMIT" != off ] || return 0
  fm_epoch_seconds_to now
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    task=${meta##*/}
    task=${task%.meta}
    case "$task" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
    kind=$(sed -n 's/^kind=//p' "$meta" 2>/dev/null | head -n 1)
    case "$kind" in ship|scout|'') ;; *) continue ;; esac
    status="$state/$task.status"
    [ -f "$status" ] && [ ! -L "$status" ] || continue
    row=$(grep -b -v '^[[:space:]]*$' "$status" 2>/dev/null | tail -n 1) || row=
    [ -n "$row" ] || continue
    offset=${row%%:*}
    line=${row#*:}
    status_line_verb "$line" verb
    case " $FM_FIRSTMATE_WAIT_VERBS " in *" $verb "*) ;; *) continue ;; esac
    if stamp=$(status_line_at_epoch "$line"); then
      :
    else
      stamp=$(stat -c %Y "$status" 2>/dev/null) || continue
    fi
    start=$stamp
    turn=$(stat -c %Y "$state/$task.turn-ended" 2>/dev/null) || turn=
    case "$turn" in ''|*[!0-9]*) ;; *) [ "$turn" -le "$start" ] || start=$turn ;; esac
    elapsed=$((now - start))
    [ "$elapsed" -ge $((FM_FIRSTMATE_WAIT_LIMIT * 60)) ] || continue
    fm_firstmate_wait_cleared "$state" "$task" "$start" && continue
    note=$(status_line_note "$line")
    note=${note:0:120}
    FM_FIRSTMATE_WAIT_ROWS="${FM_FIRSTMATE_WAIT_ROWS}${task}	${verb}	$((elapsed / 60))	${note}
"
  done
  return 0
}
