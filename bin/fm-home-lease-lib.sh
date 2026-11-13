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
