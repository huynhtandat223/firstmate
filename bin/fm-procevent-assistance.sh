#!/usr/bin/env bash
# Orchestrator-assistance adapter for the generic process-event runner.
#
# Usage:
#   fm-procevent-assistance.sh arm <programme-id>
#   fm-procevent-assistance.sh source <programme-id>
#   fm-procevent-assistance.sh autohandle <source-id> <sequence> <result-file>
#   fm-procevent-assistance.sh terminal <result-file>
#   fm-procevent-assistance.sh self-announcing
#   fm-procevent-assistance.sh retire <programme-id>
#
# `source` blocks in tail's filesystem notification path until the bound
# transcript grows, or exits immediately when the binding is stale.
# The generic runner captures that one event durably.
# `autohandle` then injects one typed observation request into the companion,
# acknowledges the capture, and re-arms before the next transcript change.
# The companion's own ordinary turn-end signal is the downstream announcement,
# so a fully applied capture needs no duplicate process-event wake.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
FM_SEND="${FM_SEND:-$FM_ROOT/bin/fm-send.sh}"
ASSISTANCE="$FM_ROOT/custom-skills/orchestrator-assistance/fm-assistance.sh"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"
# shellcheck source=custom-skills/orchestrator-assistance/fm-assistance-lib.sh
. "$FM_ROOT/custom-skills/orchestrator-assistance/fm-assistance-lib.sh"
# shellcheck source=bin/fm-operational-input.sh
. "$SCRIPT_DIR/fm-operational-input.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

validate_programme() {
  fm_task_id_creation_valid "${1:-}" || die "programme id must be path-safe and at most 64 characters"
  [ "${#1}" -le 53 ] || die "programme id is too long for an assistance source"
}

source_id() {
  validate_programme "$1"
  printf 'assistance-%s\n' "$1"
}

binding_path() { fm_assistance_binding_path "$FM_HOME" "$1"; }

binding_field() {
  fm_assistance_meta_field "$(binding_path "$1")" "$2"
}

current_binding_state() {  # <programme-id> -> current|stale|untracked
  local programme=$1 binding current recorded_harness recorded_history active_harness active_history
  binding=$(binding_path "$programme")
  [ -f "$binding" ] && [ ! -L "$binding" ] || { printf 'untracked\n'; return; }
  [ "$programme" = primary ] || { printf 'current\n'; return; }
  current=$(fm_assistance_current_path "$FM_HOME" "$programme")
  [ -f "$current" ] && [ ! -L "$current" ] || { printf 'stale\n'; return; }
  recorded_harness=$(fm_assistance_meta_field "$binding" primary_harness)
  recorded_history=$(fm_assistance_meta_field "$binding" parent_history)
  active_harness=$(fm_assistance_meta_field "$current" primary_harness)
  active_history=$(fm_assistance_meta_field "$current" parent_history)
  if [ -n "$recorded_harness" ] && [ "$recorded_harness" = "$active_harness" ] \
    && [ -n "$recorded_history" ] && [ "$recorded_history" = "$active_history" ]; then
    printf 'current\n'
  else
    printf 'stale\n'
  fi
}

cmd_arm() {
  local programme=${1:-} sid binding history aid
  validate_programme "$programme"
  binding=$(binding_path "$programme")
  [ -f "$binding" ] && [ ! -L "$binding" ] || die "no assistance binding for $programme"
  history=$(binding_field "$programme" parent_history)
  [ -f "$history" ] && [ ! -L "$history" ] || die "bound history is unavailable for $programme"
  aid=$(binding_field "$programme" assistance_task_id)
  [ -f "$STATE/$aid.meta" ] && [ ! -L "$STATE/$aid.meta" ] \
    || die "assistance session is not recorded for $programme"
  sid=$(source_id "$programme")
  "$SCRIPT_DIR/fm-procevent.sh" register assistance "$sid" -- \
    "$SCRIPT_DIR/fm-procevent-assistance.sh" source "$programme" || return 1
  printf 'armed: %s\n' "$sid"
}

cmd_source() {
  local programme=${1:-} history state
  validate_programme "$programme"
  state=$(current_binding_state "$programme")
  if [ "$state" != current ]; then
    printf 'event=stale-binding\nprogramme=%s\n' "$programme"
    exit 0
  fi
  history=$(binding_field "$programme" parent_history)
  [ -f "$history" ] && [ ! -L "$history" ] || {
    printf 'event=stale-binding\nprogramme=%s\n' "$programme"
    exit 0
  }
  tail -n 0 -F -- "$history" 2>/dev/null | {
    IFS= read -r _ || exit 1
    printf 'event=history-grew\nprogramme=%s\n' "$programme"
  }
}

result_field() {  # <result> <key>
  sed -n "s/^$2=//p" "$1" | head -n 1
}

cmd_autohandle() {
  local sid=${1:-} seq=${2:-} result=${3:-} programme event expected encoded status_file status_line
  case "$sid" in assistance-?*) programme=${sid#assistance-} ;; *) die "not an assistance source: $sid" ;; esac
  validate_programme "$programme"
  case "$seq" in ''|*[!0-9]*) die "sequence must be a nonnegative integer" ;; esac
  expected=$(source_id "$programme")
  [ "$expected" = "$sid" ] || die "source id does not identify one assistance programme"
  [ -f "$result" ] && [ ! -L "$result" ] || die "result file is unavailable"
  event=$(result_field "$result" event)
  case "$event" in
    history-grew)
      [ "$(current_binding_state "$programme")" = current ] || event=stale-binding
      ;;
    stale-binding) ;;
    *) die "assistance result is malformed" ;;
  esac
  if [ "$event" = stale-binding ]; then
    status_file="$STATE/$(binding_field "$programme" assistance_task_id).status"
    status_line="blocked [key=assistance-binding-$programme]: assistance binding is stale; run fm-assistance.sh bind $programme for the running primary session and reload the companion"
    grep -Fqx -- "$status_line" "$status_file" 2>/dev/null \
      || printf '%s\n' "$status_line" >> "$status_file" \
      || return 1
  else
    fm_operational_input_encode assistance \
      "The bound transcript grew. Run $ASSISTANCE observe $programme now, process and settle every emitted turn, then run $ASSISTANCE status $programme. Continue until status reports caught-up." \
      encoded || return 1
    FM_HOME="$FM_HOME" "$FM_SEND" "$(binding_field "$programme" assistance_task_id)" "$encoded" \
      || return 1
  fi
  "$SCRIPT_DIR/fm-procevent.sh" handled "$sid" "$seq" >/dev/null || return 1
  cmd_arm "$programme" >/dev/null || return 1
}

cmd_retire() {
  local programme=${1:-}
  validate_programme "$programme"
  "$SCRIPT_DIR/fm-procevent.sh" retire "$(source_id "$programme")"
}

case "${1:-}" in
  arm) shift; [ "$#" -eq 1 ] || usage; cmd_arm "$@" ;;
  source) shift; [ "$#" -eq 1 ] || usage; cmd_source "$@" ;;
  autohandle) shift; [ "$#" -eq 3 ] || usage; cmd_autohandle "$@" ;;
  terminal) shift; [ "$#" -eq 1 ] || usage; exit 0 ;;
  self-announcing) shift; [ "$#" -eq 0 ] || usage; exit 0 ;;
  retire) shift; [ "$#" -eq 1 ] || usage; cmd_retire "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
