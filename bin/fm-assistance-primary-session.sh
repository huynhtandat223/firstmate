#!/usr/bin/env bash
# Publish the running primary harness session for orchestrator assistance.
#
# Usage:
#   fm-assistance-primary-session.sh <harness> <session-id> <history-path>
#
# Primary SessionStart integrations call this after the harness has selected its
# active transcript.
# The record is inert when no primary assistance task exists.
# A companion uses it to detect a context clear or harness switch by exact
# session identity instead of transcript recency.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

harness=${1:-}
session=${2:-}
history=${3:-}
binding="$STATE/primary-assistance.assistance-binding"
current="$STATE/primary-assistance.assistance-current"

case "$harness" in
  claude|pi|pi-signed) ;;
  *) printf 'error: primary assistance cannot record unmeasured harness: %s\n' "${harness:-missing}" >&2; exit 1 ;;
esac
case "$session" in
  ''|*[!A-Za-z0-9._-]*) printf 'error: primary assistance session id is unsafe\n' >&2; exit 1 ;;
esac
[ -f "$binding" ] && [ ! -L "$binding" ] || exit 0
[ -f "$history" ] && [ ! -L "$history" ] || {
  printf 'error: primary assistance history is unavailable: %s\n' "$history" >&2
  exit 1
}
case "$history" in /*) ;; *) printf 'error: primary assistance history must be absolute\n' >&2; exit 1 ;; esac
[ -d "$STATE" ] && [ ! -L "$STATE" ] || {
  printf 'error: primary assistance state directory is unavailable\n' >&2
  exit 1
}
tmp=$(umask 077; mktemp "$STATE/.primary-assistance-current.XXXXXX") || exit 1
trap 'rm -f -- "$tmp"' EXIT
{
  printf 'primary_harness=%s\n' "$harness"
  printf 'primary_session=%s\n' "$session"
  printf 'parent_history=%s\n' "$history"
  printf 'recorded_at=%s\n' "$(date -Iseconds)"
} > "$tmp" || exit 1
chmod 0600 "$tmp" || exit 1
mv -f -- "$tmp" "$current" || exit 1
trap - EXIT
