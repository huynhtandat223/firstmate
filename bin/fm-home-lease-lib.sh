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
