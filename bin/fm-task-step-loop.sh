#!/usr/bin/env bash
# Home-scoped step liveness loop for the opt-in task record (plan v2 D1).
#
# Usage: fm-task-step-loop.sh [start|run|stop]
#   start  (default) make sure this home runs exactly one loop: when no live loop holds
#          state/.task-step-loop.lock, start one in its own process group, detached from the caller, and return.
#          Prints "task-step-loop: started pid=<N>", "task-step-loop: running pid=<N>" or
#          "task-step-loop: off" (no config/task-shadow flag, or no live session lock). Always exits 0.
#   run    the loop itself, in the foreground (start runs this); exits 0 when another loop holds the lock.
#   stop   stop this home's loop and wait until it has exited; prints "task-step-loop: stopped pid=<N>" or
#          "task-step-loop: none running", or exits 1 when the loop outlived the wait.
#
# Each card's live dot follows its incarnation's endpoint. Every FM_TASK_STEP_EVERY seconds (default 5) the loop
# reads every task's endpoint and calls the task record writer (bin/fm-task.sh step, or FM_TASK_SHADOW_WRITER) only
# for a task whose liveness or spawn generation differs from the last one written (state/.task-step-live, one
# `<task>\t<spawn generation>\t<alive|dead>` line each, kept across restarts). The writer refuses a report whose spawn
# generation is not the one that started the running step. A call the API did not answer is tried again on the next
# pass; a refusal is settled like a write.
#
# The loop runs outside the watcher, so a closed pane's dot stops within one interval even while firstmate handles a
# wake and no watcher runs. The arm path (bin/fm-watch-arm.sh) runs `start` on every arm, which restarts a loop that
# died. The loop exits on its own when this home's session lock (state/.lock) is free or names a dead pid, when the
# config/task-shadow flag is gone, or when the state directory is gone.
#
# With config/home-lease the loop writes steps only while this host holds the lease: it checks before every pass,
# skips a pass without it, and logs each change to state/.task-step-loop.log. It also renews the lease every
# FM_HOST_HEARTBEAT_EVERY seconds (default 30); bin/fm-lock.sh starts it as soon as the session takes the lease.
#
# A stop (TERM, INT, HUP or `stop`) lets the in-flight writer call finish, records it, and only then releases the
# lock, so no writer of a stopped loop can commit after a successor's write. Each writer call is bounded by a 2 s
# timeout; a loop killed with KILL leaves at most that one bounded call behind.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-task-shadow-config-lib.sh
. "$SCRIPT_DIR/fm-task-shadow-config-lib.sh"
# shellcheck source=bin/fm-home-lease-lib.sh
. "$SCRIPT_DIR/fm-home-lease-lib.sh"

LOCK="$STATE/.task-step-loop.lock"
TASK_RECORD_WRITER=${FM_TASK_SHADOW_WRITER:-$SCRIPT_DIR/fm-task.sh}
TASK_STEP_WRITTEN="$STATE/.task-step-live"
TASK_STEP_EVERY=${FM_TASK_STEP_EVERY:-5}
STOP=0
# seconds between lease heartbeats; the lease expires after 180
HOST_HEARTBEAT_EVERY=${FM_HOST_HEARTBEAT_EVERY:-30}
# seconds a worker claim counts when no worker record follows it
HOST_CLAIM_TTL=600

# 0 while this home should run a loop: the flag is on and the session lock names a live pid.
loop_wanted() {
  [ -d "$STATE" ] && { [ -e "$CONFIG/task-shadow" ] || [ -e "$CONFIG/home-lease" ]; } || return 1
  fm_session_lock_inspect "$STATE"
  case "$FM_LOCK_INSPECT_STATE" in free|stale) return 1 ;; esac
  return 0
}

# The live loop's pid, or nothing.
loop_pid() {
  local pid
  pid=$(cat "$LOCK/pid" 2>/dev/null || true)
  fm_pid_alive "$pid" && printf '%s\n' "$pid"
}

