#!/usr/bin/env bash
# Assistance authority checks shared by public fleet mutation commands.
# Check both cwd and FM_HOME so a caller cannot accidentally escape its home by
# pointing FM_HOME at the parent. This is a role boundary, not an OS sandbox.
fm_assistance_require_dispatcher() {
  local path
  for path in "${FM_HOME:-}" "$PWD"; do
    [ -n "$path" ] && [ -d "$path" ] || continue
    path=$(CDPATH='' cd -- "$path" && pwd -P) || return 1
    while [ "$path" != / ] && [ -n "$path" ]; do
      if [ -e "$path/.fm-assistance-home" ]; then
        echo 'error: assistance rule: observe and propose only; spawning and steering are refused' >&2
        return 1
      fi
      path=${path%/*}
    done
  done
}

fm_assistance_require_ordinary_target() {
  local meta=$1
  if [ -f "$meta" ] && grep -qx 'kind=assistance' "$meta"; then
    if [[ "${2:-}" =~ [^[:space:]] ]]; then return 0; fi
    echo 'error: assistance rule: ordinary worker commands cannot control an assistance; use fm-assistance.sh for an owner-authorized operation' >&2
    return 1
  fi
}
