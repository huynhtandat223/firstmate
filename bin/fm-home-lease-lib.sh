#!/usr/bin/env bash
# Opt-in home ownership. config/home-lease contains the shared backlog-home name.
# Host identity stays local in config/host-id. Never enable this in a worker.
fm_home_lease_config() {
  local home config
  home=${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}
  config=${FM_CONFIG_OVERRIDE:-$home/config}
  [ -f "$config/home-lease" ] || return 1
  FM_HOME_NAME=$(head -n 1 "$config/home-lease")
  [ -n "$FM_HOME_NAME" ] || { echo 'error: empty home-lease configuration' >&2; return 2; }
  export FM_HOME_NAME
}
fm_home_lease_state_dir() {
  local home
  home=${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}
  printf '%s\n' "${FM_STATE_OVERRIDE:-$home/state}"
}
fm_home_lease_require() {
  local result=0 dir
  fm_home_lease_config || result=$?
  [ "$result" -ne 1 ] || return 0
  [ "$result" -eq 0 ] || return "$result"
  dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  "$dir/fm-host.sh" lease check >/dev/null
}
fm_home_lease_take() {
  local result=0 dir
  fm_home_lease_config || result=$?
  [ "$result" -ne 1 ] || return 0
  [ "$result" -eq 0 ] || return "$result"
  dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  "$dir/fm-host.sh" register >/dev/null && "$dir/fm-host.sh" lease take
}
# Renewal runs from session start: the step loop heartbeats the lease, so it starts the moment the lease is taken
# rather than when the watcher is first armed. Idempotent; the loop exits when the session lock goes.
fm_home_lease_renew_start() {
  local result=0 dir
  fm_home_lease_config || result=$?
  [ "$result" -eq 0 ] || return 0
  dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  "$dir/fm-task-step-loop.sh" start >/dev/null 2>&1 || true
}
# A worker is claimed before its endpoint exists. The claim raises liveWorkers on the host record at once, so a host
# that takes an expired lease cannot read a zero count from before the launch. state/.host-claim.<task> keeps the
# claim counted by every later heartbeat until that worker's own record is live (host_heartbeat_pass in
# bin/fm-task-step-loop.sh). The claim and the heartbeat's count run under one lock, so they never interleave.
fm_home_lease_claim_worker() {  # <task>
  local result=0 dir state lock out
  fm_home_lease_config || result=$?
  [ "$result" -ne 1 ] || return 0
  [ "$result" -eq 0 ] || return "$result"
  dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  state=$(fm_home_lease_state_dir)
  lock=$state/.host-count.lock
  fm_lock_acquire_wait_max "$lock" 60 || { echo 'error: cannot claim a worker slot: the host worker count is busy' >&2; return 1; }
  date +%s > "$state/.host-claim.$1" 2>/dev/null || result=1
  if [ "$result" -eq 0 ] && ! out=$("$dir/fm-host.sh" worker claim "$1" 2>&1); then
    rm -f "$state/.host-claim.$1"
    printf '%s\n' "$out" >&2
    result=1
  fi
  fm_lock_release "$lock"
  return "$result"
}
# Prints the lease generation this host holds right now (nothing when the lease is off); non-zero when it holds none.
fm_home_lease_generation() {
  local result=0 dir out
  fm_home_lease_config || result=$?
  [ "$result" -ne 1 ] || return 0
  [ "$result" -eq 0 ] || return "$result"
  dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  out=$("$dir/fm-host.sh" lease check --json) || { printf '%s\n' "$out"; return 1; }
  printf '%s\n' "$out" | sed -n 's/.*"generation":\([0-9][0-9]*\).*/\1/p'
}
# The claim's undo, for a spawn that exits before its worker record exists: the slot goes back, and so does the count.
fm_home_lease_release_worker() {  # <task>
  local result=0 dir state lock
  fm_home_lease_config || result=$?
  [ "$result" -eq 0 ] || return 0
  dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  state=$(fm_home_lease_state_dir)
  lock=$state/.host-count.lock
  fm_lock_acquire_wait_max "$lock" 60 || return 1
  if [ -f "$state/.host-claim.$1" ]; then
    rm -f "$state/.host-claim.$1"
    "$dir/fm-host.sh" worker release "$1" >/dev/null 2>&1 || result=1
  fi
  fm_lock_release "$lock"
  return "$result"
}