task_step_pass() {
  local meta id generation live line written writer next=''
  # the writer settings the flag file carries (FM_TASK_BASE_URL, FM_TASK_AUTH, FM_TASK_TOKEN_FILE), as the hook reads them
  fm_task_shadow_config "$CONFIG/task-shadow"
  written=$(cat "$TASK_STEP_WRITTEN" 2>/dev/null || true)
  for meta in "$STATE"/*.meta; do
    [ "$STOP" -eq 0 ] || break
    [ -f "$meta" ] || continue
    [ "$(fm_meta_get "$meta" kind)" != assistance ] || continue
    id=${meta##*/}; id=${id%.meta}
    generation=$(fm_meta_get "$meta" spawn_gen)
    live=$(fm_backend_agent_alive "$(fm_backend_of_meta "$meta")" "$(fm_backend_target_of_meta "$meta")" 2>/dev/null) || live=unknown
    line=$(printf '%s\t%s\t%s' "$id" "$generation" "$live")
    case "$live" in
      alive|dead)
        if ! printf '%s\n' "$written" | grep -Fqx -- "$line"; then
          fm_run_timed 2 env FM_HOME="$FM_HOME" "$TASK_RECORD_WRITER" step "$id" "$live" --generation "$generation" >/dev/null 2>&1 &
          writer=$!
          # a stop signal interrupts wait: wait again until the call has really ended, then read its status
          while ! wait "$writer" && kill -0 "$writer" 2>/dev/null; do :; done
          wait "$writer"
          # the API did not answer (3) or the call ran out of time: try again next pass; any other answer is settled
          case $? in 3|124|137) line='' ;; esac
        fi ;;
      *) line='' ;;
    esac
    [ -n "$line" ] || line=$(printf '%s\n' "$written" | awk -F '\t' -v id="$id" '$1 == id { print; exit }')
    [ -z "$line" ] || next+="$line"$'\n'
  done
  # a pass cut short by a stop keeps the lines of the tasks it did not reach
  if [ "$STOP" -ne 0 ]; then
    next+=$(printf '%s\n' "$written" | awk -F '\t' -v seen="$next" 'BEGIN { n = split(seen, a, "\n"); for (i = 1; i <= n; i++) { split(a[i], f, "\t"); if (f[1] != "") s[f[1]] = 1 } } $1 != "" && !($1 in s)')
    [ -z "${next##*$'\n'}" ] || next+=$'\n'
  fi
  [ "$next" = "${written:+$written$'\n'}" ] && return 0
  printf '%s' "$next" > "$TASK_STEP_WRITTEN.tmp.$$" && mv -f "$TASK_STEP_WRITTEN.tmp.$$" "$TASK_STEP_WRITTEN"
}

