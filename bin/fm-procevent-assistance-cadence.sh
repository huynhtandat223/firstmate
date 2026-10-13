#!/usr/bin/env bash
# Built-in process-event adapter for an assistance profile's cadence.
# Usage: fm-procevent-assistance-cadence.sh wait|classify <result>|terminal <result>|silent <result>
set -euo pipefail
case "${1:-}" in
  wait)
    [ -f "${FM_HOME:?}/.fm-assistance-home" ] || exit 1
    cadence=$(jq -er '.cadence_seconds | select(type == "number" and floor == . and . >= 1 and . <= 27000)' "$FM_HOME/data/assistance.json")
    sleep "$cadence"
    printf 'assistance sources due\n'
    ;;
  classify) printf 'assistance sources due\n' ;;
  terminal|silent) exit 1 ;;
  *) echo 'error: expected wait, classify, terminal or silent' >&2; exit 2 ;;
esac