host_heartbeat_pass() {
  local meta live count=0 queue=0 epoch claim id at live_ids=' ' lock rc
  [ -f "$CONFIG/home-lease" ] || return 0
  epoch=$(date +%s)
  [ $((epoch - HOST_HEARTBEAT_AT)) -ge "$HOST_HEARTBEAT_EVERY" ] || return 0
  HOST_HEARTBEAT_AT=$epoch
  fm_home_lease_config || return 1
  # Count and report under the lock a worker claim takes, so a claim cannot fall between the count and the report.
  lock=$STATE/.host-count.lock
  fm_lock_acquire_wait_max "$lock" 30 || return 1
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    live=$(fm_backend_agent_alive "$(fm_backend_of_meta "$meta")" "$(fm_backend_target_of_meta "$meta")" 2>/dev/null) || live=unknown
    # Unknown is counted as live: no hand-over on incomplete reconciliation.
    [ "$live" = dead ] && continue
    count=$((count + 1))
    id=${meta##*/}; live_ids+="${id%.meta} "
  done
  # A claim stands in for a worker whose record is not live yet: once that record is counted the claim ends, and a
  # launch that never produced a record stops counting after HOST_CLAIM_TTL seconds.
  for claim in "$STATE"/.host-claim.*; do
    [ -f "$claim" ] || continue
    id=${claim##*/.host-claim.}
    at=$(cat "$claim" 2>/dev/null || true)
    case "$at" in ''|*[!0-9]*) at=0 ;; esac
    if [[ "$live_ids" == *" $id "* ]] || [ $((epoch - at)) -ge "$HOST_CLAIM_TTL" ]; then rm -f "$claim"; else count=$((count + 1)); fi
  done
  [ ! -f "$STATE/.wake-queue" ] || queue=$(wc -l < "$STATE/.wake-queue" | tr -d ' ')
  FM_HOST_LIVE_WORKERS=$count FM_HOST_WAKE_QUEUE_LENGTH=$queue "$SCRIPT_DIR/fm-host.sh" heartbeat >/dev/null 2>&1
  rc=$?
  fm_lock_release "$lock"
  return "$rc"
}

# 0 when this host holds the current lease (or the lease is off). Checked before every pass, so a host that lost the
# lease writes no step. Each change of ownership is one line in state/.task-step-loop.log.
host_owns_lease() {
  local now
  [ -f "$CONFIG/home-lease" ] || return 0
  fm_home_lease_config || return 1
  now=$(date +%s)
  if "$SCRIPT_DIR/fm-host.sh" lease check >/dev/null 2>&1; then
    [ "$HOST_LEASE_LOST" -eq 0 ] || printf 'at=%s holds the home lease again: step writes resume\n' "$now" >> "$STATE/.task-step-loop.log"
    HOST_LEASE_LOST=0
    return 0
  fi
  [ "$HOST_LEASE_LOST" -eq 1 ] || printf 'at=%s lost the home lease: step writes skipped\n' "$now" >> "$STATE/.task-step-loop.log"
  HOST_LEASE_LOST=1
  return 1
}

run_loop() {
  local fd
  HOST_HEARTBEAT_AT=0
  HOST_LEASE_LOST=0
  # keep no descriptor of the caller open (a harness waits on its pipes)
  for fd in 3 4 5 6 7 8 9; do eval "exec $fd>&-" 2>/dev/null || true; done
  fm_lock_try_acquire "$LOCK" || exit 0
  trap 'STOP=1' TERM INT HUP
  trap 'fm_lock_release "$LOCK"' EXIT
  while [ "$STOP" -eq 0 ] && loop_wanted; do
    host_heartbeat_pass || true
    if host_owns_lease && [ -e "$CONFIG/task-shadow" ]; then task_step_pass; fi
    [ "$STOP" -eq 0 ] || break
    # an interruptible wait: a stop ends the sleep at once
    sleep "$TASK_STEP_EVERY" &
    wait "$!" 2>/dev/null || true
  done
  exit 0
}

case "${1:-start}" in
  start)
    if ! loop_wanted; then echo "task-step-loop: off"; exit 0; fi
    if pid=$(loop_pid); then echo "task-step-loop: running pid=$pid"; exit 0; fi
    # its own process group and no inherited stdio, so the end of the caller's job does not end the loop
    ( set -m; "$SCRIPT_DIR/fm-task-step-loop.sh" run </dev/null >/dev/null 2>&1 & )
    tries=50
    while [ "$tries" -gt 0 ]; do
      if pid=$(loop_pid); then echo "task-step-loop: started pid=$pid"; exit 0; fi
      sleep 0.1; tries=$((tries - 1))
    done
    echo "task-step-loop: started (lock not yet held)"
    exit 0 ;;
  run) run_loop ;;
  stop)
    pid=$(loop_pid) || { echo "task-step-loop: none running"; exit 0; }
    kill -TERM "$pid" 2>/dev/null || true
    tries=100
    while [ "$tries" -gt 0 ] && fm_pid_alive "$pid"; do sleep 0.1; tries=$((tries - 1)); done
    if fm_pid_alive "$pid"; then echo "task-step-loop: pid=$pid outlived the stop" >&2; exit 1; fi
    echo "task-step-loop: stopped pid=$pid" ;;
  -h|--help) sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) echo "usage: fm-task-step-loop.sh [start|run|stop]" >&2; exit 2 ;;
esac
